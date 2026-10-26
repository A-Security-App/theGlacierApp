//
//  AppDatabaseSchema.swift
//  Glacier
//

import Foundation
import GRDB

/// The app database's tables and the migrations that build them.
///
/// Migration identifiers are recorded in `grdb_migrations` on every install, so they are
/// permanent: renaming one makes GRDB run it again. Installs from older builds may also have
/// identifiers recorded that are no longer registered here; GRDB ignores those.
///
/// The table, column and index names match what existing installs already have on disk.
enum AppDatabaseSchema {
    static let accountTable = "glacierAccount"
    static let phoneAccountTable = "SMSAccount"
    static let callRecordTable = "CallRecord"

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createInitialSchema") { db in
            try db.create(table: accountTable, options: .ifNotExists) { t in
                t.column("id", .integer).notNull().primaryKey(autoincrement: true)
                t.column("uniqueId", .text).notNull().unique(onConflict: .fail)
                t.column("username", .text)
                t.column("useStageConsole", .boolean).notNull().defaults(to: false)
                t.column("rebootReminderEnabled", .boolean).notNull().defaults(to: true)
                t.column("dnsEncryptionEnabled", .boolean).notNull().defaults(to: false)
                t.column("vpnEnabled", .boolean).notNull().defaults(to: false)
                t.column("loginDate", .double)
                t.column("apiKey", .text)
                t.column("avatarData", .blob)
                t.column("password", .text)
                t.column("modified", .date)
            }
            try db.create(index: "index_Account_on_accountKey", on: accountTable, columns: ["uniqueId"], options: .ifNotExists)

            // `gradientAvatar` is added by the next migration.
            try db.create(table: phoneAccountTable, options: .ifNotExists) { t in
                t.column("id", .integer).notNull().primaryKey(autoincrement: true)
                t.column("uniqueId", .text).notNull().unique(onConflict: .fail)
                t.column("twilioId", .text).notNull()
                t.column("phoneNumber", .text).notNull()
                t.column("displayName", .text)
                t.column("color", .text)
                t.column("modified", .date)
            }
            try db.create(index: "index_SMSAccount_on_uniqueId", on: phoneAccountTable, columns: ["uniqueId"], options: .ifNotExists)

            try db.create(table: callRecordTable, options: .ifNotExists) { t in
                t.column("id", .integer).notNull().primaryKey(autoincrement: true)
                t.column("uniqueId", .text).notNull().unique(onConflict: .fail)
                t.column("twilioSid", .text)
                t.column("name", .text)
                t.column("phoneNumber", .text)
                t.column("isIncoming", .boolean).notNull().defaults(to: true)
                t.column("to", .text)
                t.column("toFormatted", .text)
                t.column("from", .text)
                t.column("fromFormatted", .text)
                t.column("status", .text)
                t.column("startTime", .text)
                t.column("endTime", .text)
                t.column("duration", .text)
                t.column("modified", .date)
            }
            try db.create(index: "index_CallRecord_on_twilioSid", on: callRecordTable, columns: ["twilioSid"], options: .ifNotExists)
        }

        migrator.registerMigration("addGradientAvatarToSmsAccount") { db in
            // Installs that created their schema from a later build already have the column.
            let columns = try db.columns(in: phoneAccountTable)
            guard !columns.contains(where: { $0.name == "gradientAvatar" }) else {
                return
            }
            try db.alter(table: phoneAccountTable) { t in
                t.add(column: "gradientAvatar", .text)
            }
        }

        return migrator
    }
}
