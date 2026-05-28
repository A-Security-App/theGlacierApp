//
//  DBStorageCoordinator.swift
//  Glacier
//
//  Created by andyfriedman on 1/3/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import UIKit
import Foundation
import GRDB
import os
import SAMKeychain

@objc public class DBStorageCoordinator: Transactable {
    private static let dbname = "GlacierGRDB.sqlite"
    private static let mediadbname = "Glacier-media.sqlite"
    public static let kSQLCipherKeySpecLength: UInt = 48
    public static let kSqliteHeaderLength: UInt = 32
    
    private let storage: GRDBStorage

    public var pool: DatabasePool {
        return storage.pool
    }
    
    private static var keyspec: GRDBKeySpecSource {
        return GRDBKeySpecSource(keyServiceName: kGlacierKeySpec)
    }
    
    private let checkpointLock = OSAllocatedUnfairLock()
    
    // checkpointBudget should only be accessed while checkpointLock is acquired.
    private var checkpointBudget: Int = 0
    // lastSuccessfulCheckpointDate should only be accessed while checkpointLock is acquired.
    private var lastSuccessfulCheckpointDate: Date?
    
    override init() {
        
        do {
            // Create a folder for storing the SQLite database, as well as
            // the various temporary files created during normal database
            // operations (https://sqlite.org/tempfiles.html).
            
            //try DBStorageCoordinator.ensureDatabaseKeySpecExists()
            
            if !DBStorageCoordinator.existsGlacierGRDB(), let dbdir = DBStorageCoordinator.sharedDefaultDatabaseDirectory() {
                //let dbdir = sharedDefaultDatabaseDirectory()
                do {
                    try FileManager.default.createDirectory(at: dbdir, withIntermediateDirectories: true)
                    Log.database.info("Success")
                } catch {
                    Log.database.error("Failed to create directory: \(error)")
                }
            }
            
            // Connect to a database on disk
            // See https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databaseconnections
            if let dburl = DBStorageCoordinator.sharedGlacierGRDBURL() {
                storage = try GRDBStorage(dbURL: dburl, keyspec: DBStorageCoordinator.keyspec)
                super.init()
                return
            }
        } catch {
            // Replace this implementation with code to handle the error appropriately.
            // fatalError() causes the application to generate a crash log and terminate.
            //
            // Typical reasons for an error here include:
            // * The parent directory cannot be created, or disallows writing.
            // * The database is not accessible, due to permissions or data protection when the device is locked.
            // * The device is out of space.
            // * The database could not be migrated to its latest schema version.
            // Check the error message to determine what the actual problem was.
            fatalError("Unresolved error \(error)")
        }
        fatalError("could not create database")
    }
    
    public static func ensureDatabaseKeySpecExists() throws {
        do {
            //try keyspec.clear() //REMOVE!!!
            _ = try keyspec.fetchString()
            // Key exists and is valid.
            return
        } catch {
            Log.database.warning("Key not accessible: \(error)")
        }

            // Because we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            // the keychain will be inaccessible after device restart until
            // device is unlocked for the first time.  If the app receives
            // a push notification, we won't be able to access the keychain to
            // process that notification, so we should just terminate by throwing
            // an uncaught exception.
            /*var errorDescription = "CipherKeySpec inaccessible. New install, migration or no unlock since device restart?"
            if CurrentAppContext().isMainApp {
                let applicationState = CurrentAppContext().reportedApplicationState
                errorDescription += ", ApplicationState: \(NSStringForUIApplicationState(applicationState))"
            }
            Logger.error(errorDescription)
            Logger.flush()*/

            /*if CurrentAppContext().isMainApp {
                if CurrentAppContext().isInBackground() {
                    // Rather than crash here, we should have already detected the situation earlier
                    // and exited gracefully (in the app delegate) using isDatabasePasswordAccessible.
                    // This is a last ditch effort to avoid blowing away the user's database.
                    throw OWSAssertionError(errorDescription)
                }
            } else {
                throw OWSAssertionError("CipherKeySpec inaccessible; not main app.")
            }*/

            // At this point, either:
            //
            // * This is a new install so there's no existing password to retrieve.
            // * The keychain has become corrupt.
            
        let doesDBExist = DBStorageCoordinator.existsGlacierGRDB()
        if doesDBExist {
            throw KeychainError.failure(description: "could not load DB metadata")
        }

        keyspec.generateAndStore()
    }
    
