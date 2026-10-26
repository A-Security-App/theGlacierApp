//
//  AppDatabase.swift
//  Glacier
//

import Foundation
import GRDB

/// The app's encrypted SQLite database: the signed-in account, phone accounts and call history.
///
/// `AppDatabase.shared` opens the file in the app group container with the key from
/// `DatabaseKey`, then runs migrations on a background queue and posts `didSetupDatabase`
/// on the main queue once they finish.
final class AppDatabase {

    static let didSetupDatabase = Notification.Name("didSetupGRDB")

    static let shared: AppDatabase = {
        do {
            return try AppDatabase.openShared()
        } catch {
            // Without the database there is no account to restore and nowhere to keep call
            // history, so there is no useful way to continue.
            fatalError("Could not open the app database: \(error)")
        }
    }()

    private let writer: any DatabaseWriter
    private let asyncWriteQueue = DispatchQueue(label: "com.theglacierapp.asyncWrite")

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - Access

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.read(block)
    }

    /// Runs `block` in a write transaction. A thrown error rolls the whole transaction back.
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    /// Runs `block` in a write transaction on a serial background queue, then calls
    /// `completion` on the main queue. A failed write is logged and rolled back; `completion`
    /// still runs.
    func asyncWrite(_ block: @escaping (Database) throws -> Void, completion: @escaping () -> Void = {}) {
        asyncWriteQueue.async {
            do {
                try self.writer.write(block)
            } catch {
                Log.database.error("Write failed: \(error)")
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: - Setup

    /// The configuration every connection is opened with. `passphrase` is the raw SQLCipher key
    /// from `DatabaseKey.passphrase(for:)`.
    static func configuration(passphrase: String) -> Configuration {
        var configuration = Configuration()
        configuration.label = "AppDatabase"
        configuration.busyMode = .timeout(10)
        #if DEBUG
        configuration.publicStatementArguments = true
        #endif
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA key = \"\(passphrase)\"")
            // Existing installs keep the 32-byte SQLite header unencrypted, so iOS can recognise
            // the file as a database it may leave open while the app is suspended. Every
            // connection has to agree on this or the file will not decrypt.
            try db.execute(sql: "PRAGMA cipher_plaintext_header_size = 32")
        }
        return configuration
    }

    func migrate() throws {
        try AppDatabaseSchema.migrator.migrate(writer)
    }

    private static func openShared() throws -> AppDatabase {
        guard let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: kGlacierGroup)?
            .appendingPathComponent("Glacier", isDirectory: true) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fileURL = directory.appendingPathComponent("GlacierGRDB.sqlite")
        let databaseExists = FileManager.default.fileExists(atPath: fileURL.path)

        let key = try DatabaseKey.loadOrCreate(databaseExists: databaseExists)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: fileURL.path, configuration: configuration(passphrase: DatabaseKey.passphrase(for: key)))
        let database = AppDatabase(writer: pool)

        DispatchQueue.global().async {
            do {
                try database.migrate()
            } catch {
                fatalError("Database migration failed: \(error)")
            }
            Log.database.notice("Database migrations complete")
            protectFiles(in: directory)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: AppDatabase.didSetupDatabase, object: database)
            }
        }
        return database
    }

    /// Keeps the database and its -wal/-shm files readable after first unlock (calls and pushes
    /// arrive while the device is locked) and out of device backups: the key is stored
    /// this-device-only, so a restored copy could never be opened.
    private static func protectFiles(in directory: URL) {
        let fileManager = FileManager.default
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            Log.database.warning("Could not list database files: \(error)")
            return
        }
        for var file in files {
            do {
                try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try file.setResourceValues(values)
            } catch {
                Log.database.warning("Could not protect \(file.lastPathComponent): \(error)")
            }
        }
    }
}
