//
//  StoredRecord.swift
//  Glacier
//

import Foundation
import GRDB

/// A row in one of the app database's tables.
///
/// Rows are identified by `uniqueId`, a UUID string assigned when the model is created. `id` is
/// SQLite's row id; it is not known until the record has been inserted, so saving and deleting
/// look rows up by `uniqueId` instead.
protocol StoredRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    var id: Int64? { get set }
    var uniqueId: String { get }
}

extension StoredRecord {

    func hash(into hasher: inout Hasher) {
        hasher.combine(uniqueId)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.uniqueId == rhs.uniqueId
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Updates the row with this record's `uniqueId`, or inserts one if there is none.
    func upsert(_ db: Database) throws {
        var record = self
        record.id = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM \(Self.databaseTableName.quotedDatabaseIdentifier) WHERE uniqueId = ?",
            arguments: [uniqueId]
        )
        if record.id == nil {
            try record.insert(db)
        } else {
            try record.update(db)
        }
    }

    /// Deletes the row with this record's `uniqueId`, if there is one.
    func deleteByUniqueId(_ db: Database) throws {
        try db.execute(
            sql: "DELETE FROM \(Self.databaseTableName.quotedDatabaseIdentifier) WHERE uniqueId = ?",
            arguments: [uniqueId]
        )
    }

    /// `upsert(_:)` on the background write queue; `completion` runs on the main queue.
    func saveInBackground(completion: @escaping () -> Void = {}) {
        AppDatabase.shared.asyncWrite({ db in try self.upsert(db) }, completion: completion)
    }
}