    static func clearStoredPassword() {
        do {
            try keyspec.clear()
        } catch {
            Log.database.warning("Error: \(error)")
        }
    }

    static func prepareDatabase(db: Database, keyspec: GRDBKeySpecSource) throws {
        let keyspec = try keyspec.fetchString()
        try db.execute(sql: "PRAGMA key = \"\(keyspec)\"")
        try db.execute(sql: "PRAGMA cipher_plaintext_header_size = 32")
        /*if !CurrentAppContext().isMainApp {
                let perConnectionCacheSizeInKibibytes = 2000 / (GRDBStorage.maximumReaderCountInExtensions + 1)
                // Limit the per-connection cache size based on the number of possible readers.
                // (The default is 2000KiB per connection regardless of how many other connections there are).
                // The minus sign indicates that this is in KiB rather than the database's page size.
                // An alternative would be to use SQLite's "shared cache" mode to have a single memory pool,
                // but unfortunately that changes the locking model in a way GRDB doesn't support.
                try db.execute(sql: "PRAGMA \(prefix)cache_size = -\(perConnectionCacheSizeInKibibytes)")
        }*/
    }
    
    @objc public static func existsGlacierGRDB() -> Bool {
        if let dbpath = sharedGlacierGRDBPath() {
            return FileManager.default.fileExists(atPath: dbpath)
        }
        return false
    }
    
    fileprivate static func sharedGlacierGRDBURL() -> URL? {
        if let directory = sharedDefaultDatabaseDirectory() {
            return directory.appendingPathComponent(DBStorageCoordinator.dbname)
        }
        return nil;
    }
    
    static func sharedGlacierGRDBPath() -> String? {
        if let directory = sharedDefaultDatabaseDirectory() {
            return directory.appendingPathComponent(DBStorageCoordinator.dbname).path
        }
        return nil;
    }
    
    static func sharedDefaultDatabaseDirectory() -> URL? {
        if let groupUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kGlacierGroup) {
            // URL has support for paths instead of the String class
            return groupUrl.appendingPathComponent("Glacier")
        }
        return nil
    }
    
    @objc public static func removeAllFiles() {
        let fileManager = FileManager.default
        if let basepath = sharedGlacierGRDBPath() {
            do {
                try fileManager.removeItem(atPath: basepath)
                try fileManager.removeItem(atPath: basepath + "-wal")
                try fileManager.removeItem(atPath: basepath + "-shm")
            } catch {
                Log.database.warning("Error: \(error)")
            }
        }

        Self.removeMediaFiles()
    }
    
    public override func write(file: String = #file,
                               function: String = #function,
                               line: Int = #line,
                               block: (GRDBWriteTransaction) -> Void) {
        #if TESTABLE_BUILD
        if Thread.isMainThread &&
            AppReadiness.isAppReady {
            Logger.warn("Database write on main thread.")
        }
        #endif

        //let benchTitle = "Slow Write Transaction \(Self.owsFormatLogMessage(file: file, function: function, line: line))"
        //let timeoutThreshold = DebugFlags.internalLogging ? 0.1 : 0.5

        //InstrumentsMonitor.measure(category: "db", parent: "write", name: Self.owsFormatLogMessage(file: file, function: function, line: line)) {
            do {
                try self.write { transaction in
                    //Bench(title: benchTitle, logIfLongerThan: timeoutThreshold, logInProduction: true) {
                    block(transaction)
                    //}
                }
            } catch {
                fatalError("error: \(error.grdbErrorForLogging)")
            }
        //}
        //crossProcess.notifyChangedAsync()
    }

    public override func read(file: String = #file,
                              function: String = #function,
                              line: Int = #line,
                              block: (GRDBReadTransaction) -> Void) {
        //InstrumentsMonitor.measure(category: "db", parent: "read", name: Self.owsFormatLogMessage(file: file, function: function, line: line)) {
            do {
                try self.read { transaction in
                    block(transaction)
                }
            } catch {
                fatalError("error: \(error.grdbErrorForLogging)")
            }
        //}
    }
}

