//
//  DBSchemaCoordinator.swift
//  Glacier
//
//  Created by andyfriedman on 1/3/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB

@objc
public class DBSchemaCoordinator: NSObject {
    
    @objc public static var areMigrationsComplete = false
    public static let migrationSideEffectsCollectionName = "MigrationSideEffects"
    public static let avatarRepairAttemptCount = "Avatar Repair Attempt Count"
    
    /// Migrate a database to the latest version. Throws if migrations fail.
    ///
    /// - Parameter databaseStorage: The database to migrate.
    /// - Parameter isMainDatabase: A boolean indicating whether this is the main database. If so, some global state will be set.
    /// - Parameter runDataMigrations: A boolean indicating whether to include data migrations. Typically, you want to omit this value or set it to `true`, but we want to skip them when recovering a corrupted database.
    /// - Returns: `true` if incremental migrations were performed, and `false` otherwise.
    @discardableResult
    public static func migrateDatabase(
        databaseStorage: DBStorageCoordinator,
        isMainDatabase: Bool,
        runDataMigrations: Bool = true
    ) throws -> Bool {
        let didPerformIncrementalMigrations: Bool
        
        let dbStorage = databaseStorage
        
        let hasCreatedInitialSchema = try dbStorage.read {
            try Self.hasCreatedInitialSchema(transaction: $0)
        }
        
        if hasCreatedInitialSchema {
            do {
                Log.database.info("Using incrementalMigrator.")
                didPerformIncrementalMigrations = try runIncrementalMigrations(
                    databaseStorage: databaseStorage,
                    runDataMigrations: runDataMigrations
                )
            } catch {
                Log.database.error("Incremental migrations failed: \(error)")
                throw error
            }
        } else {
            do {
                Log.database.info("Using newUserMigrator.")
                try newUserMigrator().migrate(dbStorage.pool)
                didPerformIncrementalMigrations = false
            } catch {
                Log.database.error("New user migrator failed: \(error)")
                throw error
            }
        }
        Log.database.notice("Migrations complete.")
        
        if isMainDatabase {
            //SSKPreferences.markGRDBSchemaAsLatest()
            areMigrationsComplete = true
        }
        
        return didPerformIncrementalMigrations
    }
    
    private static func runIncrementalMigrations(
        databaseStorage: DBStorageCoordinator,
        runDataMigrations: Bool
    ) throws -> Bool {
        let dbStorage = databaseStorage
        
        let previouslyAppliedMigrations = try dbStorage.read { transaction in
            try DatabaseMigrator().appliedIdentifiers(transaction.database)
        }
        
        // First do the schema migrations. (See the comment within MigrationId for why schema and data
        // migrations are separate.)
        let incrementalMigrator = DatabaseMigratorWrapper()
        registerSchemaMigrations(migrator: incrementalMigrator)
        try incrementalMigrator.migrate(dbStorage.pool)
        
        /*if runDataMigrations {
         // Hack: Load the account state now, so it can be accessed while performing other migrations.
         // Otherwise one of them might indirectly try to load the account state using a sneaky transaction,
         // which won't work because migrations use a barrier block to prevent observing database state
         // before migration.
         try dbStorage.read { transaction in
         //_ = self.tsAccountManager.localAddress(with: transaction.asAnyRead)
         }
         
         // Finally, do data migrations.
         registerDataMigrations(migrator: incrementalMigrator)
         try incrementalMigrator.migrate(dbStorage.pool)
         }*/
        
        let allAppliedMigrations = try dbStorage.read { transaction in
            try DatabaseMigrator().appliedIdentifiers(transaction.database)
        }
        
        return allAppliedMigrations != previouslyAppliedMigrations
    }
    
    private static func hasCreatedInitialSchema(transaction: GRDBReadTransaction) throws -> Bool {
        let appliedMigrations = try DatabaseMigrator().appliedIdentifiers(transaction.database)
        Log.database.info("appliedMigrations: \(appliedMigrations.sorted()).")
        return appliedMigrations.contains(MigrationId.createInitialSchema.rawValue)
    }
    
    // MARK: -
    private enum MigrationId: String, CaseIterable {
        case createInitialSchema
        //case accountCreation

        case addGradientAvatarToSmsAccount

        // NOTE: Every time we add a migration id, consider
        // incrementing grdbSchemaVersionLatest.
        // We only need to do this for breaking changes.
        // MARK: Data Migrations
        //
        // Any migration which leverages SDSModel serialization must occur *after* changes to the
        // database schema complete.
        //
        // Otherwise, for example, consider we have these two pending migrations:
        //  - Migration 1: resaves all instances of Foo (Foo is some SDSModel)
        //  - Migration 2: adds a column "new_column" to the "model_Foo" table
        //
        // Migration 1 will fail, because the generated serialization logic for Foo expects
        // "new_column" to already exist before Migration 2 has even run.
        //
        // The solution is to always split logic that leverages SDSModel serialization into a
        // separate migration, and ensure it runs *after* any schema migrations. That is, new schema
        // migrations must be inserted *before* any of these Data Migrations.
        //
        // Note that account state is loaded *before* running data migrations, because many model objects expect
        // to be able to access that without a transaction.
        case dataMigration_populateGalleryItems
        case dataMigration_markOnboardedUsers_v2
        case dataMigration_clearLaunchScreenCache
        case dataMigration_enableV2RegistrationLockIfNecessary
        case dataMigration_resetStorageServiceData
    }
    
    public static let grdbSchemaVersionDefault: UInt = 0
    public static let grdbSchemaVersionLatest: UInt = 0
    
