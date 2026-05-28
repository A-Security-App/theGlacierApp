//
//  Transaction.swift
//  Glacier
//
//  Created by andyfriedman on 1/9/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import GRDB

// MARK: - Any*Transaction

@objc
public class GRDBReadTransaction: NSObject {

    public let database: Database

    public let startDate = Date()

    init(database: Database) {
        self.database = database
    }
}

// MARK: -

@objc
public class GRDBWriteTransaction: GRDBReadTransaction {

    private enum TransactionState {
        case open
        case finalizing
        case finalized
    }
    private var transactionState: TransactionState = .open

    override init(database: Database) {
        super.init(database: database)
    }

    deinit {
        if transactionState != .finalized {
            Log.database.debug("Write transaction not finalized.")
        }
    }

    // This method must be called before the transaction is deallocated.
    @objc
    public func finalizeTransaction() {
        guard transactionState == .open else {
            Log.database.debug("Write transaction finalized more than once.")
            return
        }
        transactionState = .finalizing
        performTransactionFinalizationBlocks()
        transactionState = .finalized
    }

    public typealias CompletionBlock = () -> Void
    internal var syncCompletions: [CompletionBlock] = []
    public struct AsyncCompletion {
        let queue: DispatchQueue
        let block: CompletionBlock
    }
    internal var asyncCompletions: [AsyncCompletion] = []

    @objc
    public func addSyncCompletion(block: @escaping CompletionBlock) {
        syncCompletions.append(block)
    }

    @objc
    public func addAsyncCompletion(queue: DispatchQueue, block: @escaping CompletionBlock) {
        asyncCompletions.append(AsyncCompletion(queue: queue, block: block))
    }

    fileprivate typealias TransactionFinalizationBlock = (_ transaction: GRDBWriteTransaction) -> Void
    private var transactionFinalizationBlocks = [String: TransactionFinalizationBlock]()
    private var removedFinalizationKeys = Set<String>()

    private func performTransactionFinalizationBlocks() {
        assert(transactionState == .finalizing)

        let blocksCopy = transactionFinalizationBlocks
        transactionFinalizationBlocks.removeAll()
        for (key, block) in blocksCopy {
            guard !removedFinalizationKeys.contains(key) else {
                continue
            }
            block(self)
        }
        assert(transactionFinalizationBlocks.isEmpty)
    }

    fileprivate func addTransactionFinalizationBlock(forKey key: String,
                                                     block: @escaping TransactionFinalizationBlock) {
        guard !removedFinalizationKeys.contains(key) else {
            // We shouldn't be adding finalizations for removed keys,
            // e.g. touching removed entities.
            Log.database.debug("Finalization unexpectedly added for removed key.")
            return
        }
        guard transactionState == .open else {
            // We're already finalizing; run the block immediately.
            block(self)
            return
        }
        if transactionFinalizationBlocks[key] != nil {
            //if !DebugFlags.reduceLogChatter {
            //    Logger.verbose("De-duplicating.")
            //}
        }
        // Always overwrite; we want to use the _last_ block.
        // For example, in the case of touching thread, a given
        // transaction might use multiple copies of a thread.
        // We want to touch the last copy of the thread that was
        // written to the database.
        transactionFinalizationBlocks[key] = block
    }

    fileprivate func addRemovedFinalizationKey(_ key: String) {
        guard !removedFinalizationKeys.contains(key) else {
            Log.database.debug("Finalization key removed twice.")
            return
        }
        removedFinalizationKeys.insert(key)
    }
}

// MARK: -

/*public extension StoreContext {
    var asTransaction: SDSAnyWriteTransaction {
        return self as! SDSAnyWriteTransaction
    }
}*/

// MARK: - Convenience Methods

public extension GRDBWriteTransaction {
    func executeUpdate(sql: String, arguments: StatementArguments = StatementArguments()) {
        do {
            let statement = try database.makeStatement(sql: sql)
            // TODO: We could use setArgumentsWithValidation for more safety.
            statement.setUncheckedArguments(arguments)
            try statement.execute()
        } catch {
            handleFatalDatabaseError(error)
        }
    }

    // This has significant perf benefits over database.execute()
    // for queries that we perform repeatedly.
    func executeWithCachedStatement(sql: String,
                                    arguments: StatementArguments = StatementArguments()) {
        do {
            let statement = try database.cachedStatement(sql: sql)
            // TODO: We could use setArgumentsWithValidation for more safety.
            statement.setUncheckedArguments(arguments)
            try statement.execute()
        } catch {
            handleFatalDatabaseError(error)
        }
    }
}

// MARK: -

public extension GRDB.Database {
    final func strictRead<T>(_ criticalSection: (_ database: GRDB.Database) throws -> T) -> T {
        do {
            return try criticalSection(self)
        } catch {
            handleFatalDatabaseError(error)
        }
    }
}

// MARK: -

private func handleFatalDatabaseError(_ error: Error) -> Never {
    //DatabaseCorruptionState.flagDatabaseCorruptionIfNecessary(
    //    userDefaults: CurrentAppContext().appUserDefaults(),
    //    error: error
    //)
    fatalError("Error: \(error)")
}

