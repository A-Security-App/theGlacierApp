//
//  DatabaseKey.swift
//  Glacier
//

import Foundation
import SAMKeychain

/// The SQLCipher key for the app database, kept in the shared keychain group.
///
/// The key is 48 random bytes used as a raw SQLCipher key: a 256-bit encryption key followed
/// by a 128-bit salt. The salt has to be part of the key because the database keeps its first
/// 32 bytes in plaintext (see `AppDatabase.configuration(passphrase:)`), which leaves SQLCipher
/// nowhere in the file to store one.
///
/// The service, account and access group are what existing installs already store the key
/// under. Changing any of them makes every existing database unreadable.
enum DatabaseKey {
    static let byteCount = 48

    enum Failure: Error {
        /// A database file exists but its key is missing or malformed. Generating a new key
        /// would not open the file, so this is reported instead of papering over it.
        case missingKeyForExistingDatabase
        case randomGenerationFailed(OSStatus)
        case keychainWriteFailed(Error?)
    }

    private static let service = kGlacierKeySpec
    private static let account = GlacierGRDBPassphraseAccountName

    /// Returns the stored key, creating one when there is no database yet.
    static func loadOrCreate(databaseExists: Bool) throws -> Data {
        if let key = load() {
            return key
        }
        guard !databaseExists else {
            throw Failure.missingKeyForExistingDatabase
        }
        let key = try randomKey()
        try store(key)
        return key
    }

    /// The key in SQLCipher's raw-key notation: `x'` + 96 hex digits + `'`.
    static func passphrase(for key: Data) -> String {
        "x'" + key.map { String(format: "%02x", $0) }.joined() + "'"
    }

    private static func load() -> Data? {
        let data = SAMKeychain.passwordData(forService: service, account: account, accessGroup: kGlacierKeyGroup, error: nil)
        guard let data, data.count == byteCount else {
            return nil
        }
        return data
    }

    private static func store(_ key: Data) throws {
        var error: NSError?
        guard SAMKeychain.setPasswordData(key, forService: service, account: account, accessGroup: kGlacierKeyGroup, error: &error) else {
            throw Failure.keychainWriteFailed(error)
        }
    }

    private static func randomKey() throws -> Data {
        var key = Data(count: byteCount)
        let status = key.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw Failure.randomGenerationFailed(status)
        }
        return key
    }
}
