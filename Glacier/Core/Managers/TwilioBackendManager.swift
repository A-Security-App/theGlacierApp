//
//  TwilioBackendManager.swift
//  Glacier
//
//  Created by andyfriedman on 9/14/22.
//  Copyright © 2022 Glacier. All rights reserved.
//
import UIKit
import Foundation
import Alamofire
import Contacts
import JWTDecode
public protocol TokenStatusDelegate:AnyObject {
    func tokenUpdated()
}
open class TwilioBackendManager: NSObject
{
    static let API_ENDPOINT = (EndpointService.shared.consoleBaseEndpoint ?? "") + (EndpointService.shared.twilioAPIEndpoint ?? "")
    static let deleteVMStatus = "deleted"
    static let readVMStatus = "read"
    private static let shared = TwilioBackendManager()
    public var identity:String?
    public var phoneToken:String?
    public var pushToken:Data?
    //private var idToken:String?
    private var accessToken:String?
    private var pushRegistered = false
    private var dataPopulated = false
    private var apiKey:String?
    private var org:String?
    var contacts = [PhoneContact]()
    private var phoneDelegates = [TwilioAccountDelegateProtocol]()
    private var tokenListeners = [TokenStatusDelegate]()
    var glacierPhone:GlacierPhone?
    private var smsOn = false
    var currentAccounts: [PhoneAccountModel] = []
    var selectedAccount: PhoneAccountModel? {
        didSet {
            DispatchQueue.main.async {
                for phoneDelegate in self.phoneDelegates {
                    phoneDelegate.setSelectedAccount(self.selectedAccount)
                }
            }
            vmInitialized = false
            self.queryForVMInfo()
        }
    }
    var selectedRecordings = [VoicemailRecord]()
    var updatingRecordings = false
    var vmInitialized = false
    var hasNewVM = false
    private var callHistoryDelegate:CallHistoryDelegateProtocol?
    let sessionManager = Alamofire.Session(
        configuration: URLSessionConfiguration.ephemeral,
        serverTrustManager: GlacierPinningConfiguration.makeServerTrustManager()
    )
    let internalQueue = DispatchQueue(label: "SMS Internal Queue", qos: .userInitiated)
    private override init() {
        if let glacierAcct = GlacierAccountModel.getGlacierAccount() {
            identity = glacierAcct.username//.components(separatedBy: "@").first ?? ""
        }
        super.init()
        //delegate = self
        self.currentAccounts = self.getExistingAccounts()
        if self.currentAccounts.count > 0 {
            self.selectedAccount = self.currentAccounts.first
        }
    }
    private func subscriptionIsActive() -> Bool {
        return GlacierAccountModel.getGlacierAccount()?.hasActivePhoneNumberSubscription ?? false
    }
    func addTokenListener(_ listener: TokenStatusDelegate) {
        tokenListeners.append(listener)
    }
    func shutdown() {
        self.identity = nil
        self.phoneToken = nil
        self.pushToken = nil
        self.contacts.removeAll()
        self.dataPopulated = false
        self.smsOn = false
        self.glacierPhone = nil
        self.pushRegistered = false
    }
    /*func setIdToken(_ idToken: String) {
        self.idToken = idToken
        for listener in self.tokenListeners {
            listener.tokenUpdated()
        }
    }
    func getIdToken() -> String? {
        return self.idToken
    }*/
    func setAccessToken(_ accessToken: String) {
        self.accessToken = accessToken
        for listener in self.tokenListeners {
            listener.tokenUpdated()
        }
        NotificationCenter.default.post(name: .twilioAccessTokenUpdated, object: nil)
    }
    func getAccessToken() -> String? {
        return self.accessToken
    }
    func fetchContacts(completion: @escaping (Bool) -> Void) {
        guard subscriptionIsActive() else {
            completion(false)
            return
        }
        guard UserPermissionManager.shared.hasContactsPermission else {
            completion(false)
            return
        }
        fetchContactsFromStore(completion: completion)
    }
    private func fetchContactsFromStore(completion: @escaping (Bool) -> Void) {
        self.internalQueue.async {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey, CNContactThumbnailImageDataKey]
            let request = CNContactFetchRequest(keysToFetch: keys as [CNKeyDescriptor])
            request.sortOrder = .familyName
            do {
                // Let's build a directory of phone numbers and related contacts so that
                // it would become easier and faster to find contacts for a given number later
                ContactsManager.shared.clearIndex()
                ContactsManager.shared.buildContactIndex()
                let store = CNContactStore()
                var contacts = [PhoneContact]()
                let resize = CGSize(width: 100, height: 100)
                try store.enumerateContacts(with: request, usingBlock: { (contact, stopPointer) in
                    guard !contact.phoneNumbers.isEmpty else { return }
                    let fullName = (contact.givenName + " " + contact.familyName).trimmingCharacters(in: .whitespaces)
                    let contactName = !fullName.isEmpty ? fullName : (!contact.nickname.isEmpty ? contact.nickname : contact.organizationName)
                    var avatar: UIImage? = nil
                    if let avdata = contact.thumbnailImageData, let avImg = UIImage(data: avdata) {
                        avatar = avImg.scalePreservingAspectRatio(targetSize: resize)
                    }
                    for phoneNumber in contact.phoneNumbers {
                        let numberString = phoneNumber.value.stringValue
                        let phoneLabel = CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: phoneNumber.label ?? CNLabelOther).capitalized
                        var initials = GlacierImages.stringInitials(withMaxCharacters: contactName, maxCharacters: 2) ?? ""
                        if initials.isEmpty {
                            initials = GlacierImages.stringInitials(withMaxCharacters: numberString, maxCharacters: 2) ?? ""
                        }
                        contacts.append(
                            PhoneContact(
                                id: "\(contact.identifier)_\(numberString)",
                                name: contactName,
                                initials: initials,
                                phoneNumber: numberString,
                                phoneLabel: phoneLabel,
                                avatar: avatar
                            )
                        )
                    }
                })
                self.contacts = contacts
                completion(true)
                return
            } catch let error {
                Log.calls.error("Failed to enumerate contacts: \(error)")
                completion(false)
            }
        }
    }
    func getMatchingContact(_ number: String) -> PhoneContact? {
        let cleanNum = CallManager.cleanPhoneNumber(number)
        for contact in self.contacts {
            let contactNum = CallManager.cleanPhoneNumber(contact.phoneNumber)
            if TwilioBackendManager.arePhoneNumbersEqualUS(phone1: cleanNum, phone2: contactNum) {
                return contact
            }
        }
        return nil
    }
    func getEndpoint() -> String {
        TwilioBackendManager.API_ENDPOINT
    }
    func getAvailableNumListUrl() -> String {
        return getEndpoint() + "search"
    }
    func releaseNumUrl() -> String {
        return getEndpoint() + "release"
    }
    func purchaseNumUrl() -> String {
        return getEndpoint() + "purchase"
    }
    func getAccessTokenUrl() -> String {
        return getEndpoint() + "token"
    }
    func getUserTwilioNumbers() -> String {
        return getEndpoint() + "numbers"
    }
    func voicemailListUrl() -> String {
        return getEndpoint() + "voicemail_list"
    }
    func getVoicemailUrl() -> String {
        return getEndpoint() + "get_voicemail"
    }
    func updateVoicemailStatusUrl() -> String {
        return getEndpoint() + "update_voicemail_status"
    }
    func phoneTokenUrl() -> String {
        return getEndpoint() + "getAccessTokenForDial"
    }
    func callHistoryUrl() -> String {
        return getEndpoint() + "call-history"
    }
    func queryForAvailableNumbers(areaCode:String?, contains:String?) {
        guard !SecurityCenter.isProxyDetected else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
            var params = ["countryCode":"US"]
            if let areaCode = areaCode {
                params["areaCode"] = areaCode
            }
            if let contains = contains {
                params["contains"] = contains
            }
            self.sessionManager.request(self.getAvailableNumListUrl(), method: .post, parameters: params, encoding: JSONEncoding.default, headers: headers)
            .validate()
            .responseDecodable(of: TwilioResponse.self, queue: self.internalQueue) { response in
            //.responseData(queue: self.internalQueue) { response in
                switch response.result {
                    case .success(let value):
                    let phoneNumbers: [GlacierPhoneNumber] = value.data.map { GlacierPhoneNumber(number: $0.phoneNumber) }
                        for phoneDelegate in self.phoneDelegates {
                            phoneDelegate.availableNumbersUpdated(phoneNumbers)
                        }
                        return
                    case .failure(let error):
                        let nums: [GlacierPhoneNumber] = []
                        for phoneDelegate in self.phoneDelegates {
                            phoneDelegate.availableNumbersUpdated(nums)
                        }
                        Log.calls.error("Error accessing available numbers: \(error)")
                        return
                }
            }
        }
    }
    func nameANumber(_ selectedNumber:String, selectedName:String?, responseHandler: ((Bool) -> Void)? = nil) {
        //self.naming = false
        //self.numAction = nil
        if let displayName = selectedName, let smsAcct = getExistingAccount(phoneNumber: selectedNumber) {
            smsAcct.grdbRecord?.displayName = displayName
            smsAcct.save(completion: {
                responseHandler?(true)
                self.currentAccounts = self.getExistingAccounts()
            })
        }
    }
    func purchaseNumber(_ selectedNumber:String, selectedName:String?, responseHandler: ((Bool) -> Void)? = nil) {
        guard !SecurityCenter.isProxyDetected else { responseHandler?(false); return }
        Task { [weak self] in
            guard let self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
            self.sessionManager.request(self.purchaseNumUrl(), method: .post, parameters: ["number": selectedNumber], encoding: JSONEncoding.default, headers: headers)
                .validate()
                .responseData(queue: self.internalQueue) { response in
                    switch response.result {
                    case .success(_):
                        let shouldActivateSubscriptionFeatures = self.currentAccounts.isEmpty
                        let color = PhoneAccountModel.getNextColor(self.currentAccounts.count)
                        var gradientAvatar: String? = nil
                        if let avatar = self.getNextAvailableGradientAvatar() {
                            gradientAvatar = avatar.name
                            if var avatarDictionary: [String: String] = UserDefaultsService.shared.get(for: \.phoneNumberGradientAvatarDictionary), avatarDictionary[selectedNumber] == nil {
                                avatarDictionary[selectedNumber] = avatar.name
                                UserDefaultsService.shared.set(avatarDictionary, for: \.phoneNumberGradientAvatarDictionary)
                            } else {
                                UserDefaultsService.shared.set([selectedNumber: avatar.name], for: \.phoneNumberGradientAvatarDictionary)
                            }
                        }
                        let smsAccount = PhoneAccountModel(phoneNumber: selectedNumber, smsacctid: "tempid", color:color, gradientAvatar: gradientAvatar)
                        if let acctname = selectedName {
                            smsAccount.grdbRecord?.displayName = acctname
                        }
                        //IOSM#105
                        smsAccount.save(completion: {
                            self.currentAccounts.append(smsAccount)
                            if shouldActivateSubscriptionFeatures {
                                SubscriptionAccessCoordinator.shared.activateSubscriptionFeaturesIfNeeded()
                                // If this is the first phone number (e.g., added post-onboarding),
                                // the coordinator's guard may silently no-op if handleSubscriptionStatusChange
                                // was never called with isSubscribed=true before token refresh.
                                // Unconditionally request push permission and fetch the call token
                                // so that performMakeVoiceCall has a callToken available.
                                DispatchQueue.main.async {
                                    PushController.registerForPushNotifications()
                                }
                                self.queryForTwilioTokens()
                            }
                            self.selectedAccount = smsAccount
                            responseHandler?(true)
                        })
                        return
                    case .failure(let error):
                        Log.calls.error("Error purchasing number: \(error)")
                        responseHandler?(false)
                        return
                    }
                }
        }
    }
    func releaseNumber(_ selectedNumber:String, responseHandler: ((Bool) -> Void)? = nil) {
        guard !SecurityCenter.isProxyDetected else { responseHandler?(false); return }
        Task { [weak self] in
            guard let self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else {
                responseHandler?(false)
                return
            }
            self.removeAccount(selectedNumber)
            if var avatarDictionary: [String: String] = UserDefaultsService.shared.get(for: \.phoneNumberGradientAvatarDictionary) {
                avatarDictionary[selectedNumber] = nil
                UserDefaultsService.shared.set(avatarDictionary, for: \.phoneNumberGradientAvatarDictionary)
            }
            self.sessionManager.request(self.releaseNumUrl(), method: .post, parameters: ["number":selectedNumber], encoding: JSONEncoding.default, headers: headers)
                .validate()
                .responseData(queue: self.internalQueue) { response in
                    switch response.result {
                    case .success(_):
                        //self.queryForNumbers()
                        responseHandler?(true)
                        return
                    case .failure(let error):
                        Log.calls.error("Error releasing number: \(error)")
                        responseHandler?(false)
                        return
                    }
            }
        }
    }
    private func removeAccount(_ selectedNumber:String) {
        self.internalQueue.async {
            if let acct = self.getExistingAccount(phoneNumber:selectedNumber) {
                acct.remove(completion: {
                    self.currentAccounts = self.getExistingAccounts()
                    if self.selectedAccount?.grdbRecord?.phoneNumber == selectedNumber {
                        if self.currentAccounts.count > 0 {
                            self.selectedAccount = self.currentAccounts.first
                        } else {
                            self.selectedAccount = nil
                        }
                    }
                })
            }
        }
    }
    /// Performs the local portion of a number release (GRDB removal, in-memory state update,
    /// avatar dictionary cleanup) **without** making the backend `/release` API call.
    /// Use this when the backend will handle the release independently (e.g. subscription lapse
    /// detected via the backend subscription endpoint).
    func removeNumberLocally(_ selectedNumber: String) {
        removeAccount(selectedNumber)
        if var avatarDictionary: [String: String] = UserDefaultsService.shared.get(for: \.phoneNumberGradientAvatarDictionary) {
            avatarDictionary[selectedNumber] = nil
            UserDefaultsService.shared.set(avatarDictionary, for: \.phoneNumberGradientAvatarDictionary)
        }
    }
    static func arePhoneNumbersEqualUS(phone1: String, phone2: String) -> Bool {
        if phone1.count < 8 || phone2.count < 8 {
            return false
        }
        if phone1 == phone2 {
            return true
        }
        let phone1us = "1" + phone1
        let phone2us = "1" + phone2
        if phone1us == phone2 {
            return true
        }
        if phone1 == phone2us {
            return true
        }
        return false
    }
    public class func sharedMgr() -> TwilioBackendManager {
        return shared
    }
    public func getToken() {
        if self.phoneToken == nil {
            queryForTwilioTokens()
            if subscriptionIsActive() {
                queryForNumbers()
            }
        }
    }
    func needsTokenRefresh(_ token: String) -> Bool {
        let jwt: JWT
        do {
            jwt = try decode(jwt: token)
        } catch {
            Log.calls.error("Failed to decode Twilio token to check expiry: \(error)")
            return true
        }
        if let exp = jwt.expiresAt {
            let remaining = exp.timeIntervalSinceNow
            return remaining < 300 // refresh if < 5 minutes remaining
        }
        return true
    }
    public func queryForTwilioTokens() {
        guard !SecurityCenter.isProxyDetected else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
            if identity == nil, let glacierName = GlacierAccountModel.getGlacierAccount()?.username {
                identity = glacierName//.components(separatedBy: "@").first ?? ""
            }
            if identity != nil
            {
                self.sessionManager.request(self.getAccessTokenUrl(), method: .get, encoding: URLEncoding.default, headers: headers)
                    .validate()
                    .responseData(queue: self.internalQueue) { response in
                        switch response.result {
                        case .success(let value):
                            self.parseToken(token: value)
                            return
                        case .failure(let error):
                            Log.calls.error("Error getting chat/voice token: \(error)")
                            return
                        }
                    }
            }
        }
    }
    func parseToken(token: Data) {
        let parsed: Any?
        do {
            parsed = try JSONSerialization.jsonObject(with: token, options: .allowFragments)
        } catch {
            Log.calls.error("Failed to parse Twilio token response: \(error)")
            parsed = nil
        }
        if let json = parsed as? Dictionary<String,Any> {
            if let vtoken = json["voice_token"] as? String {
                self.phoneToken = vtoken
                CallManager.sharedCallManager().twilioTokenReceived(vtoken)
                /*if let jwt = try? decode(jwt: vtoken) {
                    if let exp = jwt.expiresAt {
                        print("Token expires at: \(exp)")
                    }
                    if let grantsClaim = jwt.claim(name: "grants").rawValue as? [String: Any] {
                        if grantsClaim["chat"] != nil {
                            print("✅ ChatGrant present")
                        }
                        if grantsClaim["voice"] != nil {
                            print("✅ VoiceGrant present")
                        }
                    }
                }*/
            }
        }
    }
    public func queryForNumbers() {
        guard subscriptionIsActive() else {
            return
        }
        guard !SecurityCenter.isProxyDetected else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
            if identity == nil, let glacierName = GlacierAccountModel.getGlacierAccount()?.username {
                identity = glacierName//.components(separatedBy: "@").first ?? ""
            }
            self.sessionManager.request(self.getUserTwilioNumbers(), method: .get, encoding: URLEncoding.default, headers: headers)
                .validate()
                .responseData(queue: self.internalQueue) { response in
                    switch response.result {
                    case .success(let value):
                        self.parseNumbers(data: value)
                        return
                    case .failure(let error):
                        Log.calls.error("Error getting Twilio numbers: \(error)")
                        if self.glacierPhone == nil, self.phoneToken == nil {
                            self.queryForTwilioTokens()
                            self.fetchContacts(completion: {_ in })
                        }
                        return
                    }
            }
        }
    }
    func parseNumbers(data: Data) {
        //let data = response.data(using: .utf8),
        let parsed: Any?
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: .allowFragments)
        } catch {
            Log.calls.error("Failed to parse Twilio numbers response: \(error)")
            parsed = nil
        }
        if let json = parsed as? Dictionary<String,Any> {
            let gphone = GlacierPhone()
            gphone.addUserToPurchaseNumbers = true
            if let jdata = json["data"] as? [Dictionary<String,String>] {
                for acct in jdata {
                    gphone.selectedTwilionumber.append(acct)
                }
            }
            if self.glacierPhone == nil, self.phoneToken == nil {
                queryForTwilioTokens()
                self.fetchContacts(completion: {_ in })
            } else if let mytoken = self.phoneToken, self.needsTokenRefresh(mytoken) {
                queryForTwilioTokens()
            }
            self.glacierPhone = gphone
            self.processTwilioUserData(gphone)
        }
    }
    private func processTwilioUserData(_ glacierPhone: GlacierPhone) {
        var phonenumbers: [String] = []
        var index = 0
        self.currentAccounts.removeAll()
        var updated = false
        for item in glacierPhone.selectedTwilionumber {
            if let phonenumber = item["number"], let id = item["sid"] {
                phonenumbers.append(phonenumber)
                //can just change to PhoneAccount.existingAccount(with: phoneNumber)
                var smsAccount:PhoneAccountModel?
                if let smsAcct = getExistingAccount(phoneNumber: phonenumber) {
                    smsAccount = smsAcct
                } else {
                    let color = PhoneAccountModel.getNextColor(index)
                    var gradientAvatar: String? = nil
                    if let avatar = getNextAvailableGradientAvatar() {
                        gradientAvatar = avatar.name
                        if var avatarDictionary: [String: String] = UserDefaultsService.shared.get(for: \.phoneNumberGradientAvatarDictionary), avatarDictionary[phonenumber] == nil {
                            avatarDictionary[phonenumber] = avatar.name
                            UserDefaultsService.shared.set(avatarDictionary, for: \.phoneNumberGradientAvatarDictionary)
                        } else {
                            UserDefaultsService.shared.set([phonenumber: avatar.name], for: \.phoneNumberGradientAvatarDictionary)
                        }
                    }
                    smsAccount = PhoneAccountModel(phoneNumber: phonenumber, smsacctid: id, color:color, gradientAvatar: gradientAvatar)
                    updated = true
                    if self.selectedAccount == nil {
                        self.selectedAccount = smsAccount
                    }
                    //IOSM#105
                    smsAccount?.save(completion: {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .newPhoneNumberAdded, object: nil)
                        }
                    })
                }
                currentAccounts.append(smsAccount!)
            }
            index+=1
        }
        //remove from our database any numbers removed via console
        for acct in getExistingAccounts() {
            if let acctnum = acct.grdbRecord?.phoneNumber {
                var found = false
                for num in phonenumbers {
                    if acctnum == num {
                        found = true
                    }
                }
                if !found {
                    updated = true
                    acct.remove(completion: {
                        if self.selectedAccount?.grdbRecord?.phoneNumber == acctnum {
                            self.currentAccounts = self.getExistingAccounts()
                            if self.currentAccounts.count > 0 {
                                self.selectedAccount = self.currentAccounts.first
                            } else {
                                self.selectedAccount = nil
                            }
                        }
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .userPhoneNumberDetailsUpdated, object: nil)
                        }
                    })
                }
            }
        }
        if updated == false {
            if (self.currentAccounts.count > 0 && self.selectedAccount == nil) {
                self.selectedAccount = self.currentAccounts.first
            }
        }
    }
    private func getNextAvailableGradientAvatar() -> PhoneNumberGradientAvatar? {
        let allAvatars: [PhoneNumberGradientAvatar] = [.blueGradient, .megentaGradient, .orangeGradient, .greenGradient, .pinkGradient]
        guard let avatarDictionary: [String: String] = UserDefaultsService.shared.get(for: \.phoneNumberGradientAvatarDictionary) else {
            return allAvatars.first
        }
        let usedAvatars: [PhoneNumberGradientAvatar] = avatarDictionary.compactMap { PhoneNumberGradientAvatar(rawValue: $0.value) }
        return allAvatars.first { !usedAvatars.contains($0) }
    }
    func queryForVMInfo(responseHandler: ((Bool) -> Void)? = nil) {
        guard !SecurityCenter.isProxyDetected else { responseHandler?(false); return }
        guard let selacct = self.selectedAccount, let selnumber = selacct.grdbRecord?.phoneNumber else {
            responseHandler?(false)
            return
        }
        Task { [weak self] in
            guard let self,
                  let headers = await GlacierAPIHeaders.authHeaders() else {
                responseHandler?(false)
                return
            }
            var vmnumber = selnumber
            if selnumber.hasPrefix("+") {
                vmnumber.removeFirst()
            }
            self.updatingRecordings = true
            self.sessionManager.request(self.voicemailListUrl(), method: .get, parameters: ["number":vmnumber], encoding: URLEncoding.default, headers: headers)
                .validate()
                .responseData(queue: self.internalQueue) { response in
                    switch response.result {
                    case .success(let value):
                        if let results = String(data: value, encoding: .utf8) {
                            self.handleVMs(response: results, responseHandler: responseHandler)
                        } else {
                            self.updatingRecordings = false
                            responseHandler?(false)
                        }
                        return
                    case .failure(let error):
                        self.updatingRecordings = false
                        Log.calls.error("Error getting voicemail list: \(error)")
                        responseHandler?(false)
                        return
                    }
                }
        }
    }
    func handleVMs(response: String, responseHandler: ((Bool) -> Void)? = nil) {
        guard let data = response.data(using: .utf8) else { return }
        let parsed: Any?
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: .allowFragments)
        } catch {
            Log.calls.error("Failed to parse voicemail response: \(error)")
            parsed = nil
        }
        if let json = parsed as? Dictionary<String,Any> {
            var recordings = [VoicemailRecord]()
            var hasUnreadVM = false
            if let jdata = json["data"] as? Dictionary<String,Any>, let jrecordings = jdata["recordings"] as? [Dictionary<String,String>] {
                for rec in jrecordings {
                    let recording = VoicemailRecord()
                    recording.from = rec["from"] ?? ""
                    recording.recordingSid = rec["recordingsid"] ?? ""
                    recording.time = rec["time"] ?? ""
                    recording.duration = rec["duration"] ?? ""
                    recording.callSid = rec["callsid"] ?? ""
                    recording.to = rec["to"] ?? ""
                    recording.url = rec["url"] ?? ""
                    recording.status = rec["status"] ?? "read" //unread, read, deleted
                    if recording.status == "new" {
                        hasUnreadVM = true
                    }
                    if let to = recording.to, let contact = ContactsManager.shared.matchContact(for: to) {
                        recording.contact = contact
                    }
                    recordings.append(recording)
                }
                let userInfo = [kNotificationType:kNotificationVoicemailType]
                if recordings.count > self.selectedRecordings.count, vmInitialized {
                    DispatchQueue.main.async {
                        GlacierApplicationDelegate.appDelegate.showLocalNotificationWith(
                            identifier: nil,
                            body: NSLocalizedString("New voicemail", comment: "New voicemail notification title"),
                            badge: 0,
                            userInfo: userInfo
                        )
                    }
                }
            }
            self.selectedRecordings = recordings
            vmInitialized = true
            self.hasNewVM = hasUnreadVM
            self.updatingRecordings = true
            responseHandler?(true)
            DispatchQueue.main.async {
                for phoneDelegate in self.phoneDelegates {
                    phoneDelegate.voicemailUpdated()
                }
            }
        } else {
            self.updatingRecordings = false
            responseHandler?(false)
        }
    }
    func deleteVM(_ vmsid: String) {
        self.updateVMStatus(vmsid, status: TwilioBackendManager.deleteVMStatus)
    }
    func listenedToVM(_ vmsid: String) {
        self.updateVMStatus(vmsid, status: TwilioBackendManager.readVMStatus)
    }
    func updateVMStatus(_ vmsid:String, status:String) {
        guard !SecurityCenter.isProxyDetected else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
            self.sessionManager.request(self.updateVoicemailStatusUrl(), method: .post, parameters: ["recordingSid":vmsid, "status":status], encoding: JSONEncoding.default, headers: headers)
                .validate()
                .responseData(queue: self.internalQueue) { response in
                    switch response.result {
                    case .success(_):
                        self.queryForVMInfo()
                        return
                    case .failure(let error):
                        Log.calls.error("Error updating voicemail status: \(error)")
                        return
                    }
                }
        }
    }
    func getExistingAccount(phoneNumber:String) -> PhoneAccountModel? {
        return PhoneAccountModel.existingAccount(with: phoneNumber)
    }
    func getExistingAccounts() -> [PhoneAccountModel] {
        return PhoneAccountModel.allAccounts()
    }
    func getAccountName() -> String? {
        let account = GlacierAccountModel.getGlacierAccount()
        return account?.username
    }
    func setPhoneDelegate(_ phoneDelegate:TwilioAccountDelegateProtocol) {
        self.phoneDelegates.append(phoneDelegate)
    }
    func removeLastPhoneDelegate() {
        self.phoneDelegates.removeLast()
    }
}
extension TwilioBackendManager {
    func setCallHistoryDelegate(_ historyDelegate:CallHistoryDelegateProtocol) {
        self.callHistoryDelegate = historyDelegate
    }
    func queryCallHistory() {
        self.queryCallHistory(500)
    }
    func queryCallHistory(_ limitNum:Int, responseHandler: ((Data?) -> Void)? = nil) {
        guard !SecurityCenter.isProxyDetected else { responseHandler?(nil); return }
        //apikey -- number (selected, or all), limit 500
        /*guard let apikey = self.getApiKey() else {
            self.callHistoryDelegate?.callHistoryUpdated(nil)
            return
        }*/
        Task { [weak self] in
            guard let self,
                  let headers = await GlacierAPIHeaders.authHeaders() else {
                responseHandler?(nil)
                return
            }
            let limit = String(limitNum)
            if let currentNumber = self.selectedAccount?.grdbRecord?.phoneNumber
            {
                let req = self.callHistoryUrl()
                //print("***** \(req)")
                self.sessionManager.request(req, method: .get, parameters: ["number": currentNumber, "limit": limit], encoding: URLEncoding.default, headers: headers)
                    .validate()
                    .responseData(queue: self.internalQueue) { response in
                        switch response.result {
                        case .success(let value):
                            self.callHistoryDelegate?.callHistoryUpdated(value)
                            responseHandler?(value)
                            return
                        case .failure(let error):
                            Log.calls.error("Error getting history: \(error)")
                            self.callHistoryDelegate?.callHistoryUpdated(nil)
                            responseHandler?(nil)
                            return
                        }
                    }
            } else {
                self.callHistoryDelegate?.callHistoryUpdated(nil)
                responseHandler?(nil)
            }
        }
    }
}
//IOSM#76
public class GlacierPhone:NSObject {
    public var selectedTwilionumber: [Dictionary<String,String>] = []
    public var addUserToPurchaseNumbers:Bool = false
    public func getJson() -> String {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(self.selectedTwilionumber)
            if let jsonString = String(data: data, encoding: .utf8) {
                return jsonString
            }
        } catch {
          Log.calls.error("Error: \(error)")
        }
        return ""
    }
}
public protocol TwilioAccountDelegateProtocol:AnyObject {
    func availableNumbersUpdated(_ availableNumbers: [GlacierPhoneNumber])
    func setSelectedAccount(_ account: PhoneAccountModel?)
    func voicemailUpdated()
}
public extension TwilioAccountDelegateProtocol {
    func availableNumbersUpdated(_ availableNumbers: [GlacierPhoneNumber]) {}
    func setSelectedAccount(_ account: PhoneAccountModel?) {}
    func voicemailUpdated() {}
}
public protocol CallHistoryDelegateProtocol:AnyObject {
    func callHistoryUpdated(_ historyData: Data?)
    //func handleToken(_ token: String)
}
extension String {
    func insertingSpace(every n: Int) -> String {
        var result: String = ""
        let characters = Array(self)
        stride(from: 0, to: characters.count, by: n).forEach {
            result += String(characters[$0..<min($0+n, characters.count)])
            if $0+n < characters.count {
                result += " "
            }
        }
        return result
    }
}
public class VoicemailRecord:AnyObject {
    public var id: String = UUID().uuidString
    public var from:String?
    public var recordingSid:String?
    public var time:String?
    public var duration:String?
    public var callSid:String?
    public var to:String? //ALF IOSM-503
    public var url:String?
    public var status:String?
    var contact:PhoneContact?
}
extension VoicemailRecord: Identifiable, Hashable {
    public static func == (lhs: VoicemailRecord, rhs: VoicemailRecord) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
public extension NSData {
    func hexString() -> String {
        return (self as Data).toHexString()
    }
}
public extension Data {
    func toHexString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
struct TwilioResponse: Codable {
    let status: Int
    let message: String
    let data: [TwilioNumber]
}
struct TwilioNumber: Codable {
    let friendlyName: String
    let phoneNumber: String
    let region: String
}
