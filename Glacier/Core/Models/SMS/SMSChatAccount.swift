//
//  PhoneAccount.swift
//  Glacier
//
//  Created by andyfriedman on 9/4/23.
//  Copyright © 2023 Glacier. All rights reserved.
//
import UIKit
import Foundation
import GRDB
open class PhoneAccountModel: GRDBModel {
    var grdbRecord:PhoneAccount?
    private var acctColor: UIColor?
    public var color: UIColor? {
        get {
            if acctColor == nil, let colorStr = grdbRecord?.color {
                acctColor = UIColor.UIColorFromString(string: colorStr)
            }
            return acctColor
        }
        set {
            acctColor = newValue
            if let newval = newValue {
                grdbRecord?.color = UIColor.StringFromUIColor(color: newval)
            }
        }
    }
    public convenience init(phoneNumber:String, smsacctid:String) {
        self.init()
        let avatar = PhoneAccountModel.getGradientAvatar(for: phoneNumber)
        self.grdbRecord = PhoneAccount(
            uniqueId: self.uniqueId,
            phoneNumber: phoneNumber,
            twilioId: smsacctid,
            displayName: phoneNumber,
            color: PhoneAccountModel.getNextColor(),
            gradientAvatar: avatar
        )
    }
    public convenience init(phoneNumber:String, smsacctid:String, color:UIColor, gradientAvatar: String?) {
        self.init()
        self.grdbRecord = PhoneAccount(
            uniqueId: self.uniqueId,
            phoneNumber: phoneNumber,
            twilioId: smsacctid,
            displayName: phoneNumber,
            color: color,
            gradientAvatar: gradientAvatar
        )
    }
    public convenience init(phoneNumber:String, smsacctid:String, displayName: String, color:UIColor, gradientAvatar: String?) {
        self.init()
        self.grdbRecord = PhoneAccount(
            uniqueId: self.uniqueId,
            phoneNumber: phoneNumber,
            twilioId: smsacctid,
            displayName: displayName,
            color: color,
            gradientAvatar: gradientAvatar
        )
    }
    convenience init(account: PhoneAccount) {
        self.init(uniqueId: account.uniqueId)
        self.grdbRecord = account
    }
    public func getSmsId() -> String? {
        return self.grdbRecord?.twilioId
    }
    public static func getNextColor() -> UIColor {
        return PhoneAccountModel.getNextColor(0)
    }
    public static func getNextColor(_ idx:Int) -> UIColor {
        let accts = PhoneAccountModel.allAccounts()
        let index = idx % UIColor.solids.count
        var newColor = UIColor.solids[index]
        // PREM: Below loop crahes due to idx being greater than UIColor.solids.count
//        for i in idx..<UIColor.solids.count {
//            let solidcolor = UIColor.solids[i]
//            var colorfound = false
//            for smsAcct in accts {
//                if smsAcct.color == solidcolor {
//                    colorfound = true
//                    break
//                }
//            }
//            if colorfound == false {
//                newColor = solidcolor
//                break
//            }
//        }
        return newColor
    }
    public static func getGradientAvatar(for phoneNumber: String) -> String? {
        guard let avatarDictionary: [String: String] = UserDefaultsService.shared.get(for: \.phoneNumberGradientAvatarDictionary),
              let avatar = avatarDictionary[phoneNumber] else {
            return nil
        }
        return avatar
    }
}
extension PhoneAccountModel {
    public func save(completion: @escaping () -> Void) {
        self.grdbRecord?.storeInGRDB(completion: completion)
    }
    public func save() {
        self.grdbRecord?.storeInGRDB()
    }
    public func remove(completion: @escaping () -> Void) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbRecord?.grdbRemove(transaction: transaction)
        }, completion: completion)
    }
    public static func existingAccount(with phoneNumber:String) -> PhoneAccountModel? {
        var account:PhoneAccountModel?
        let sql = "SELECT * FROM \(PhoneAccount.databaseTableName) WHERE phoneNumber == ?"
        let sqlRequest = SQLRequest<Void>(sql: sql, arguments: [phoneNumber], cached: true)
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try PhoneAccount.fetchOne(transaction.database, sqlRequest) {
                    account = PhoneAccountModel(account: record)
                }
            })
        } catch {
            Log.database.debug("error: \(error)")
            return nil
        }
        return account
    }
    public static func allAccounts() -> [PhoneAccountModel] {
        var accounts:[PhoneAccountModel] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let records = try PhoneAccount
                    .fetchAll(transaction.database)
                for record in records {
                    accounts.append(PhoneAccountModel(account: record))
                }
            })
        } catch {
            Log.database.debug("PhoneAccountModel.allConversations error: \(error)")
        }
        return accounts
    }
    public static func allAccountsSortedByDisplayName() -> [PhoneAccountModel] {
        let allAccounts = PhoneAccountModel.allAccounts()
        let sortedAccounts = allAccounts.sorted {
            if $0.hasValidDisplayName != $1.hasValidDisplayName {
                return $0.hasValidDisplayName
            }
            if let firstPhoneNumber = $0.grdbRecord?.phoneNumber, let secondPhoneNumber = $1.grdbRecord?.phoneNumber {
                return firstPhoneNumber < secondPhoneNumber
            }
            return false
        }
        return sortedAccounts
    }
}
extension PhoneAccountModel {
    var hasValidDisplayName: Bool {
        guard let name = grdbRecord?.displayName,
              !name.isEmpty else {
            return false
        }
        guard let phoneNumber = grdbRecord?.phoneNumber,
              name != phoneNumber else {
            return false
        }
        return true
    }
}
struct PhoneAccount: GRDBRecord, TableRecord {
    var id: Int64?
    var uniqueId: String
    var phoneNumber: String?
    var twilioId: String?
    var displayName: String?
    var color: String?
    var gradientAvatar: String?
    var modified: Date?
    public static var databaseTableName: String {
        "smsAccount" //yes, we know this doesn't match, we will migrate one day
    }
    public init(uniqueId:String, phoneNumber:String?, twilioId:String?, displayName:String?, color:UIColor?, gradientAvatar: String?) {
        self.uniqueId = uniqueId
        self.phoneNumber = phoneNumber
        self.twilioId = twilioId
        self.displayName = displayName
        //self.color = color
        if let color = color {
            self.color = UIColor.StringFromUIColor(color: color)
        }
        self.gradientAvatar = gradientAvatar
        self.modified = Date()
    }
    public init(uniqueId:String) {
        self.uniqueId = uniqueId
        self.modified = Date()
    }
    public static func allSMSAccounts() -> [PhoneAccount] {
        var accounts:[PhoneAccount] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                accounts = try PhoneAccount
                    .fetchAll(transaction.database)
            })
        } catch {
            Log.database.error("error: allSMSAccounts \(error)")
        }
        return accounts
    }
}