//For Media
extension DBStorageCoordinator {
    static func sharedGlacierMediaPath() -> String? {
        if let directory = sharedDefaultDatabaseDirectory() {
            return directory.appendingPathComponent(DBStorageCoordinator.mediadbname).path
        }
        return nil;
    }
    
    @objc public static func existsGlacierMediaDB() -> Bool {
        if let dbpath = sharedGlacierMediaPath() {
            return FileManager.default.fileExists(atPath: dbpath)
        }
        return false
    }
    
    func passwordForMedia() {
        
    }
    
    @objc public static func removeMediaFiles() {
        let fileManager = FileManager.default
        if let mediapath = sharedGlacierMediaPath() {
            do {
                try fileManager.removeItem(atPath: mediapath)
                try fileManager.removeItem(atPath: mediapath + "-wal")
                try fileManager.removeItem(atPath: mediapath + "-shm")
            } catch {
                Log.database.warning("Error removing media files: \(error)")
            }
        }
    }
    
    func setStorageFileProtections() {
        self.storage.setFileProtections()
    }
}

extension DBStorageCoordinator {

    #if TESTABLE_BUILD
    // TODO: We could eventually eliminate all nested transactions.
    private static let detectNestedTransactions = false

    // In debug builds, we can detect transactions opened within transaction.
    // These checks can also be used to detect unexpected "sneaky" transactions.
    @ThreadBacked(key: "canOpenTransaction", defaultValue: true)
    public static var canOpenTransaction: Bool
    #endif

    @discardableResult
    public func read<T>(block: (GRDBReadTransaction) throws -> T) throws -> T {

        #if TESTABLE_BUILD
        owsAssertDebug(Self.canOpenTransaction)
        // Check for nested tractions.
        if Self.detectNestedTransactions {
            // Check for nested tractions.
            Self.canOpenTransaction = false
        }
        defer {
            if Self.detectNestedTransactions {
                Self.canOpenTransaction = true
            }
        }
        #endif

        return try pool.read { database in
            try autoreleasepool {
                try block(GRDBReadTransaction(database: database))
            }
        }
    }

    @discardableResult
    public func write<T>(block: (GRDBWriteTransaction) throws -> T) throws -> T {

        var value: T!
        var thrown: Error?
        try write { (transaction) in
            do {
                value = try block(transaction)
            } catch {
                thrown = error
            }
        }
        if let error = thrown {
            throw error.grdbErrorForLogging
        }
        return value
    }

    @objc
    public func read(block: (GRDBReadTransaction) -> Void) throws {

        #if TESTABLE_BUILD
        //owsAssertDebug(Self.canOpenTransaction)
        if Self.detectNestedTransactions {
            // Check for nested tractions.
            Self.canOpenTransaction = false
        }
        defer {
            if Self.detectNestedTransactions {
                Self.canOpenTransaction = true
            }
        }
        #endif

        try pool.read { database in
            autoreleasepool {
                block(GRDBReadTransaction(database: database))
            }
        }
    }

    @objc
    public func write(block: (GRDBWriteTransaction) -> Void) throws {

        #if TESTABLE_BUILD
        //owsAssertDebug(Self.canOpenTransaction)
        // Check for nested tractions.
        if Self.detectNestedTransactions {
            // Check for nested tractions.
            Self.canOpenTransaction = false
        }
        defer {
            if Self.detectNestedTransactions {
                Self.canOpenTransaction = true
            }
        }
        #endif

        var syncCompletions: [GRDBWriteTransaction.CompletionBlock] = []
        var asyncCompletions: [GRDBWriteTransaction.AsyncCompletion] = []

        try pool.write { database in
            autoreleasepool {
                let transaction = GRDBWriteTransaction(database: database)
                block(transaction)
                transaction.finalizeTransaction()

                syncCompletions = transaction.syncCompletions
                asyncCompletions = transaction.asyncCompletions
            }
        }

        checkpointLock.withLock {
            checkpointIfNecessary()
        }

        // Perform all completions _after_ the write transaction completes.
        for block in syncCompletions {
            block()
        }

        for asyncCompletion in asyncCompletions {
            asyncCompletion.queue.async(execute: asyncCompletion.block)
        }
    }

