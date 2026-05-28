//
//  GRDBRecord.swift
//  Glacier
//
//  Created by andyfriedman on 1/10/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB
//import DifferenceKit
//import CocoaLumberjack

public protocol GRDBRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    var id: Int64? { get mutating set }
    var uniqueId: String { get }
    //var modified: Date { get mutating set }
    static var databaseTableName: String { get }
    
    func storeInGRDB(completion: @escaping () -> Void)
    func save(completion: @escaping () -> Void)
    
    func hash(into hasher: inout Hasher)
    //func isContentEqual(to source: any GRDBRecord) -> Bool
}

public extension GRDBRecord {

    private var uniqueIdColumnName: String {
        return "uniqueId"
    }

    private var uniqueIdColumnValue: String {
        return self.uniqueId
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(self.uniqueId)
    }
    
    //static func == (lhs: any GRDBRecord, rhs: any GRDBRecord) -> Bool {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.uniqueId == rhs.uniqueId
    }
    
    /*func isContentEqual(to source: any GRDBRecord) -> Bool {
        return uniqueId == source.uniqueId && modified == source.modified
    }*/
    
    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = rowID
    }
    
    func storeInGRDB() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbSave(transaction: transaction)
        })
    }
    
    func storeInGRDB(completion: @escaping () -> Void) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbSave(transaction: transaction)
        }, completion: completion)
    }
    
    func save() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbSave(transaction: transaction)
        })
    }
    
    func save(completion: @escaping () -> Void) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbSave(transaction: transaction)
        }, completion: completion)
    }
    
    func remove(completion: @escaping () -> Void) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbRemove(transaction: transaction)
        }, completion: completion)
    }

    // This is a "fault-tolerant" save method that will upsert in production.
    // In DEBUG builds it will fail if the intention (insert v. update)
    // doesn't match the database contents.
    func grdbSave(transaction: GRDBWriteTransaction) {
        // GRDB TODO: the record has an id property, but we can't use it here
        //            until we modify the logic.
        //            grdbIdByUniqueId() verifies that the model hasn't been
        //            deleted from the db.
        if let grdbId: Int64 = grdbIdByUniqueId(transaction: transaction) {
            grdbUpdate(grdbId: grdbId, transaction: transaction)
        } else {
            grdbInsert(transaction: transaction)
        }
    }

    private func grdbUpdate(grdbId: Int64, transaction: GRDBWriteTransaction) {
        do {
            //need a deep copy here probably
            var recordCopy = self
            recordCopy.id = grdbId
            try recordCopy.update(transaction.database)
        } catch {
            fatalError("Update failed: \(error.grdbErrorForLogging)")
        }
    }

    private func grdbInsert(transaction: GRDBWriteTransaction) {
        do {
            var recordCopy = self
            try recordCopy.insert(transaction.database)
        } catch {
            fatalError("Insert failed: \(error.grdbErrorForLogging)")
        }
    }

    func grdbRemove(transaction: GRDBWriteTransaction) {
        do {
            //let tableName = tableMetadata.tableName
            let whereSQL = "\(uniqueIdColumnName.quotedDatabaseIdentifier)=?"
            let sql: String = "DELETE FROM \(Self.databaseTableName.quotedDatabaseIdentifier) WHERE \(whereSQL)"

            let statement = try transaction.database.cachedStatement(sql: sql)
            guard let arguments = StatementArguments([uniqueIdColumnValue]) else {
                fatalError("Could not convert values.")
            }
            // TODO: We could use setArgumentsWithValidation for more safety.
            statement.setUncheckedArguments(arguments)
            try statement.execute()
        } catch {
            //DatabaseCorruptionState.flagDatabaseCorruptionIfNecessary(
            //    userDefaults: CurrentAppContext().appUserDefaults(),
            //    error: error
            //)
            fatalError("Write failed: \(error.grdbErrorForLogging)")
        }
    }
}

// MARK: -

fileprivate extension GRDBRecord {

    func grdbIdByUniqueId(transaction: GRDBReadTransaction) -> Int64? {
        GRDBModel.grdbIdByUniqueId(tableName: Self.databaseTableName,
                                   uniqueIdColumnName: uniqueIdColumnName,
                                   uniqueIdColumnValue: uniqueIdColumnValue,
                                   transaction: transaction)
    }
}

// MARK: -

extension GRDBModel {
    static func grdbIdByUniqueId(tableName: String,//tableMetadata: GRDBTableMetadata,
                                 uniqueIdColumnName: String,
                                 uniqueIdColumnValue: String,
                                 transaction: GRDBReadTransaction) -> Int64? {
        do {
            //let tableName = tableMetadata.tableName
            let sql = "SELECT id FROM \(tableName.quotedDatabaseIdentifier) WHERE \(uniqueIdColumnName.quotedDatabaseIdentifier)=?"
            guard let value = try Int64.fetchOne(transaction.database, sql: sql, arguments: [uniqueIdColumnValue]) else {
                return nil
            }
            return value
        } catch {
            return nil
        }
    }
}

