//
//  HistoryViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 01/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 HistoryViewModel defines requirements for call history and voicemail screens view models.
 */
protocol HistoryViewModel: GlacierViewModelWithRootCoordinator {
    var selectedTab: HistoryScreenTab { get set }
    
    var callHistory: [CallRecord] { get }
    var hasNewVM: Bool { get }
    var voiceMails: [VoicemailRecord] { get }
    var isLoadingData: Bool { get set }
    
    init(rootCoordinator: any GlacierRootCoordinator)
    
    func initialize()
    func getHistoricalData()
    func getContact(for phoneNumber: String) -> PhoneContact?
    func startCall(with phoneNumber: String, personName: String?)
    
    func presentVoicemailDetailsView(for voiceMail: VoicemailRecord)
}

/**
 HistoryVM defines data/state and business logic for call history and voicemail screens.
 */
final class HistoryVM: HistoryViewModel, ObservableObject, PhoneNumberMenuCoordinator {
    
    // MARK: - Public properties
    
    @Published var selectedTab: HistoryScreenTab = .callHistory {
        didSet {
            getHistoricalData()
        }
    }
    
    @Published var callHistory: [CallRecord] = []
    @Published var hasNewVM: Bool = false
    @Published var voiceMails: [VoicemailRecord] = []
    @Published var isLoadingData: Bool = false
    
    let rootCoordinator: any GlacierRootCoordinator
    
    // MARK: - Private properties
    
    private var didAttemptHistoryDataLoad: Bool = false
    private var didAttemptVoicemailDataLoad: Bool = false
    
    private var callRecDict = [String:CallRecord]()
    private var activePhoneNumber: PhoneAccountModel?
    private var contacts = [PhoneContact]()
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
    }
    
    func initialize() {
        TwilioBackendManager.sharedMgr().setCallHistoryDelegate(self)
        TwilioBackendManager.sharedMgr().setPhoneDelegate(self)
        hasNewVM = TwilioBackendManager.sharedMgr().hasNewVM
        
        activePhoneNumber = TwilioBackendManager.sharedMgr().selectedAccount
    }
    
    func getHistoricalData() {
        if case .callHistory = selectedTab {
            getCallHistory()
        } else {
            getVoiceMails()
        }
    }
    
    func getContact(for phoneNumber: String) -> PhoneContact? {
        return ContactsManager.shared.matchContact(for: phoneNumber)
    }
    
    func startCall(with phoneNumber: String, personName: String?) {
        hidePhoneNumberMenu()
        
        guard !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let popupConfiguration = PopupConfiguration(
            title: nil,
            description: NSLocalizedString("Start call?", comment: "Phone screen call confirmation prompt description"),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                    onTap: {
                        self.dismissPopup()
                    }
                ),
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Call", comment: "Call button title"),
                    onTap: {
                        // Let's send notification for call initialization
                        NotificationCenter.default.post(
                            name: .startPhoneCall,
                            object: nil,
                            userInfo: [
                                GlacierNotificationProperties.phoneNumber: phoneNumber,
                                GlacierNotificationProperties.personName: personName ?? ""
                            ]
                        )
                        
                        self.dismissPopup()
                    }
                )
            ],
            buttonsAlignment: .horizontal
        )
        presentPopup(with: popupConfiguration)
    }
    
    func presentVoicemailDetailsView(for voiceMail: VoicemailRecord) {
        presentScreen(.voicemailDetails(voiceMail))
    }
    
    // MARK: - Private methods
    
    private func getCallHistory() {
        guard !isLoadingData else { return }
        
        if !didAttemptHistoryDataLoad {
            presentProgressIndicator()
        }
        
        isLoadingData = true
        didAttemptHistoryDataLoad = true
        
        TwilioBackendManager.sharedMgr().queryCallHistory(500) { [weak self] data in
            DispatchQueue.main.async {
                self?.dismissProgressIndicator()
            }
            
            guard let strongSelf = self,
                  let historyData = data,
                  let json = strongSelf.parseJSON(from: historyData) else {
                DispatchQueue.main.async {
                    self?.isLoadingData = false
                }
                return
            }
            
            DispatchQueue.main.async {
                strongSelf.contacts = TwilioBackendManager.sharedMgr().contacts

                var newRecords: [CallRecord] = strongSelf.parseIncomingCalls(from: json)
                newRecords.append(contentsOf: strongSelf.parseOutgoingCalls(from: json))
                strongSelf.storeAndReload(records: newRecords)
            }
        }
    }
    
    private func getVoiceMails() {
        guard !isLoadingData else { return }
        
        if !didAttemptVoicemailDataLoad {
            presentProgressIndicator()
        }
        
        isLoadingData = true
        didAttemptVoicemailDataLoad = true

        TwilioBackendManager.sharedMgr().queryForVMInfo { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissProgressIndicator()
            }
            
            guard let strongSelf = self,
                  !TwilioBackendManager.sharedMgr().selectedRecordings.isEmpty else {
                DispatchQueue.main.async {
                    self?.isLoadingData = false
                }
                return
            }
            
            DispatchQueue.main.async {
                strongSelf.hasNewVM = TwilioBackendManager.sharedMgr().hasNewVM
                strongSelf.voiceMails.removeAll()
                strongSelf.voiceMails.append(contentsOf: TwilioBackendManager.sharedMgr().selectedRecordings)
                strongSelf.isLoadingData = false
            }
        }
    }
}