    // This method should only be invoked with checkpointLock already acquired.
    private func checkpointIfNecessary() {
        // What Is Checkpointing?
        //
        // Checkpointing is the process of integrating the WAL into the main database file.
        // Without it, the WAL will grow indefinitely. A large WAL affects read performance.
        // Therefore we want to keep the WAL small.
        //
        // * The SQLite WAL consists of "frames", representing changes to the database.
        // * Frames are appended to the tail of the WAL.
        // * The WAL tracks how many of its frames have been integrated into the database.
        // * Checkpointing entails some subset of the following tasks:
        //   * Integrating some or all of the frames of the WAL into the database.
        //   * "Restarting" the WAL so the next frame is written to the head of the WAL
        //     file, not the tail. WAL file size doesn't change, but since subsequent writes
        //     overwrite from the start of the WAL, WAL file size growth can be bounded.
        //   * "Truncating" the WAL so that that the WAL file is deleted or returned to
        //     an empty state.
        //
        // The more unintegrated frames there are in the WAL, the longer a checkpoint takes
        // to complete. Long-running checkpoints can cause problems in the app, e.g.
        // blocking the main thread (note: we currently do _NOT_ checkpoint on the main
        // thread).  Therefore we want to bound overall WAL file size _and_ the number of
        // unintegrated frames.
        //
        // To bound WAL file size, it's important to periodically "restart" or (preferably)
        // truncate the WAL file. We currently always truncate.
        //
        // To bound the number of unintegrated frames, we can use passive checkpoints.
        // We don't explicitly initiate passive checkpoints, but leave this to SQLite
        // auto-checkpointing.
        //
        //
        // Checkpoint Types
        //
        // Checkpointing has several flavors: passive, full, restart, truncate.
        //
        // * Passive checkpoints abort immediately if there are any database
        //   readers or writers. This makes them "cheap" in the sense that
        //   they won't block for long.
        //   However they only integrate WAL contents, they don't "restart" or
        //   "truncate" so they don't inherently limit WAL growth.
        //   My understanding is that they can have partial success, e.g.
        //   integrating some but not all of the frames of the WAL. This is
        //   beneficial.
        // * Full/Restart/Truncate checkpoints will block using the busy-handler.
        //   We use truncate checkpoints since they truncate the WAL file.
        //   See GRDBStorage.buildConfiguration for our busy-handler (aka busyMode
        //   callback). It aborts after ~50ms.
        //   These checkpoints are more expensive and will block while they do
        //   their work but will limit WAL growth.
        //
        // SQLite has auto-checkpointing enabled by default, meaning that it
        // is continually trying to perform passive checkpoints in the background.
        // This is beneficial.
        //
        //
        // Exclusion
        //
        // Note that we are navigating multiple exclusion mechanisms.
        //
        // * SQLite (as we have configured it) excludes database writes using
        //   write locks (POSIX advisory locking on the database files).
        //   This locking protects the database from cross-process writes.
        // * GRDB writers use a serial DispatchQueue to exclude writes from
        //   each other within a given DatabasePool / DatabaseQueue.
        //   AFAIK this does not protect any GRDB internal state; it allows
        //   GRDB to detect re-entrancy, etc.
        //
        // SQLite cannot checkpoint if there are any readers or writers.
        // Therefore we cannot checkpoint within a SQLite write transaction.
        // We checkpoint after write transactions using
        // DatabasePool.writeWithoutTransaction().  This method uses the
        // GRDB exclusion mechanism but not the SQL one.
        //
        //
        // Our approach:
        //
        // * Always (not including auto-checkpointing) use truncate checkpoints
        //   to limit WAL size.
        // * Only checkpoint immediately after writes.
        // * It's expensive and unnecessary to do a checkpoint on every write,
        //   so we only checkpoint once every N writes. We always checkpoint after
        //   the first write.  Large (in terms of file size) writes should be rare,
        //   so WAL file size should be bounded and quite small.
        // * Use a "budget" to tracking the urgency of trying to perform a checkpoint after
        //   the next write.  When the budget reaches zero, we should try after the next
        //   write.  Successes bump up the budget considerably, failures bump it up a little.
        // * Retry more often after failures, via the budget.
        //
        //
        // What could go wrong:
        //
        // * Our busy-handler (aka busyMode callback) is untested. Previously it was
        //   irrelevant because we always performed checkpoints on a separate
        //   DatabaseQueue.
        //   It needs to work correctly to ensure that checkpoints timeout if there's
        //   heavy contention (reads or writes).
        // * Checkpointing could be expensive in some cases, causing blocking.
        //   This shouldn't be an issue: we're more aggressive than ever about
        //   keeping the WAL small.
        // * Cross-process activity could interfere with checkpointing.
        //   This shouldn't be an issue: We shouldn't have more than one of
        //   the apps (main app, SAE, NSE) active at the same time for long.
        // * Checkpoints might frequently fail if we're constantly doing reads.
        //   This shouldn't be an issue: A checkpoint should eventually
        //   succeed when db activity settles.  This checkpoint might take a while
        //   but that's unavoidable.
        //   The counter-argument is that we only try to checkpoint immediately after
        //   a write. We often do reads immediately after writes to update the UI
        //   to reflect the DB changes.  Those reads _might_ frequently interfere
        //   with checkpointing.
        // * We might not be checkpointing often enough, or we might be checkpointing
        //   too often.  Either way, it's about balancing overall perf with the perf
        //   cost of the next successful checkpoint.  We can tune this behavior
        //   using the "checkpoint budget".
        //
        // Reference
        //
        // * https://www.sqlite.org/c3ref/wal_checkpoint_v2.html
        // * https://www.sqlite.org/wal.html
        // * https://www.sqlite.org/howtocorrupt.html
        //
        guard !Thread.isMainThread else {
            // To avoid blocking the main thread, we avoid doing "truncate" checkpoints
            // on the main thread. We perhaps could do passive checkpoints on the main
            // thread, which abort if there is any contention.
            //
            // We decrement the checkpoint budget anyway.
            checkpointBudget -= 1
            return
        }
        var shouldCheckpoint = checkpointBudget <= 0

        // Limit checkpoint frequency by time so that heavy write activity
        // won't bog down the main thread.
        let maxCheckpointFrequency: TimeInterval = 0.25
        if shouldCheckpoint,
           let lastSuccessfulCheckpointDate = self.lastSuccessfulCheckpointDate,
           abs(lastSuccessfulCheckpointDate.timeIntervalSinceNow) < maxCheckpointFrequency {
            Log.database.debug("Skipping checkpoint due to frequency.")
            shouldCheckpoint = false
        }
        guard shouldCheckpoint else {
            // We decrement the checkpoint budget.
            checkpointBudget -= 1
            return
        }

        // Set checkpointTimeout flag.
        //owsAssertDebug(GRDBStorage.checkpointTimeout == nil)
        GRDBStorage.checkpointTimeout = GRDBStorage.maxBusyTimeoutMs
        //owsAssertDebug(GRDBStorage.checkpointTimeout != nil)
        defer {
            // Clear checkpointTimeout flag.
            //owsAssertDebug(GRDBStorage.checkpointTimeout != nil)
            GRDBStorage.checkpointTimeout = nil
            //owsAssertDebug(GRDBStorage.checkpointTimeout == nil)
        }

        // Hold a background task for the duration of the checkpoint so iOS does not kill
        // the process with 0xdead10cc (file lock held during suspension) if the user
        // backgrounds the app mid-fsync.
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "DBCheckpoint") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        defer {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }

