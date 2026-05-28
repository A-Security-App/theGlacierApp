//
//  CallRecord.swift
//  Glacier
//
//  Created by andyfriedman on 2/11/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import Foundation
import GRDB

struct CallRecord: GRDBRecord, TableRecord {
    var id: Int64?
    var uniqueId: String
    
    var name:String //link with PhoneContact
    var phoneNumber:String
    var isIncoming = false
    var twilioSid: String
    var to:String
    var toFormatted:String
    var from:String
    var fromFormatted:String
    var status:String
    var startTime:String
    var endTime:String
    var duration:String
    var modified = Date()
    
    public static var databaseTableName: String {
        return "CallRecord"
    }
    
    public init(uniqueId:String, name:String, phoneNumber:String, incoming:Bool, twilioSid:String, to:String, toFormatted:String, from:String, fromFormatted:String, status:String, startTime:String, endTime:String, duration:String) {
        self.uniqueId = uniqueId
        self.name = name
        self.phoneNumber = phoneNumber
        self.isIncoming = incoming
        self.twilioSid = twilioSid
        self.to = to
        self.toFormatted = toFormatted
        self.from = from
        self.fromFormatted = fromFormatted
        self.status = status
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
    }
    
    public static func allMessages() -> [CallRecord] {
        var messages:[CallRecord] = []
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                messages = try CallRecord
                    .order(Column("startTime").desc)
                    .fetchAll(transaction.database)
            })
        } catch {
            Log.calls.debug("CallRecord.allMessages error: \(error)")
        }

        return messages
    }
    
    public static func allMessages(_ number:String) -> [CallRecord] {
        var messages:[CallRecord] = []
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                messages = try CallRecord
                    .filter(Column("to") == number || Column("from") == number)
                    .order(Column("startTime").desc)
                    .fetchAll(transaction.database)
            })
        } catch {
            Log.calls.debug("CallRecord.allMessages error: \(error)")
        }

        return messages
    }
    
    public static func storeCallRecords(callRecords:[CallRecord], completion: @escaping ()->Void) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            for callRecord in callRecords {
                callRecord.grdbSave(transaction: transaction)
            }
        }, completion: completion)
    }

    public static func removeAll(for number: String) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                try CallRecord
                    .filter(Column("to") == number || Column("from") == number)
                    .deleteAll(transaction.database)
            } catch {
                Log.calls.debug("CallRecord.removeAll error: \(error)")
            }
        })
    }
}
