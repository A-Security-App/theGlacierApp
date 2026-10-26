import XCTest
import GRDB
@testable import Glacier

/// `AppDatabase` has to open the encrypted databases that earlier builds left on users' devices
/// and keep their data. These tests build such a database with the earlier builds' schema,
/// migration records and encryption settings, then open it with the current code.
final class AppDatabaseUpgradeTests: XCTestCase {

    private var directory: URL!
    private let passphrase = DatabaseKey.passphrase(for: Data((0..<DatabaseKey.byteCount).map { UInt8($0) }))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDatabaseUpgradeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Upgrades

    func testInstallFromRecentBuildOpensWithItsData() throws {
        let url = try makeExistingDatabase(hasGradientAvatar: true, migrations: Self.recentBuildMigrations)

        let database = try open(url)
        try database.migrate()

        let account = try XCTUnwrap(database.read { db in try GlacierAccount.fetchOne(db) })
        XCTAssertEqual(account.uniqueId, "account-1")
        XCTAssertEqual(account.username, "person@example.com")
        XCTAssertTrue(account.vpnEnabled)
        XCTAssertFalse(account.dnsEncryptionEnabled)

        let phoneAccounts = try database.read { db in try PhoneAccount.fetchAll(db) }
        XCTAssertEqual(phoneAccounts.map(\.phoneNumber), ["+15551234567"])
        XCTAssertEqual(phoneAccounts.first?.gradientAvatar, "gradient-3")

        let calls = try database.read { db in try CallRecord.fetchAll(db) }
        XCTAssertEqual(calls.map(\.twilioSid), ["CA0001"])
        XCTAssertEqual(calls.first?.isIncoming, true)
        XCTAssertEqual(calls.first?.remotePhoneNumber, "+15557654321")

        // Nothing re-ran and nothing was forgotten, including identifiers no longer registered.
        XCTAssertEqual(try appliedMigrations(database), Set(Self.recentBuildMigrations))
    }

    func testInstallFromFirstBuildGainsGradientAvatarColumn() throws {
        let url = try makeExistingDatabase(hasGradientAvatar: false, migrations: Self.firstBuildMigrations)

        let database = try open(url)
        try database.migrate()

        let columns = try database.read { db in try db.columns(in: AppDatabaseSchema.phoneAccountTable).map(\.name) }
        XCTAssertTrue(columns.contains("gradientAvatar"))

        let phoneAccounts = try database.read { db in try PhoneAccount.fetchAll(db) }
        XCTAssertEqual(phoneAccounts.map(\.phoneNumber), ["+15551234567"])
        XCTAssertNil(phoneAccounts.first?.gradientAvatar)

        XCTAssertEqual(try appliedMigrations(database), Set(Self.firstBuildMigrations + ["addGradientAvatarToSmsAccount"]))
    }

    func testFreshInstallMatchesExistingInstallSchema() throws {
        let existing = try open(try makeExistingDatabase(hasGradientAvatar: true, migrations: Self.recentBuildMigrations))
        let fresh = try open(directory.appendingPathComponent("fresh.sqlite"))
        try fresh.migrate()

        for table in [AppDatabaseSchema.accountTable, AppDatabaseSchema.phoneAccountTable, AppDatabaseSchema.callRecordTable] {
            XCTAssertEqual(try columnShapes(fresh, table), try columnShapes(existing, table), table)
            XCTAssertEqual(try indexShapes(fresh, table), try indexShapes(existing, table), table)
        }
        XCTAssertEqual(try appliedMigrations(fresh), ["createInitialSchema", "addGradientAvatarToSmsAccount"])
    }

    // MARK: - Encryption

    func testFileIsEncryptedWithPlaintextHeader() throws {
        let url = directory.appendingPathComponent("header.sqlite")
        try createAndClose(url)

        let bytes = try Data(contentsOf: url)
        // The 32-byte SQLite header stays readable; the schema after it does not.
        XCTAssertEqual(bytes.prefix(16), Data("SQLite format 3\0".utf8))
        XCTAssertNil(bytes.range(of: Data("CREATE TABLE".utf8)))
    }