        pool.writeWithoutTransaction { database in
            let kind: Database.CheckpointMode = .truncate

            var walSizePages: Int32 = 0
            var pagesCheckpointed: Int32 = 0
            var code: Int32 = 0
            //Bench(title: "Checkpoint",
                  //logIfLongerThan: TimeInterval(5) / TimeInterval(1000),
                  //logInProduction: true) {
                code = sqlite3_wal_checkpoint_v2(database.sqliteConnection,
                                                 nil,
                                                 kind.rawValue,
                                                 &walSizePages,
                                                 &pagesCheckpointed)
            //}
            if code != SQLITE_OK {
                // Extracting this error message can race.
                let errorMessage = String(cString: sqlite3_errmsg(database.sqliteConnection))
                if code == SQLITE_BUSY {
                    // It is expected that the busy-handler (aka busyMode callback)
                    // will abort checkpoints if there is contention.
                    Log.database.warning("checkpointIfNecessary Error code: \(code), errorMessage: \(errorMessage).")
                } else {
                    Log.database.error("checkpointIfNecessary Error code: \(code), errorMessage: \(errorMessage).")
                }
                // If the checkpoint failed, try again soon.
                checkpointBudget += 5
            } else {
                let pageSize: Int32 = 4 * 1024
                let walFileSizeBytes = walSizePages * pageSize
                let maxWalFileSizeBytes = 4 * 1024 * 1024
                if walFileSizeBytes > maxWalFileSizeBytes {
                    Log.database.debug("walFileSizeBytes: \(walFileSizeBytes).")
                    Log.database.debug("walSizePages: \(walSizePages), pagesCheckpointed: \(pagesCheckpointed).")
                } else {
                    Log.database.debug("walSizePages: \(walSizePages), pagesCheckpointed: \(pagesCheckpointed).")
                }
                // If the checkpoint succeeded, wait N writes before performing another checkpoint.
                checkpointBudget += 32
                lastSuccessfulCheckpointDate = Date()
            }
        }
    }
}

