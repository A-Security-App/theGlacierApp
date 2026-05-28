//
//  DBManager.swift
//  Glacier
//
//  Created by andyfriedman on 12/29/22.
//  Copyright © 2022 Glacier. All rights reserved.
//

import UIKit
import GRDB
import SAMKeychain
import Foundation

/// DBManager lets the application access the database.
///
/// It applies the pratices recommended at
/// <https://github.com/groue/GRDB.swift/blob/master/Documentation/GoodPracticesForDesigningRecordTypes.md>
@objc public class DBManager: Transactable {
    
    private static let shared = DBManager()
    
    private var _grdbStorage: DBStorageCoordinator?
    private var hasPendingCrossProcessWrite = false
    private var needsDataMigration = false
    //public var dbStatements = DBStatements()
    
    @objc
    public static let didSetupDatabase = Notification.Name("didSetupGRDB")
    
    @objc public var grdbStorage: DBStorageCoordinator {
        if let storage = _grdbStorage {
            return storage
        } else {
            let storage = createGrdbStorage()
            _grdbStorage = storage
            return storage
        }
    }
    
    @objc public class func sharedDB() -> DBManager {
        return shared
    }
    
    @objc public class func setMigrateData() -> DBManager {
        return shared
    }
    
    override init() {
        do {
            // Crash if keychain is inaccessible or database can't be created
            try DBStorageCoordinator.ensureDatabaseKeySpecExists()
        } catch {
            fatalError("Cannot create GRDB: \(error)")
        }
        
        super.init()
        needsDataMigration = !DBStorageCoordinator.existsGlacierGRDB()
        let storage = grdbStorage
        
        DispatchQueue.global().async {
            self.runGrdbSchemaMigrationsOnMainDatabase(completion: { () in
                //alert app that migration completed
                Log.database.notice("ran Migrations")
#if !TARGET_IS_EXTENSION
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: DBManager.didSetupDatabase, object: self)
                }
                
                self.grdbStorage.setStorageFileProtections()
#endif
            })
        }
#if !TARGET_IS_EXTENSION
        addObservers()