    // An optimization for new users, we have the first migration import the latest schema
    // and mark any other migrations as "already run".
    private static func newUserMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(MigrationId.createInitialSchema.rawValue) { db in
            // Within the transaction this migration opens, check that we haven't already run
            // the initial schema migration, in case we are racing with another process that
            // is also running migrations.
            if try hasCreatedInitialSchema(transaction: GRDBReadTransaction(database: db)) {
                // Already done!
                return
            }
            
            guard let sqlFile = Bundle.main.url(forResource: "grdbschema", withExtension: "sql") else {
                fatalError("sqlFile was unexpectedly nil")
            }
            
            let sql = try String(contentsOf: sqlFile)
            try db.execute(sql: sql)
            
            // After importing the initial schema, we want to skip the remaining
            // incremental migrations, so we manually mark them as complete.
            for migrationId in (MigrationId.allCases.filter { $0 != .createInitialSchema }) {
                //if !CurrentAppContext().isRunningTests {
                //    Logger.info("skipping migration: \(migrationId) for new user.")
                //}
                insertMigration(migrationId.rawValue, db: db)
            }
        }
        
        return migrator
    }
    
    private class DatabaseMigratorWrapper {
        var migrator = DatabaseMigrator()
        
        /**
         * Registers a database migration to be run asynchronously.
         *
         * In short, migrations get registered, GRDB checks which if any haven't been run yet, and runs those.
         * Each migration is provided a transaction and is allowed to throw exceptions on failures.
         * Migrations MUST use the provided transaction to guarantee correctness. The same transaction
         * is used to check migration eligibility and to mark migrations as completed.
         * Migrations that _do not_ throw an exception will be marked at completed. Failed migrations
         * _must_ throw an exception to be marked as incomplete and be re-run on next app launch.
         * Every exception thrown crashes the app.
         */
        func registerMigration(
            _ identifier: MigrationId,
            migrate: @escaping (GRDBWriteTransaction) throws -> Result<Void, Error>
        ) {
            // Hold onto a reference to the migrator, so we can use its `appliedIdentifiers` method
            // which is really a static method since it uses no instance state, but needs a reference
            // to an instance (any instance, doesn't matter) anyway.
            // Don't keep a strong reference to self as that would be a retain cycle, and don't rely
            // on a weak reference to self because self is not guaranteed to be retained when
            // the migration actually runs; this class is used primary for migration setup.
            let migrator = self.migrator
            // Run with immediate foreign key checks so that pre-existing dangling rows
            // don't cause unrelated migrations to fail. We also don't perform schema
            // alterations that would necessitate disabling foreign key checks.
            self.migrator.registerMigration(identifier.rawValue, foreignKeyChecks: .immediate) { (database: Database) in
                let startTime = CACurrentMediaTime()
                
                // Create a transaction with this database connection.
                // GRDB creates a database connection for each migration applied; this migration
                // is finalized by GRDB internally. The steps look like:
                // 1. Create Database connection (in a write transaction)
                // 2. Run this closure, the migration itself
                // 3. Write to the grdb_migrations table to mark this migration as done (if we don't throw)
                // 4. Commit the transaction.
                //
                // Notably, it does _not_ check that the migration hasn't been run within the same transaction.
                // We do that here and just say we succeeded by early returning and not throwing an error.
                // This catches situations where the migrations are racing across processes.
                //
                // As long as we do this within the same DB connection we get as input to this
                // method, the check happens within the same transaction that writes that
                // the migration is complete, and we can take advantage of DB locks to enforce
                // migrations are only run once across processes.
                if try migrator
                    .appliedIdentifiers(database)
                    .contains(identifier.rawValue) {
                    // Already run! Just succeed.
                    Log.database.notice("Attempting to re-run an already-finished migration, exiting: \(identifier.rawValue)")
                    return
                }
                
                Log.database.info("Running migration: \(identifier.rawValue)")
                do {
                    let transaction = GRDBWriteTransaction(database: database)
                    let result = try migrate(transaction)
                    switch result {
                    case .success:
                        let timeElapsed = CACurrentMediaTime() - startTime
                        let formattedTime = String(format: "%0.2fms", timeElapsed * 1000)
                        Log.database.notice("Migration completed: \(identifier.rawValue), duration: \(formattedTime)")
                    case .failure(let error):
                        fatalError("Migration \(identifier) failed with returned error: \(error)")
                    }
                    transaction.finalizeTransaction()
                } catch {
                    fatalError("Migration \(identifier) failed with thrown error: \(error)")
                }
            }
        }
        
        func migrate(_ database: DatabaseWriter) throws {
            try migrator.migrate(database)
        }
    }
    
    private static func registerSchemaMigrations(migrator: DatabaseMigratorWrapper) {

        migrator.registerMigration(.createInitialSchema) { _ in
            fatalError("This migration should have already been run by the last GRDB migration.")
            //return .success(())
        }

        migrator.registerMigration(.addGradientAvatarToSmsAccount) { transaction in
            let columns = try transaction.database.columns(in: "smsAccount")
            guard !columns.contains(where: { $0.name == "gradientAvatar" }) else {
                return .success(())
            }
            try transaction.database.alter(table: "smsAccount") { t in
                t.add(column: "gradientAvatar", .text)
            }
            return .success(())
        }

    }
}

private func hasRunMigration(_ identifier: String, transaction: GRDBReadTransaction) -> Bool {
    do {
        return try String.fetchOne(transaction.database, sql: "SELECT identifier FROM grdb_migrations WHERE identifier = ?", arguments: [identifier]) != nil
    } catch {
        fatalError("Error: \(error)")
    }
}

private func insertMigration(_ identifier: String, db: Database) {
    do {
        try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
    } catch {
        fatalError("Error: \(error)")
    }
}