public enum KeychainError: Error {
    case failure(description: String)
    case missing(description: String)
}

public enum DBError: Error {
    case failure(description: String)
    case unexpected(description: String)
}


public struct GRDBKeySpecSource {

    private var kSQLCipherKeySpecLength: UInt {
        DBStorageCoordinator.kSQLCipherKeySpecLength
    }

    let keyServiceName: String
    //let keyName: String

    func fetchString() throws -> String {
        // Use a raw key spec, where the 96 hexadecimal digits are provided
        // (i.e. 64 hex for the 256 bit key, followed by 32 hex for the 128 bit salt)
        // using explicit BLOB syntax, e.g.:
        //
        // x'98483C6EB40B6C31A448C22A66DED3B5E5E8D5119CAC8327B655C8B5C483648101010101010101010101010101010101'
        //let trydata = try fetchData()

        guard let data = fetchData(), data.count == kSQLCipherKeySpecLength else {
            throw KeychainError.failure(description: "unexpected keyspec length")
        }

        let passphrase = "x'\(data.hexEncodedString())'"
        return passphrase
    }

    public func fetchData() -> Data? {
        return SAMKeychain.passwordData(forService: keyServiceName, account: GlacierGRDBPassphraseAccountName, accessGroup: kGlacierKeyGroup, error: nil)
    }

    func clear() throws {
        var error: NSError?
        let result = SAMKeychain.deletePassword(forService: keyServiceName, account: GlacierGRDBPassphraseAccountName, accessGroup: kGlacierKeyGroup, error: &error)
        let mediaResult = SAMKeychain.deletePassword(forService: keyServiceName, account: GlacierMediaPassphraseName, accessGroup: kGlacierKeyGroup, error: &error)
        if let error = error {
            throw KeychainError.failure(description: "error deleting password: \(error)")
        }
        guard result, mediaResult else {
            throw KeychainError.failure(description: "could not delete password")
        }
    }

    func generateAndStore() {
        do {
            let keyData = try secureRandomData(count: Int(kSQLCipherKeySpecLength))
            try store(data: keyData)
        } catch {
            fatalError("Could not generate key for GRDB: \(error)")
        }
        
        do {
            let mediaKeyData = try secureRandomData(count: Int(kSQLCipherKeySpecLength))
            try storeMedia(data: mediaKeyData)
        } catch {
            fatalError("Could not generate key for GRDB: \(error)")
        }
    }
    
    func fetchMediaString() throws -> String {
        
        guard let data = fetchMediaData(), data.count == kSQLCipherKeySpecLength else {
            throw KeychainError.failure(description: "unexpected keyspec length")
        }

        let passphrase = "x'\(data.hexEncodedString())'"
        return passphrase
    }
    
    public func fetchMediaData() -> Data? {
        return SAMKeychain.passwordData(forService: keyServiceName, account: GlacierMediaPassphraseName, accessGroup: kGlacierKeyGroup, error: nil)
    }
    