#endif
    }
    
    private static func clearDBKeychain() {
        var error: NSError?
        SAMKeychain.deletePassword(forService: kServiceName, account: GlacierGRDBPassphraseAccountName, accessGroup: kGlacierKeyGroup, error: nil)
        if let error = error {
            Log.database.error("Error deleting DB password from keychain: \(error.localizedDescription) \(error.userInfo)")
        }

        error = nil
        SAMKeychain.deletePassword(forService: kGlacierSalt, account: GlacierGRDBPassphraseAccountName, accessGroup:kGlacierKeyGroup, error: nil)
        if let error = error {
            Log.database.error("Error deleting DB salt from keychain: \(error.localizedDescription) \(error.userInfo)")
        }

        error = nil
        SAMKeychain.deletePassword(forService: kGlacierMediaSalt, account: GlacierGRDBPassphraseAccountName, accessGroup:kGlacierKeyGroup, error: nil)
        if let error = error {
            Log.database.error("Error deleting media salt from keychain: \(error.localizedDescription) \(error.userInfo)")
        }

        error = nil
        SAMKeychain.deletePassword(forService: kGlacierKeySpec, account: GlacierGRDBPassphraseAccountName, accessGroup:kGlacierKeyGroup, error: nil)
        if let error = error {
            Log.database.error("Error deleting DB keyspec from keychain: \(error.localizedDescription) \(error.userInfo)")
        }

        error = nil
        SAMKeychain.deletePassword(forService: kGlacierKeySpec, account: GlacierGRDBPassphraseAccountName, accessGroup:kGlacierKeyGroup, error: nil)
        if let error = error {
            Log.database.error("Error deleting DB keyspec data from keychain: \(error.localizedDescription) \(error.userInfo)")
        }

        error = nil
        SAMKeychain.deletePassword(forService: kGlacierMediaKeySpec, account: GlacierGRDBPassphraseAccountName, accessGroup:kGlacierKeyGroup, error: nil)
        if let error = error {
            Log.database.error("Error deleting media keyspec from keychain: \(error.localizedDescription) \(error.userInfo)")
        }
    }
    
    func resetDB() {
        self.deleteGrdbFiles()
        DBStorageCoordinator.clearStoredPassword()
        do {
            // Crash if keychain is inaccessible or database can't be created
            try DBStorageCoordinator.ensureDatabaseKeySpecExists()
        } catch {
            fatalError("Cannot create KeySpec: \(error)")
        }
        
        _grdbStorage = nil
        _ = grdbStorage
        
        DispatchQueue.global().async {
            self.runGrdbSchemaMigrationsOnMainDatabase(completion: { () in
                //alert app that migration completed
                Log.database.notice("ran Migrations")
                /*DispatchQueue.main.async {
                    NotificationCenter.default.post(name: DBManager.didSetupDatabase, object: self)
                }*/
            })
        }
    }
    
    private func addObservers() {
            // Cross process writes
        /*crossProcess.callback = { [weak self] in
            DispatchQueue.main.async {
                self?.handleCrossProcessWrite()
            }
        }*/
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name:UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    func createGrdbStorage() -> DBStorageCoordinator {
        return DBStorageCoordinator()
    }

    @objc public func deleteGrdbFiles() {
        DBStorageCoordinator.removeAllFiles()
    }

    @objc public func resetAllStorage() {
        //DBStorageCoordinator.resetAllStorage()
    }
    
    // completion is performed on the main queue.
    @objc public func runGrdbSchemaMigrationsOnMainDatabase(completion: @escaping () -> Void) {
        let didPerformIncrementalMigrations: Bool = {
            do {
                return try DBSchemaCoordinator.migrateDatabase(
                    databaseStorage: grdbStorage,
                    isMainDatabase: true
                )
            } catch {
                //DatabaseCorruptionState.flagDatabaseCorruptionIfNecessary(
                //    userDefaults: CurrentAppContext().appUserDefaults(),
                //    error: error
                //)
                fatalError("Database migration failed. Error: \(error.grdbErrorForLogging)")
            }
        }()

        Log.database.notice("didPerformIncrementalMigrations: \(didPerformIncrementalMigrations)")

        if didPerformIncrementalMigrations {
            reopenGRDBStorage(completion: completion)
        } else {
            DispatchQueue.main.async(execute: completion)
        }
    }
    
    public func reopenGRDBStorage(completion: @escaping () -> Void = {}) {
        // There seems to be a rare issue where at least one reader or writer
        // (e.g. SQLite connection) in the GRDB pool ends up "stale" after
        // a schema migration and does not reflect the migrations.
        grdbStorage.pool.releaseMemory()
        _grdbStorage = createGrdbStorage()

        DispatchQueue.main.async {
            completion()
        }
    }

    
    @objc func didBecomeActive() {
        //AssertIsOnMainThread()

        //guard hasPendingCrossProcessWrite else {
        //    return
        //}
        //hasPendingCrossProcessWrite = false

        //postCrossProcessNotificationActiveAsync()
    }
    
    private func handleCrossProcessWrite() {
        //AssertIsOnMainThread()

        //guard CurrentAppContext().isMainApp else {
        //    return
        //}

        // Post these notifications always, sync.
        NotificationCenter.default.post(name: DBManager.didReceiveCrossProcessNotificationAlwaysSync, object: nil, userInfo: nil)

        // Post these notifications async and defer if inactive.
        //if Application.shared.applicationState == .active {
        //if CurrentAppContext().isMainAppAndActive {
            // If already active, update immediately.
            postCrossProcessNotificationActiveAsync()
        //} else {
            // If not active, set flag to update when we become active.
            //hasPendingCrossProcessWrite = true
        //}
    }

    @objc
    public static let didReceiveCrossProcessNotificationActiveAsync = Notification.Name("didReceiveCrossProcessNotificationActiveAsync")
    @objc
    public static let didReceiveCrossProcessNotificationAlwaysSync = Notification.Name("didReceiveCrossProcessNotificationAlwaysSync")

    private func postCrossProcessNotificationActiveAsync() {
        // TODO: The observers of this notification will inevitably do
        //       expensive work.  It'd be nice to only fire this event
        //       if this had any effect, if the state of the database
        //       has changed.
        //
        //       In the meantime, most (all?) cross process write notifications
        //       will be delivered to the main app while it is inactive. By
        //       de-bouncing notifications while inactive and only updating
        //       once when we become active, we should be able to effectively
        //       skip most of the perf cost.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: DBManager.didReceiveCrossProcessNotificationActiveAsync, object: nil)
        }
    }

    // MARK: - Transactable

    public override func read(file: String = #file,
                              function: String = #function,
                              line: Int = #line,
                              block: (GRDBReadTransaction) -> Void) {
        //InstrumentsMonitor.measure(category: "db", parent: "read", name: Self.owsFormatLogMessage(file: file, function: function, line: line)) {
            do {
                try grdbStorage.read { transaction in
                    block(transaction)
                }
            } catch {
                fatalError("error: \(error.grdbErrorForLogging)")
            }
        //}
    }

    @objc(readWithBlock:)
    public func readObjC(block: (GRDBReadTransaction) -> Void) {
        read(file: "objc", function: "block", line: 0, block: block)
    }

    @objc(readWithBlock:file:function:line:)
    public func readObjC(block: (GRDBReadTransaction) -> Void, file: UnsafePointer<CChar>, function: UnsafePointer<CChar>, line: Int) {
        read(file: String(cString: file), function: String(cString: function), line: line, block: block)
    }

    // NOTE: This method is not @objc. See SDSDatabaseStorage+Objc.h.
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
                try grdbStorage.write { transaction in
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
    
    /// Provides access to the database.
    ///
    /// Application can use a `DatabasePool`, and tests can use a fast
    /// in-memory `DatabaseQueue`.
    ///
    /// See <https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databaseconnections>
    //private let dbWriter: any DatabaseWriter
}

#if !TARGET_IS_EXTENSION
extension DBManager {
    @objc public static func deleteAll() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                try PhoneAccount.deleteAll(transaction.database)
            } catch {
                Log.database.debug("PhoneAccount.removeAll: \(error)")
            }
            
        })
    }
}
#endif

public extension NSString {
    
    /// Create `Data` from hexadecimal string representation
    ///
    /// This takes a hexadecimal representation and creates a `Data` object. Note, if the string has any spaces or non-hex characters (e.g. starts with '<' and with a '>'), those are ignored and only hex characters are processed.
    ///
    /// - returns: Data represented by this hexadecimal string.
    
    @objc func dataFromHex() -> Data? {
        let characters = (self as String)
        var data = Data(capacity: characters.count / 2)
        
        let regex = try! NSRegularExpression(pattern: "[0-9a-f]{1,2}", options: .caseInsensitive)
        regex.enumerateMatches(in: (self as String), options: [], range: NSMakeRange(0, characters.count)) { match, flags, stop in
            let byteString = (self as NSString).substring(with: match!.range)
            var num = UInt8(byteString, radix: 16)!
            data.append(&num, count: 1)
        }
        
        guard data.count > 0 else {
            return nil
        }
        
        return data
    }
}