    func testWrongKeyCannotReadDatabase() throws {
        let url = directory.appendingPathComponent("key.sqlite")
        try createAndClose(url)

        let otherPassphrase = DatabaseKey.passphrase(for: Data(repeating: 0xAB, count: DatabaseKey.byteCount))
        XCTAssertThrowsError(try DatabaseQueue(path: url.path, configuration: AppDatabase.configuration(passphrase: otherPassphrase)).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master")
        })
    }

    func testPassphraseIsRawKeyNotation() {
        let passphrase = DatabaseKey.passphrase(for: Data([0x00, 0x0F, 0xA0, 0xFF]))
        XCTAssertEqual(passphrase, "x'000fa0ff'")
        XCTAssertEqual(self.passphrase.count, 2 + DatabaseKey.byteCount * 2 + 1)
    }

    // MARK: - Records

    func testUpsertAndDeleteMatchRowsByUniqueId() throws {
        let database = try open(directory.appendingPathComponent("records.sqlite"))
        try database.migrate()

        var record = PhoneAccount(uniqueId: "phone-1", phoneNumber: "+15551234567", twilioId: "PN1", displayName: "Work", color: nil, gradientAvatar: nil)
        try database.write { db in try record.upsert(db) }
        // A copy that has never seen the row's id still updates it rather than inserting another.
        record.displayName = "Personal"
        record.id = nil
        try database.write { db in try record.upsert(db) }

        let stored = try database.read { db in try PhoneAccount.fetchAll(db) }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.displayName, "Personal")
        XCTAssertNotNil(stored.first?.id)

        try database.write { db in try record.deleteByUniqueId(db) }
        XCTAssertEqual(try database.read { db in try PhoneAccount.fetchCount(db) }, 0)
    }

    // MARK: - Fixture

    /// What a database created by the first build records in `grdb_migrations`.
    private static let firstBuildMigrations = [
        "createInitialSchema",
        "dataMigration_populateGalleryItems",
        "dataMigration_markOnboardedUsers_v2",
        "dataMigration_clearLaunchScreenCache",
        "dataMigration_enableV2RegistrationLockIfNecessary",
        "dataMigration_resetStorageServiceData",
    ]

    /// What a database created by a build since `gradientAvatar` was added records.
    private static let recentBuildMigrations = firstBuildMigrations + ["addGradientAvatarToSmsAccount"]

    private func open(_ url: URL) throws -> AppDatabase {
        AppDatabase(writer: try DatabasePool(path: url.path, configuration: AppDatabase.configuration(passphrase: passphrase)))
    }

    /// Creates a migrated database and closes it, which folds the write-ahead log into the file.
    private func createAndClose(_ url: URL) throws {
        let pool = try DatabasePool(path: url.path, configuration: AppDatabase.configuration(passphrase: passphrase))
        try AppDatabase(writer: pool).migrate()
        try pool.close()
    }

    /// Builds a database the way earlier builds left it on disk: their table definitions
    /// (including tables no current code reads), their migration records, and one row per table.
    private func makeExistingDatabase(hasGradientAvatar: Bool, migrations: [String]) throws -> URL {
        let url = directory.appendingPathComponent("existing-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path, configuration: AppDatabase.configuration(passphrase: passphrase))
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE keyvalue (KEY TEXT NOT NULL, collection TEXT NOT NULL, VALUE BLOB NOT NULL, PRIMARY KEY (KEY, collection));
                CREATE TABLE IF NOT EXISTS "SMSAccount" (
                    "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    "uniqueId" TEXT NOT NULL UNIQUE ON CONFLICT FAIL,
                    "twilioId" TEXT NOT NULL,
                    "phoneNumber" TEXT NOT NULL,
                    "displayName" TEXT,
                    \(hasGradientAvatar ? "\"gradientAvatar\" TEXT," : "")
                    "color" TEXT,
                    "modified" DATE
                );
                CREATE TABLE IF NOT EXISTS "SMSConversation" ("id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, "uniqueId" TEXT NOT NULL UNIQUE ON CONFLICT FAIL);
                CREATE TABLE IF NOT EXISTS "SMSMessage" ("id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, "uniqueId" TEXT NOT NULL UNIQUE ON CONFLICT FAIL);
                CREATE TABLE IF NOT EXISTS "SMSMediaItem" ("id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, "uniqueId" TEXT NOT NULL UNIQUE ON CONFLICT FAIL);
                CREATE TABLE IF NOT EXISTS "CallRecord" (
                    "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    "uniqueId" TEXT NOT NULL UNIQUE ON CONFLICT FAIL,
                    "twilioSid" TEXT,
                    "name" TEXT,
                    "phoneNumber" TEXT,
                    "isIncoming" BOOLEAN NOT NULL DEFAULT 1,
                    "to" TEXT,
                    "toFormatted" TEXT,
                    "from" TEXT,
                    "fromFormatted" TEXT,
                    "status" TEXT,
                    "startTime" TEXT,
                    "endTime" TEXT,
                    "duration" TEXT,
                    "modified" DATE
                );
                CREATE INDEX "index_CallRecord_on_twilioSid" ON "CallRecord"("twilioSid");
                CREATE INDEX "index_SMSAccount_on_uniqueId" ON "SMSAccount"("uniqueId");
                CREATE TABLE IF NOT EXISTS "glacierAccount" (
                    "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    "uniqueId" TEXT NOT NULL UNIQUE ON CONFLICT FAIL,
                    "username" TEXT,
                    "useStageConsole" BOOLEAN NOT NULL DEFAULT 0,
                    "rebootReminderEnabled" BOOLEAN NOT NULL DEFAULT 1,
                    "dnsEncryptionEnabled" BOOLEAN NOT NULL DEFAULT 0,
                    "vpnEnabled" BOOLEAN NOT NULL DEFAULT 0,
                    "loginDate" DOUBLE,
                    "apiKey" TEXT,
                    "avatarData" BLOB,
                    "password" TEXT,
                    "modified" DATE
                );
                CREATE INDEX "index_Account_on_accountKey" ON "glacierAccount"("uniqueId");
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                """)
            for identifier in migrations {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
            }
            try db.execute(sql: """
                INSERT INTO glacierAccount (uniqueId, username, useStageConsole, rebootReminderEnabled, dnsEncryptionEnabled, vpnEnabled, modified)
                VALUES ('account-1', 'person@example.com', 0, 1, 0, 1, '2026-01-02 03:04:05.000');
                INSERT INTO SMSAccount (uniqueId, twilioId, phoneNumber, displayName, color, modified)
                VALUES ('phone-1', 'PN1', '+15551234567', '+15551234567', NULL, '2026-01-02 03:04:05.000');
                INSERT INTO CallRecord (uniqueId, twilioSid, name, phoneNumber, isIncoming, "to", toFormatted, "from", fromFormatted, status, startTime, endTime, duration, modified)
                VALUES ('call-1', 'CA0001', 'Caller', '+15557654321', 1, '+15551234567', '(555) 123-4567', '+15557654321', '(555) 765-4321', 'completed', '2026-01-02T03:04:05Z', '2026-01-02T03:05:05Z', '60', '2026-01-02 03:05:05.000');
                """)
            if hasGradientAvatar {
                try db.execute(sql: "UPDATE SMSAccount SET gradientAvatar = 'gradient-3'")
            }
        }
        try queue.close()
        return url
    }

    private func appliedMigrations(_ database: AppDatabase) throws -> Set<String> {
        try database.read { db in try Set(String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")) }
    }

    private func columnShapes(_ database: AppDatabase, _ table: String) throws -> [String] {
        try database.read { db in
            try db.columns(in: table)
                .map { "\($0.name) \($0.type.uppercased()) notNull=\($0.isNotNull) default=\($0.defaultValueSQL ?? "-") pk=\($0.primaryKeyIndex)" }
                .sorted()
        }
    }

    private func indexShapes(_ database: AppDatabase, _ table: String) throws -> [String] {
        try database.read { db in
            try db.indexes(on: table).map { "\($0.name) \($0.columns) unique=\($0.isUnique)" }.sorted()
        }
    }
}