    //https://www.advancedswift.com/secure-random-number-swift/
    func secureRandomData(count: Int) throws -> Data {
        var bytes = [Int8](repeating: 0, count: count)

        // Fill bytes with secure random data
        let status = SecRandomCopyBytes(
            kSecRandomDefault,
            count,
            &bytes
        )
        
        // A status of errSecSuccess indicates success
        if status == errSecSuccess {
            // Convert bytes to Data
            let data = Data(bytes: bytes, count: count)
            return data
        }
        else {
            throw KeychainError.failure(description: "could not create random data")
        }
    }

    public func store(data: Data) throws {
        guard data.count == kSQLCipherKeySpecLength else {
            throw KeychainError.failure(description: "unexpected keyspec length")
        }
        var error: NSError?
        let result = SAMKeychain.setPasswordData(data, forService: keyServiceName, account: GlacierGRDBPassphraseAccountName, accessGroup: kGlacierKeyGroup, error: &error)
        if let error = error {
            throw KeychainError.failure(description: "error setting string: \(error)")
        }
        guard result else {
            throw KeychainError.failure(description: "could not store keyspec")
        }
    }
    
    public func storeMedia(data: Data) throws {
        guard data.count == kSQLCipherKeySpecLength else {
            throw KeychainError.failure(description: "unexpected keyspec length")
        }
        var error: NSError?
        let result = SAMKeychain.setPasswordData(data, forService: keyServiceName, account: GlacierMediaPassphraseName, accessGroup: kGlacierKeyGroup, error: &error)
        if let error = error {
            throw KeychainError.failure(description: "error setting string: \(error)")
        }
        guard result else {
            throw KeychainError.failure(description: "could not store media keyspec")
        }
    }
}

private struct GRDBStorage {

    let pool: DatabasePool

    private let dbURL: URL
    private let poolConfiguration: Configuration

    fileprivate static let maxBusyTimeoutMs = 50

    init(dbURL: URL, keyspec: GRDBKeySpecSource) throws {
        self.dbURL = dbURL

        self.poolConfiguration = Self.buildConfiguration(keyspec: keyspec)
        self.pool = try Self.buildPool(dbURL: dbURL, poolConfiguration: poolConfiguration)

#if !TARGET_IS_EXTENSION
        if let dbpath = DBStorageCoordinator.sharedDefaultDatabaseDirectory()?.path, let dburl = URL(string: dbpath) {
            do {
                try FileManager.default.setFileProtection(in: dburl, protectionType: .protectionKey, level: .completeUntilFirstUserAuthentication)
            } catch {
                Log.database.warning("Could not set file protection: \(error)")
            }
        }
#endif
    }

    func setFileProtections() {
#if !TARGET_IS_EXTENSION
        if let dbpath = DBStorageCoordinator.sharedDefaultDatabaseDirectory()?.path, let dburl = URL(string: dbpath) {
            do {
                try FileManager.default.setFileProtection(in: dburl, protectionType: .protectionKey, level: .completeUntilFirstUserAuthentication)
            } catch {
                Log.database.warning("Could not set file protection: \(error)")
            }
            do {
                try FileManager.default.excludeFilesFromBackup(in: dburl)
            } catch {
                Log.database.warning("Could not exclude files from backup: \(error)")
            }
        }
#endif
    }

    // See: https://github.com/groue/GRDB.swift/blob/master/Documentation/SharingADatabase.md
    private static func buildPool(dbURL: URL, poolConfiguration: Configuration) throws -> DatabasePool {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var newPool: DatabasePool?
        var dbError: Error?
        coordinator.coordinate(writingItemAt: dbURL,
                               options: .forMerging,
                               error: &coordinatorError,
                               byAccessor: { url in
            do {
                newPool = try DatabasePool(path: url.path, configuration: poolConfiguration)
            } catch {
                dbError = error
            }
        })
        if let error = dbError ?? coordinatorError {
            throw error
        }
        guard let pool = newPool else {
            throw DBError.failure(description: "Missing pool.")
        }
        
        return pool
    }