// MARK: - CallHistoryDelegateProtocol method for call history API response processing

extension HistoryVM: CallHistoryDelegateProtocol {
    
    public func callHistoryUpdated(_ historyData: Data?) {
        DispatchQueue.main.async {
            self.dismissProgressIndicator()
        }
    }
    
    private func parseJSON(from data: Data) -> [String: Any]? {
        do {
            return try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any]
        } catch {
            Log.calls.error("Failed to parse call history JSON: \(error)")
            return nil
        }
    }
    
    private func parseIncomingCalls(from json: [String: Any]) -> [CallRecord] {
        guard let records = json["incomingCalls"] as? [[String: Any]] else {
            return []
        }

        return records.compactMap { record in
            buildCallRecord(from: record, isIncoming: true)
        }
    }
    
    private func parseOutgoingCalls(from json: [String: Any]) -> [CallRecord] {
        guard let records = json["outgoingCalls"] as? [[String: Any]] else {
            return []
        }

        return records.compactMap { record in
            buildCallRecord(from: record, isIncoming: false)
        }
    }
    
    private func buildCallRecord(from record: [String: Any], isIncoming: Bool) -> CallRecord? {
        guard
            let sid = record["sid"] as? String,
            callRecDict[sid] == nil,

            let to = record["to"] as? String,
            let toFormatted = record["toFormatted"] as? String,
            let from = record["from"] as? String,
            let fromFormatted = record["fromFormatted"] as? String,
            let status = record["status"] as? String,
            let startTime = record["startTime"] as? String,
            let endTime = record["endTime"] as? String,
            let duration = record["duration"] as? String,
            let direction = record["direction"] as? String,

            !to.contains("sip"),
            !from.contains("sip")
        else {
            return nil
        }

        // Direction validation
        if isIncoming && direction != "inbound" { return nil }
        if !isIncoming && direction != "outbound-dial" { return nil }
        if !isIncoming && to.contains("client") { return nil }

        let name = isIncoming ? fromFormatted : toFormatted
        let phoneNumber = isIncoming ? fromFormatted : toFormatted

        let recordModel = CallRecord(
            uniqueId: sid,
            name: name,
            phoneNumber: phoneNumber,
            incoming: isIncoming,
            twilioSid: sid,
            to: to,
            toFormatted: toFormatted,
            from: from,
            fromFormatted: fromFormatted,
            status: status,
            startTime: startTime,
            endTime: endTime,
            duration: duration
        )

        let processed = processCallRecord(cdr: recordModel)
        callRecDict[sid] = processed

        return processed
    }
    
    private func processCallRecord(cdr: CallRecord) -> CallRecord {
        var modded = cdr
        
        var cdrnumber = CallManager.cleanPhoneNumber(cdr.from)
        if cdr.isIncoming == false {
            cdrnumber = CallManager.cleanPhoneNumber(cdr.to)
        }
            
        for contact in self.contacts {
            let cleanContact = CallManager.cleanPhoneNumber(contact.phoneNumber)
            if TwilioBackendManager.arePhoneNumbersEqualUS(phone1: cdrnumber, phone2: cleanContact) {
                modded.name = contact.name
                modded.phoneNumber = contact.phoneNumber
                break
            }
        }
        
        return modded
    }
    
    private func storeAndReload(records: [CallRecord]) {
        CallRecord.storeCallRecords(callRecords: records) { [weak self] in
            guard let strongSelf = self else {
                self?.isLoadingData = false
                return
            }

            strongSelf.callHistory.removeAll()
            if let activeNumber = strongSelf.activePhoneNumber, let phoneNumber = activeNumber.grdbRecord?.phoneNumber {
                strongSelf.callHistory.append(contentsOf: CallRecord.allMessages(phoneNumber))
            } else {
                strongSelf.callHistory.append(contentsOf: CallRecord.allMessages())
            }

            strongSelf.callRecDict = Dictionary(uniqueKeysWithValues: strongSelf.callHistory.map { ($0.twilioSid, $0) })
            strongSelf.isLoadingData = false
        }
    }
}

// MARK: - Delegate methods for processing update events related to Glacier phone numbers and voicemails

extension HistoryVM: TwilioAccountDelegateProtocol {
    
    // It is called, when new phone number is selected via PhoneNumberMenuView
    public func setSelectedAccount(_ account: PhoneAccountModel?) {
        activePhoneNumber = TwilioBackendManager.sharedMgr().selectedAccount
        getHistoricalData()
    }

    // It is called, when TwilioBackendManager is done with loading/processing VoicemailRecord
    public func voicemailUpdated() {
        DispatchQueue.main.async {
            self.dismissProgressIndicator()
            self.hasNewVM = TwilioBackendManager.sharedMgr().hasNewVM
            self.voiceMails.removeAll()
            self.voiceMails.append(contentsOf: TwilioBackendManager.sharedMgr().selectedRecordings)
        }
    }
}
