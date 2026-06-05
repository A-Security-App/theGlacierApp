//
//  GlacierAccount.swift
//  Glacier
//
//  Created by andyfriedman on 8/13/25.
//  Copyright © 2025 Glacier. All rights reserved.
//
import UIKit
import Foundation
import GRDB
import SAMKeychain
import CryptoKit
open class GlacierAccountModel: GRDBModel {
    public static let defaultPort:UInt = 80
    public static let accountImage = UIImage(named: "glacier-logo")
    var grdbRecord:GlacierAccount?
    convenience init(account:GlacierAccount) {
        self.init(uniqueId: account.uniqueId)
        self.grdbRecord = account
    }
    convenience init(username:String) {
        self.init()
        grdbRecord = GlacierAccount(uniqueId: self.uniqueId, username: username, loginDate: nil, apiKey:nil, avatarData: nil, modified: nil)
    }
}
#if !TARGET_IS_EXTENSION
extension GlacierAccountModel {
    public var avatarData: Data? {
        get {
            return self.grdbRecord?.avatarData
        }
        set {
            if let avatarData = self.grdbRecord?.avatarData, avatarData != newValue {
                //GlacierImageCache.shared().removeImage(self.uniqueId)
                GlacierImages.removeImage(withIdentifier: self.uniqueId)
            }
            self.grdbRecord?.avatarData = newValue
        }
    }
}
#endif
extension GlacierAccountModel {
    func removeKeychainPassword(_ error:NSError?) throws {
        var error: NSError?
        let result = SAMKeychain.deletePassword(forService: kServiceName, account: self.uniqueId, accessGroup: kGlacierKeyGroup, error:&error) //need accessGroup: kGlacierKeyGroup?
        if let error = error {
            throw KeychainError.failure(description: "error deleting password: \(error)")
        }
        guard result else {
            throw KeychainError.failure(description: "could not delete password")
        }
    }
    public var password: String? {
        get {
            var error: NSError?
            let password = SAMKeychain.password(forService: kServiceName, account: self.uniqueId, accessGroup: kGlacierKeyGroup, error:&error)
            if (error != nil) {
                Log.database.error("Error retreiving password from keychain: \(String(describing: error?.localizedDescription)) \(String(describing: error?.userInfo))")
            }
            return password
        }
        set {
            guard let pass = newValue else { return }
            if pass.count == 0 {
                //NSAssert(password.length > 0, @"Improperly removing password!");
                Log.database.error("Improperly removing password! To remove password call removeKeychainPassword!")
                return
            }
            var error: NSError?
            let result = SAMKeychain.setPassword(pass, forService: kServiceName, account: self.uniqueId, accessGroup:kGlacierKeyGroup, error:&error)
            if result == false {
                Log.database.error("Error saving password to keychain: \(String(describing: error?.localizedDescription)) \(String(describing: error?.userInfo))")
            }
        }
    }
    public var useStageConsole: Bool {
        get {
            return self.grdbRecord?.useStageConsole ?? false
        }
        set {
            self.grdbRecord?.useStageConsole = newValue
        }
    }
    public var rebootReminderEnabled: Bool {
        get {
            return self.grdbRecord?.rebootReminderEnabled ?? false
        }
        set {
            self.grdbRecord?.rebootReminderEnabled = newValue
        }
    }
    public var dnsEncryptionEnabled: Bool {
        get {
            return self.grdbRecord?.dnsEncryptionEnabled ?? false
        }
        set {
            self.grdbRecord?.dnsEncryptionEnabled = newValue
        }
    }
    public var vpnEnabled: Bool {
        get {
            return self.grdbRecord?.vpnEnabled ?? false
        }
        set {
            self.grdbRecord?.vpnEnabled = newValue
        }
    }
    private static let subscriptionStateKeyPrefix = "com.theglacierapp.subscription.state."
    private static let phoneSubscriptionStateKeyPrefix = "com.theglacierapp.subscription.phone.state."
    private static let backendSubscribedKeyPrefix = "com.theglacierapp.subscription.backend.subscribed."
    private static let backendPhoneNumbersKeyPrefix = "com.theglacierapp.subscription.backend.phoneNumbers."
    public var hasActiveSubscription: Bool {
        get {
            let key = GlacierAccountModel.subscriptionStateKeyPrefix + uniqueId
            var defaultval = false
            return UserDefaults.standard.object(forKey: key) as? Bool ?? defaultval
        }
        set {
            let key = GlacierAccountModel.subscriptionStateKeyPrefix + uniqueId
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
    public var hasActivePhoneNumberSubscription: Bool {
        get {
            let key = GlacierAccountModel.phoneSubscriptionStateKeyPrefix + uniqueId
            var defaultval = false
            return UserDefaults.standard.object(forKey: key) as? Bool ?? defaultval
        }
        set {
            let key = GlacierAccountModel.phoneSubscriptionStateKeyPrefix + uniqueId
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
    // MARK: - Phone number slot tracking
    private static let phoneNumbersEverAddedKeyPrefix = "com.theglacierapp.phoneNumbers.everAdded."
    /// Running total of phone numbers ever successfully added by this account.
    /// Incremented each time `TwilioBackendManager.purchaseNumber` succeeds.
    /// Never decremented — burning a number does not restore a free slot.
    public var phoneNumbersEverAdded: Int {
        get { UserDefaults.standard.integer(forKey: GlacierAccountModel.phoneNumbersEverAddedKeyPrefix + uniqueId) }
        set { UserDefaults.standard.set(newValue, forKey: GlacierAccountModel.phoneNumbersEverAddedKeyPrefix + uniqueId) }
    }

    private static let phoneNumbersAddedMonthlyKeyPrefix = "com.theglacierapp.phoneNumbers.monthlyAdded."
    /// Number of free adds the user has made in the current calendar month.
    /// Keyed by year+month so it resets automatically each new month.
    public var phoneNumbersAddedThisCalendarMonth: Int {
        get { UserDefaults.standard.integer(forKey: monthlyAddKey) }
        set { UserDefaults.standard.set(newValue, forKey: monthlyAddKey) }
    }
    private var monthlyAddKey: String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return "\(GlacierAccountModel.phoneNumbersAddedMonthlyKeyPrefix)\(uniqueId).\(c.year!).\(c.month!)"
    }

    /// Number of free number-selection slots remaining under the current subscription plan.
    /// Returns the initial plan slots first; once exhausted, grants 1 free add per calendar month.
    /// Returns 0 when no plan is active or all free slots are consumed.
    public var freePhoneNumberSlotsRemaining: Int {
        guard let plan = GlacierPhoneNumberSubscriptionPlan.activePlan else { return 0 }
        let initialSlotsRemaining = max(0, plan.maxPhoneNumbers - phoneNumbersEverAdded)
        if initialSlotsRemaining > 0 { return initialSlotsRemaining }
        return phoneNumbersAddedThisCalendarMonth == 0 ? 1 : 0
    }
    // MARK: - Backend subscription last-known state
    /// Last successful response from the backend `/subscription` endpoint.
    /// Defaults to `false` until the endpoint is queried and a response is persisted.
    public var lastKnownBackendSubscribed: Bool {
        get {
            let key = GlacierAccountModel.backendSubscribedKeyPrefix + uniqueId
            return UserDefaults.standard.object(forKey: key) as? Bool ?? false
        }
        set {
            let key = GlacierAccountModel.backendSubscribedKeyPrefix + uniqueId
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
    /// Last successful phone-number count from the backend `/subscription` endpoint (0, 1, 2, or 5).
    /// Defaults to `0` until the endpoint is queried and a response is persisted.
    public var lastKnownBackendPhoneNumbers: Int {
        get {
            let key = GlacierAccountModel.backendPhoneNumbersKeyPrefix + uniqueId
            return UserDefaults.standard.object(forKey: key) as? Int ?? 0
        }
        set {
            let key = GlacierAccountModel.backendPhoneNumbersKeyPrefix + uniqueId
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
    public var loginDate: Date? {
        get {
            return self.grdbRecord?.loginDate
        }
        set {
            self.grdbRecord?.loginDate = newValue ?? Date()
        }
    }
    public var accountId: Int64 {
        get {
            return self.grdbRecord?.id ?? 0
        }
    }
}
extension GlacierAccountModel {
    static var currentAccount:GlacierAccountModel?
    public func touchAccount() {
        if let rec = self.grdbRecord {
            rec.touch()
        }
    }
    static func getGlacierAccount() -> GlacierAccountModel? {
        var account:GlacierAccountModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let caccount = try GlacierAccount
                    .fetchOne(transaction.database) {
                    account = GlacierAccountModel(account: caccount)
                }
            })
        } catch {
            Log.database.debug("GlacierAccountModel.firstAccount error: \(error)")
        }
        return account
    }
    func saveAccount(){
        do {
            try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                self.grdbRecord?.grdbSave(transaction: transaction)
                GlacierAccountModel.currentAccount = nil
            })
        } catch {
            Log.database.debug("GlacierAccountModel.save with error: \(error)")
        }
    }
    func saveAccountAsync(){
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbRecord?.grdbSave(transaction: transaction)
            GlacierAccountModel.currentAccount = nil
        })
    }
    func removeAccount(){
        do {
            try self.removeKeychainPassword(nil)
        } catch {
            Log.database.debug("GlacierAccountModel.remove account, removeKeychainPassword with error: \(error)")
        }
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbRecord?.grdbRemove(transaction: transaction)
        })
    }
}
extension GlacierAccountModel {
    public var username: String {
        get {
            return self.grdbRecord?.username ?? ""
        }
        set {
            self.grdbRecord?.username = newValue
        }
    }
#if !TARGET_IS_EXTENSION
    public var avatarImage: UIImage? {
        get {
            let grec = self.grdbRecord!
            return GlacierImages.avatarImage(withUniqueIdentifier: self.uniqueId, avatarData: grec.avatarData, displayName: grec.username, username: grec.username)
        }
    }
#endif
}
struct GlacierAccount: GRDBRecord, TableRecord {
    public var id: Int64?
    public var uniqueId: String
    var username: String
    var useStageConsole = false
    var rebootReminderEnabled = true
    var dnsEncryptionEnabled = false
    var vpnEnabled = false
    var loginDate: Date?
    var apiKey: String?
    var avatarData:Data?
    var password:String?
    var modified: Date?
    public static var databaseTableName: String {
        "GlacierAccount"
    }
    public init(uniqueId:String, username:String, loginDate:Date?, apiKey:String?, avatarData:Data?, modified: Date?) {
        self.uniqueId = uniqueId
        self.username = username
        self.loginDate = loginDate
        self.apiKey = apiKey
        self.avatarData = avatarData
        self.modified = Date()
    }
    func touch() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            let nowdate = Date()
            var account = self
            do {
                account.modified = nowdate
                try account.update(transaction.database, columns: [Column("modified")])
            } catch {
                Log.database.debug("GlacierAccount.touch with error: \(error)")
            }
        })
    }
}