    // The checkpointTimeout flag is backed by a thread local.
    // We don't want to affect the behavior of the busy-handler (aka busyMode callback)
    // in other threads while checkpointing.
    fileprivate static var checkpointTimeoutKey: String { "GRDBStorage.checkpointTimeoutKey" }
    fileprivate static var checkpointTimeout: Int? {
        get {
            Thread.current.threadDictionary[Self.checkpointTimeoutKey] as? Int
        }
        set {
            Thread.current.threadDictionary[Self.checkpointTimeoutKey] = newValue
        }
    }

    fileprivate static var maximumReaderCountInExtensions: Int { 4 }

    private static func buildConfiguration(keyspec: GRDBKeySpecSource) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = false
        configuration.foreignKeysEnabled = true // Default is already true
        #if DEBUG
        configuration.publicStatementArguments = true
        #endif

        // TODO: We should set this to `false` (or simply remove this line, as `false` is the default).
        // Historically, we took advantage of SQLite's old permissive behavior, but the SQLite
        // developers [regret this][0] and may change it in the future.
        //
        // [0]: https://sqlite.org/quirks.html#dblquote
        //configuration.acceptsDoubleQuotedStringLiterals = true

        // Useful when your app opens multiple databases
        configuration.label = "GRDB Storage"
        //let isMainApp = CurrentAppContext().isMainApp
        configuration.maximumReaderCount = 10 //isMainApp ? 10 : maximumReaderCountInExtensions
        configuration.busyMode = .callback({ (retryCount: Int) -> Bool in
            // sleep N milliseconds
            let millis = 25
            usleep(useconds_t(millis * 1000))
            Log.database.debug("retryCount: \(retryCount)")
            let accumulatedWaitMs = millis * (retryCount + 1)
            if accumulatedWaitMs > 0, (accumulatedWaitMs % 250) == 0 {
                Log.database.warning("Database busy for \(accumulatedWaitMs)ms")
            }

            // Only time out during checkpoints, not writes.
            if let checkpointTimeout = self.checkpointTimeout {
                if accumulatedWaitMs > checkpointTimeout {
                    Log.database.warning("Aborting busy retry.")
                    return false
                }
                return true
            } else {
                return true
            }
        })
        configuration.prepareDatabase { db in
            try DBStorageCoordinator.prepareDatabase(db: db, keyspec: keyspec)

            //db.trace { dbQueryLog("\($0)") }

            //MediaGalleryManager.setup(database: db)
        }
        configuration.defaultTransactionKind = .immediate
        configuration.allowsUnsafeTransactions = true
        configuration.automaticMemoryManagement = false
        return configuration
    }
}

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}

public extension Error {
    var grdbErrorForLogging: Error {
        // If not a GRDB error, return unmodified.
        guard let grdbError = self as? GRDB.DatabaseError else {
            return self
        }
        // DatabaseError.description includes the arguments.
        Log.database.debug("grdbError: \(grdbError))")
        // DatabaseError.description does not include the extendedResultCode.
        Log.database.debug("resultCode: \(grdbError.resultCode), extendedResultCode: \(grdbError.extendedResultCode), message: \(String(describing: grdbError.message)), sql: \(String(describing: grdbError.sql))")
        let error = GRDB.DatabaseError(resultCode: grdbError.extendedResultCode,
                                       message: grdbError.message,
                                       sql: nil,
                                       arguments: nil)
        return error
    }
}

public extension FileManager {
    
    func excludeFilesFromBackup(in directory: URL) throws {
        //let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey]
        
        guard let enumerator = self.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            throw NSError(domain: "FileEnumeratorError", code: 2, userInfo: nil)
        }
        
        for case var fileURL as URL in enumerator {
            var isDirectory: ObjCBool = false
            if self.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try fileURL.setResourceValues(resourceValues)
            }
        }
    }
    
    func setFileProtection(
        in directory: URL,
        protectionType: FileAttributeKey = .protectionKey,
        level: FileProtectionType = .complete
    ) throws {
        //let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey]
        
        guard let enumerator = self.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            throw NSError(domain: "FileEnumeratorError", code: 1, userInfo: nil)
        }
        
        for case let fileURL as URL in enumerator {
            var isDirectory: ObjCBool = false
            if self.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                try self.setAttributes([.protectionKey: level], ofItemAtPath: fileURL.path)
            }
        }
    }
}
