//
//  CallManager.swift
//  Created by Andy Friedman on 2/10/20.
//  Copyright © 2020 Glacier Security. All rights reserved.

import UIKit
import Foundation
import CallKit
import TwilioVoice
import AVFoundation

public protocol GlacierCallDelegateProtocol: AnyObject {
    //func activateAudio(_ activate: Bool)
    func holdCall(_ onHold: Bool)
    func muteAudio(_ shouldMute: Bool)
    func disconnectCall(_ userInitiated: Bool)
    func isConnected() -> Bool
    func setStatus(_ status:String)
    func setBluetoothEnabled(_ bluetoothEnabled: Bool) //ALF IOSM-451
    func handleAudioDenied() //ALF IOSM-464
}

public enum SpeakerChoice : UInt {
    case receiver = 0
    case speaker = 1
    case bluetooth = 2
}

/**
 * The purpose of this class is to collect and process server
 * and push info in one place.
 *
 * All public members must be accessed from the main queue.
 */
public class CallManager : NSObject {
    private static let shared = CallManager()
    
    public static let CallManagerErrorDomain = "CallManagerErrorDomain"

    let kCachedDeviceToken = "CachedDeviceToken"
    let kCachedBindingDate = "CachedBindingDate"
    let kRegistrationTTLInDays = 365
    
    var cAccount:GlacierAccountModel?
    var currentCall:TwilioCall?
    var alternateCall:TwilioCall?
    var currentUuid:UUID?
    var lastUuid:UUID? //IOSM-569
    var notificationUuid:String?
    var awaitingCallResponse:Bool = false
    var isBusy:Bool = false
    var busyTone:Bool = false
    var busyId:String?
    var endedCall:Bool = false
    var receivedRetract:Bool = false
    var hasIncomingVoiceCall:Bool = false
    var audioSession:AVAudioSession?
    
    var activeCallInvite:CallInvite?
    var activeCall:Call?
    
    var bluetoothAvailable: Bool = false
    var bluetoothEnabled: Bool = false
    var speakerChoice: SpeakerChoice = SpeakerChoice.receiver
    
    public var callToken:String?
    public var deviceToken:Data?

    /// Stores a call that was deferred while waiting for a token refresh.
    private var pendingCall: PhoneContact?

    private weak var gcdelegate: GlacierCallDelegateProtocol? = nil
    private var callKitCompletionCallback: ((Bool) -> Void)?
    
    // CallKit components
    let callKitProvider: CXProvider
    let callKitCallController: CXCallController
    //var callKitCompletionHandler: ((Bool)->Swift.Void?)? = nil
    var userInitiatedDisconnect: Bool = false
    
    var callTimeout: DispatchWorkItem?
    var unconnectedAnswerCallAction: CXAnswerCallAction?
    var player: AVAudioPlayer?
    var incomingCallHandle:CXHandle?
    
    private var callObserver: CXCallObserver?
    
    /**
     * We will create an audio device and manage it's lifecycle in response to CallKit events.
     */
    var tvoaudioDevice: TwilioVoice.DefaultAudioDevice = TwilioVoice.DefaultAudioDevice()
    let syncQueue = DispatchQueue(label: "callManager.syncQueue")

    deinit {
        // CallKit has an odd API...must call invalidate or the CXProvider is leaked.
        callKitProvider.invalidate()
        
        NotificationCenter.default.removeObserver(self)
    }
    
    private override init() {
        let configuration = CXProviderConfiguration()
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        //configuration.ringtoneSound = "MarimbaRingtone.wav"
        configuration.supportsVideo = false
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false;
        if let callKitIcon = UIImage(named: "glacier-logo") {
            configuration.iconTemplateImageData = callKitIcon.pngData()
        }
        callKitProvider = CXProvider(configuration: configuration)
        callKitCallController = CXCallController()
        
        super.init()
        self.cAccount = nil
        
        //ALF IOSM-451
        NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChange(_:)), name: NSNotification.Name(rawValue: AVAudioSession.routeChangeNotification.rawValue), object: nil)
        
        callKitProvider.setDelegate(self, queue: nil)
        callObserver = CXCallObserver()
        callObserver?.setDelegate(self, queue: DispatchQueue.main)
        
        self.tvoaudioDevice.block = {
            do {
                TwilioVoice.DefaultAudioDevice.DefaultAVAudioSessionConfigurationBlock()
                let audioSession = AVAudioSession.sharedInstance()
                
                try audioSession.setMode(.voiceChat)
                try audioSession.overrideOutputAudioPort(AVAudioSession.PortOverride.none)
                
            } catch {
                Log.calls.error("Twilio audio Fail: \(error.localizedDescription)")
            }
        }
        
        self.audioSession = AVAudioSession.sharedInstance()
        
        TwilioVoiceSDK.audioDevice = self.tvoaudioDevice
        self.tvoaudioDevice.block()
    }
    
    public class func sharedCallManager() -> CallManager {
        return shared
    }
    
    public func setAccount(_ account: GlacierAccountModel) {
        self.cAccount = account
    }
    
    public func hasAccount() -> Bool {
        if (self.cAccount != nil) {return true}
        
        return false
    }
    
    public func setGlacierCallDelegate(_ del: GlacierCallDelegateProtocol?) {
        self.gcdelegate = del
        // If a new delegate registers while the call is already connected (e.g. incoming call
        // that connected before PhoneCallScreen fully appeared), notify it immediately.
        if let del = del, isCallActive() {
            del.setStatus("connected")
        }
    }
    
    // MARK: Public API
    
    func makeVoiceCall(_ receiver: String, name: String) {
        let initials = GlacierImages.stringInitials(withMaxCharacters: name, maxCharacters: 2) ?? ""
        var contact = PhoneContact(id: UUID().uuidString, name: name, initials: initials, phoneNumber: receiver)
        if let foundContact = ContactsManager.shared.matchContact(for: receiver) {
            contact = foundContact
        }
        self.makeVoiceCall(contact)
    }
    
    func makeVoiceCall(_ contact:PhoneContact) {//receiver: String, name: String) {
        guard !SecurityCenter.isProxyDetected else {
            Log.calls.warning("Call blocked: proxy detected")
            return
        }
        guard let callto = CallManager.formatDialString(contact.phoneNumber) else {
            Log.calls.error("Unable to format phone number for dialing")
            return
        }

        // If the voice token is missing or about to expire, refresh it first and
        // resume the call once twilioTokenReceived delivers the new token.
        let backend = TwilioBackendManager.sharedMgr()
        if callToken == nil || (callToken.map { backend.needsTokenRefresh($0) } ?? true) {
            Log.calls.notice("callToken missing or stale – refreshing before call")
            pendingCall = contact
            backend.queryForTwilioTokens()
            return
        }

        var updatedContact = contact
        updatedContact.phoneNumber = callto

        let call = TwilioCall()
        call.receiver = callto
        call.calltitle = contact.name //ALF IOSM-503 and change to receivers above
        call.caller = backend.selectedAccount?.grdbRecord?.phoneNumber
        self.currentUuid = UUID.init()
        call.callUuid = self.currentUuid
        call.isCaller = true
        call.contact = updatedContact
        self.currentCall = call

        //call CallKit here before sending to server
        if let uuid = self.currentUuid {
            performStartCallAction(uuid: uuid, receiver: contact.name) //receiver)
        }
    }
    
    static func cleanPhoneNumber(_ phoneNumber: String) -> String {
        let cleanedPhoneNumber = phoneNumber.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        return cleanedPhoneNumber
    }
    
    static func formatDialString(_ phoneNumber: String) -> String? {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if trimmed.hasPrefix("+") {
            let digitsOnly = trimmed.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            guard digitsOnly.isEmpty == false else { return nil }
            return "+" + digitsOnly
        }

        let digitsOnly = cleanPhoneNumber(trimmed)
        guard digitsOnly.isEmpty == false else { return nil }

        if digitsOnly.count == 10 {
            return "+1" + digitsOnly
        }

        return "+" + digitsOnly
    }
}

public class TwilioCall:AnyObject {
    public var caller:String?
    public var receiver:String?
    public var roomname:String?
    public var token:String?
    public var callid:String?
    public var calltitle:String? //ALF IOSM-503
    public var status:String?
    public var systemMessage:String?
    public var callUuid:UUID?
    public var outgoing:Bool = true
    public var isGroup:Bool = false //IOSM-545
    public var isCaller:Bool = false //IOSM-527b
    var contact:PhoneContact?
    var callstatus:CallStatus = .disconnected
    var answerCallAction: CXAnswerCallAction?
}

public enum CallStatus : Int {
    case disconnected = 0
    case waiting = 1
    case connecting = 2
    case connected = 3
    case unknown = 4
}

extension CallManager : CXProviderDelegate {

    public func providerDidReset(_ provider: CXProvider) {
        Log.calls.info("Twilio providerDidReset:")

        // AudioDevice is enabled by default
        // The Phone code has this as false. why?
        self.tvoaudioDevice.isEnabled = false
        
        //room?.disconnect()
        gcdelegate?.disconnectCall(false)
    }

    public func providerDidBegin(_ provider: CXProvider) {
        Log.calls.info("Twilio providerDidBegin")
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Log.calls.info("didActivateAudioSession:")
        if let curcall = self.currentCall {
            Log.calls.info("didActivateAudioSession isVoice:")
            self.tvoaudioDevice.isEnabled = true
        }
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Log.calls.info("Twilio provider:didDeactivateAudioSession:")
        self.tvoaudioDevice.isEnabled = false
        self.audioSession = nil
        CallManager.configureDefaultAudioSession()
    }

    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        Log.calls.notice("Twilio provider:timedOutPerformingAction:")
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Log.calls.notice("Twilio provider:performStartCallAction:")

        /*
         * Configure the audio session, but do not start call audio here, since it must be done once
         * the audio session has been activated by the system after having its priority elevated.
         */

        callKitProvider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        

            
            var callContact = self.currentCall?.contact
            if callContact == nil, let name = self.currentCall?.calltitle, let receiver = self.currentCall?.receiver, let initials = GlacierImages.stringInitials(withMaxCharacters: name, maxCharacters: 2) {
                callContact = PhoneContact(id: UUID().uuidString, name: name, initials: initials, phoneNumber: receiver)
            }
            
            guard let contact = callContact else {
                return
            }
            
            performMakeVoiceCall(uuid: action.callUUID, contact: contact) { success in
                if success {
                    Log.calls.notice("performMakeVoiceCall() successful")
                    self.callKitProvider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
                } else {
                    Log.calls.error("performMakeVoiceCall() failed")
                }
            }
        
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Log.calls.notice("CXProvider:performAnswerCallAction: \(action.callUUID)")

        /*
         * Configure the audio session, but do not start call audio here, since it must be done once
         * the audio session has been activated by the system after having its priority elevated.
         */
        self.callTimeout?.cancel() //IOSM-569
        
        if self.currentCall != nil {
            self.currentCall?.callstatus = .connecting
            self.currentCall?.answerCallAction = action
        } else {
            self.unconnectedAnswerCallAction = action
            let task = DispatchWorkItem {
                Log.calls.notice("calling timeout")
                self.performTimeout()
            }
            callTimeout = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: callTimeout!)
        }

        self.handleAnswerCall()
        self.awaitingCallResponse = false
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        //print("Twilio provider:performEndCallAction: with *** userInitiatedDisconnect: \(userInitiatedDisconnect)")
        Log.calls.notice("CXProvider:CXEndCallAction:")

        self.callTimeout?.cancel()

        if isBusy, hasIncomingVoiceCall == false {
            action.fulfill()
            Log.calls.info("CXProvider:CXEndCallAction: returning early")
            return
        }
        
        if let invite = activeCallInvite {
            invite.reject()
        } else if !userInitiatedDisconnect {
            Log.calls.info("CXProvider:CXEndCallAction: !userInitiatedDisconnect")
            gcdelegate?.disconnectCall(false)
            if self.endedCall == false, let call = self.currentCall, !self.busyTone, self.receivedRetract == false {
                Log.calls.info("CXProvider:CXEndCallAction: about to cancelCall")
            }
        } else {
            // User-initiated end: disconnect the Twilio call if it still exists,
            // then always notify the delegate so the UI is dismissed even if
            // activeCall was already cleared by a concurrent callDidDisconnect.
            if let call = activeCall {
                Log.calls.info("CXProvider:CXEndCallAction: disconnecting activeCall")
                call.disconnect()
            }
            gcdelegate?.disconnectCall(false)
        }

        self.endedCall = false
        self.hasIncomingVoiceCall = false
        self.awaitingCallResponse = false
        let hasActiveCall = self.isCallActive()
        if !hasActiveCall || (hasActiveCall && activeCallInvite == nil) {
            Log.calls.info("performEndCallAction: nullifying currentCall")
            self.currentUuid = nil
            self.notificationUuid = nil
            self.currentCall = nil
            self.alternateCall = nil
        }
        self.activeCallInvite = nil
        self.isBusy = false
        self.busyTone = false
        self.receivedRetract = false
        action.fulfill()
        Log.calls.info("CXProvider:CXEndCallAction: end")
    }
    
    func finalizeVoiceCall() {
        if let uuid = self.activeCall?.uuid {
            callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        }
        self.activeCallInvite = nil
        self.activeCall = nil
        
        if let url = Bundle.main.url(forResource: "MarimbaBlink", withExtension: "wav") {
            self.playSound(soundUrl: url)
        }
        self.performSpeakerAction(selection: SpeakerChoice.bluetooth)
        self.setGlacierCallDelegate(nil)
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Log.calls.info("Twilio provider:performSetMutedCallAction:")
        
        gcdelegate?.muteAudio(action.isMuted)
        
        /*if let call = activeCalls[action.callUUID.uuidString] {
            call.isMuted = action.isMuted
            action.fulfill()
        } else {
            action.fail()
        }*/
        
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Log.calls.info("Twilio provider:performSetHeldCallAction:")

        let cxObserver = callKitCallController.callObserver
        let calls = cxObserver.calls

        guard let call = calls.first(where:{$0.uuid == action.callUUID}) else {
            action.fail()
            return
        }

        if call.isOnHold {
            gcdelegate?.holdCall(false)
        } else {
            gcdelegate?.holdCall(true)
        }
        
        /*if let call = activeCalls[action.callUUID.uuidString] {
            call.isOnHold = action.isOnHold

            /** Explicitly enable the TVOAudioDevice.
            * This is workaround for an iOS issue where the `provider(_:didActivate:)` method is not called
            * when un-holding a VoIP call after an ended PSTN call.
            */ https://developer.apple.com/forums/thread/694836
            if !call.isOnHold {
                audioDevice.isEnabled = true
                activeCall = call
            }

            toggleUIState(isEnabled: true, showCallControl: true)

            action.fulfill()
        } else {
            action.fail()
        }*/
        
        action.fulfill()
    }
}

extension CallManager {
    
    static func configureDefaultAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        
        Log.calls.debug("Configuring default audio session...")
        
        var options: AVAudioSession.CategoryOptions = []
        options.insert(.mixWithOthers)

        do {
            try audioSession.setCategory(.playback, mode: .default, options: options)
        } catch {
            Log.calls.error("Failed to configure audio session: \(error)")
        }

        do {
            try audioSession.setActive(true, options: [])
        } catch {
            Log.calls.error("Error activating audio session: \(error)")
        }

        Log.calls.debug("Current audio route: \(audioSession.currentRoute)")
    }

    func performStartCallAction(uuid: UUID, receiver: String?) {
        let callHandle = CXHandle(type: .generic, value: receiver ?? "")
        let startCallAction = CXStartCallAction(call: uuid, handle: callHandle)
        
        startCallAction.isVideo = false
        
        let transaction = CXTransaction(action: startCallAction)
        
        callKitCallController.request(transaction)  { error in
            if let error = error {
                Log.calls.error("StartCallAction transaction request failed: \(error.localizedDescription)")
                return
            }
            Log.calls.notice("StartCallAction transaction request successful")
        }
    }
    
    func performMakeVoiceCall(uuid: UUID, contact: PhoneContact, completionHandler: @escaping (Bool) -> Void) {
        guard let accessToken = self.callToken else {
            completionHandler(false)
            return
        }

        callKitCompletionCallback = completionHandler

        let connectOptions = ConnectOptions(accessToken: accessToken) { builder in
            builder.params = ["to": self.currentCall?.receiver ?? "",
                              "from": self.currentCall?.caller ?? ""]
            builder.uuid = uuid
        }

        let call = TwilioVoiceSDK.connect(options: connectOptions, delegate: self)
        activeCall = call
    }
    
    func performAnswerVoiceCall() {
        guard let callInvite = activeCallInvite else {
            Log.calls.notice("No CallInvite matches the UUID")
            return
        }

        let acceptOptions = AcceptOptions(callInvite: callInvite) { builder in
            builder.uuid = callInvite.uuid
        }

        var callContact = self.currentCall?.contact
        if callContact == nil {
            var contact = PhoneContact(id: UUID().uuidString, name: "Unknown", initials: "U", phoneNumber: "Unknown")
            var contactnum = contact.phoneNumber
            if let tcall = self.currentCall, let from = tcall.caller {
                contactnum = from
                contact.name = tcall.calltitle ?? from
                contact.phoneNumber = from
            } else if let from = callInvite.from {
                contactnum = from
                contact.name = from
                contact.phoneNumber = from
            }

            if let foundContact = ContactsManager.shared.matchContact(for: contactnum) {
                contact = foundContact
            }
            callContact = contact
        }

        guard let contact = callContact else {
            Log.calls.notice("No contact found for call")
            return
        }

        // Open PhoneCallScreen via the same notification path used for outgoing calls.
        // The isIncomingCall flag tells PhoneCallVM to register as gcdelegate without
        // placing a new outgoing call.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .startPhoneCall,
                object: nil,
                userInfo: [
                    GlacierNotificationProperties.phoneNumber: contact.phoneNumber,
                    GlacierNotificationProperties.personName: contact.name,
                    GlacierNotificationProperties.isIncomingCall: true
                ]
            )
        }

        // Accept with CallManager as the Twilio CallDelegate. callDidConnect will
        // call reportCallConnected and notify gcdelegate when the call is established.
        let call = callInvite.accept(options: acceptOptions, delegate: self)
        activeCall = call
        activeCallInvite = nil
    }
    
    func dialedDigit(_ digit: String) {
        if let curCall = self.activeCall {
            curCall.sendDigits(digit)
            //print("**** dialed digit: \(digit)")
        }
    }
    
    func handleAnswerCall() {
        guard let tcall = self.currentCall else { return }
        self.performAnswerVoiceCall()
    }
    
    func isBluetoothAvailable() -> Bool {
        return self.bluetoothAvailable
    }
    
    //ALF IOSM-451
    @objc func audioRouteChange(_ notification:Notification) {
        //if (IPAD)
        //    return;
        //var headphonesConnected = false
        
        let session = AVAudioSession.sharedInstance()
        let newRoute = session.currentRoute
        if (newRoute.outputs.count > 0) {
            let route = newRoute.outputs[0].portType
            if ((route == AVAudioSession.Port.bluetoothA2DP || route == AVAudioSession.Port.bluetoothHFP)) {
                if (!bluetoothAvailable) {
                    bluetoothAvailable = true
                    gcdelegate?.setBluetoothEnabled(bluetoothAvailable)
                }
            } else {
                if (bluetoothAvailable) {
                    bluetoothAvailable = false
                    gcdelegate?.setBluetoothEnabled(bluetoothAvailable)
                }
            }
        }
    }
    
    //ALF IOSM-437
    func isRinging() -> Bool {
        if (self.awaitingCallResponse) {
            return true
        }
        return false
    }

    public func reportIncomingCall(uuid: UUID, callId: String, caller: String, isVoice: Bool, completion: ((NSError?) -> Void)? = nil) {
        
        var inCall = false
        var calltitle = caller
        if (self.currentCall == nil) {
            self.currentUuid = uuid
            self.lastUuid = uuid //IOSM-569
            let call = TwilioCall()
            call.callid = callId
            call.caller = caller
            call.callUuid = uuid
            call.outgoing = false
            call.isCaller = false
            
            //print("***** reportIncomingCall about to getMAtchingContact for \(caller)")
            if isVoice, let contact = ContactsManager.shared.matchContact(for: caller) {
                call.calltitle = contact.name
                call.contact = contact
            }
            calltitle = call.calltitle ?? caller
            
            self.currentCall = call
            self.awaitingCallResponse = true
            
        } else { //call exists
            Log.calls.info("we think we have current call, should be busy?")
            inCall = true
        }
            
        let callHandle = CXHandle(type: .generic, value: calltitle)
            
        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = callHandle
        callUpdate.supportsDTMF = isVoice
        callUpdate.supportsHolding = isVoice
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false
        callUpdate.hasVideo = false
            
        Log.calls.notice("reportIncomingCall reportNewIncomingCall")
        callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
            if error == nil {
                Log.calls.notice("Incoming call successfully reported.")
            } else {
                Log.calls.error("Failed to report incoming call successfully: \(String(describing: error?.localizedDescription)).")
            }
                
            completion?(error as NSError?)
        }
        
        if (!inCall) {
            let task = DispatchWorkItem { self.performTimeout() }
            callTimeout = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: callTimeout!)
        }
    }
    
    private func performTimeout() {
        if (self.awaitingCallResponse) {
            if let callAction = self.unconnectedAnswerCallAction {
                callAction.fail()
                //alert user
            }
            
            if let uuid = self.currentUuid {
                self.performEndCallAction(uuid: uuid, userInitiated: false)
            }
            self.unconnectedAnswerCallAction = nil
        }
    }
    
    func playSound(soundUrl: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: soundUrl, fileTypeHint: AVFileType.wav.rawValue)
        } catch _ {
            return // if it doesn't exist, don't play it
        }

        guard let player = player else { return }

        player.play()
    }
    
    func stopSound() {
        self.busyTone = false
        guard let player = player else { return }
        player.stop()
    }
    
    func performCancelCallAction(userInitiated: Bool) {
        if let uuid = self.currentUuid {
            performEndCallAction(uuid: uuid, userInitiated: userInitiated)
        }
    }

    func performEndCallAction(uuid: UUID, userInitiated: Bool) {
        self.endedCall = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.stopSound()
            TwilioBackendManager.sharedMgr().queryCallHistory(4)
        }
        Log.calls.notice("performEndCallAction with \(uuid) and userInitiated \(userInitiated)")
        userInitiatedDisconnect = userInitiated
        
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)

        callKitCallController.request(transaction) { error in
            if let error = error {
                Log.calls.error("EndCallAction transaction request failed: \(error.localizedDescription).")
                // CallKit rejected the action (e.g. it already considers the call
                // ended). provider(_:perform:CXEndCallAction) will not fire, so force
                // cleanup here so the UI is not left stuck.
                DispatchQueue.main.async {
                    self.gcdelegate?.disconnectCall(userInitiated)
                }
                return
            }

            Log.calls.notice("EndCallAction transaction request successful")
        }
    }

    func handleBusy(uuid: UUID, busyId: String, isVoice: Bool) {
        self.isBusy = true
        self.busyId = busyId
        self.hasIncomingVoiceCall = isVoice
        self.endedCall = true
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)

        callKitCallController.request(transaction) { error in
            if let error = error {
                Log.calls.error("EndCallAction transaction request failed: \(error.localizedDescription).")
                return
            }

            Log.calls.notice("EndCallAction transaction request successful")
        }
    }

    func reportCallDisconnected(uuid: UUID, error: Error?) {
        //ALF IOSM-515
        self.isBusy = false
        self.busyTone = false
        
        //IOSM-527b if groupCall, and we are caller, send callEnded message with
        //if let curcall = self.currentCall, curcall.isCaller {
            //self.sendEndCallMessage(curcall)
        //}
        
        if !userInitiatedDisconnect { //}, let error = error {
            var reason = CXCallEndedReason.remoteEnded

            if error != nil {
                reason = .failed
            }

            self.callKitProvider.reportCall(with: uuid, endedAt: nil, reason: reason)
        }
        
        self.awaitingCallResponse = false
        self.currentUuid = nil
        self.notificationUuid = nil
        self.currentCall = nil
        self.alternateCall = nil
        self.activeCall = nil
        self.userInitiatedDisconnect = false
    }
    
    public func reportCallConnected(uuid: UUID?, connectTime: Date) {
        self.stopSound()
        
        self.currentCall?.status = "inprogress" //ALF IOSM-503
        
        let cxObserver = callKitCallController.callObserver
        let calls = cxObserver.calls
        if let call = calls.first(where:{$0.uuid == uuid}) {
            if call.isOutgoing {
                if let calluuid = uuid {
                    self.callKitProvider.reportOutgoingCall(with: calluuid, connectedAt: connectTime)
                } else if let myuuid = self.currentUuid {
                    self.callKitProvider.reportOutgoingCall(with: myuuid, connectedAt: connectTime)
                }
            }
        }
        
        //ALF IOSM-464 check permissions
        checkAudioPermissions()
    }
    
    //ALF IOSM-464
    public func checkAudioPermissions() -> Bool {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .denied:
            gcdelegate?.handleAudioDenied()
            return true
        case .undetermined:
            gcdelegate?.handleAudioDenied()
            return true
        case .granted: break
        default:
            break
        }
        
        return false
    }
    
    //ALF IOSM-464, true means it still needs authorization
    public func checkVideoPermissions() -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            return true
        }
        
        return false
    }
    
    public func performMuteAction(uuid: UUID, isMuted: Bool) {
        let muteAction = CXSetMutedCallAction(call: uuid, muted: isMuted)
        let transaction = CXTransaction(action: muteAction)

        callKitCallController.request(transaction)  { error in
            DispatchQueue.main.async {
                if let error = error {
                    Log.calls.error("SetMutedCallAction transaction request failed: \(error.localizedDescription)")
                    return
                }
                Log.calls.info("SetMutedCallAction transaction request successful")
            }
        }
    }
    
    public func performSpeakerAction(isSelected: Bool) {
        
        self.tvoaudioDevice.block = {
            do {
                let audioSession = AVAudioSession.sharedInstance()
                
                if(isSelected) {
                    try audioSession.setMode(.videoChat)
                    if (self.bluetoothAvailable) {
                        try audioSession.overrideOutputAudioPort(AVAudioSession.PortOverride.speaker)
                    }
                } else {
                    try audioSession.setMode(.voiceChat)
                    try audioSession.overrideOutputAudioPort(AVAudioSession.PortOverride.none)
                }
            } catch {
                Log.calls.error("Fail: \(error.localizedDescription)")
            }
        }
        
        self.tvoaudioDevice.block()
    }
    
    public func performSpeakerAction(selection: SpeakerChoice) {
        
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.setActive(true)

            if session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
                // Speaker is currently on → turn it off
                try session.overrideOutputAudioPort(.none)
                //speakerButton.setTitle("Speaker Off", for: .normal)
            } else {
                // Speaker is off → turn it on
                try session.overrideOutputAudioPort(.speaker)
                //speakerButton.setTitle("Speaker On", for: .normal)
            }
        } catch {
            Log.calls.debug("Failed to toggle speaker: \(error)")
        }
    }
    
    public func isSpeakerMode() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute
        let volume = audioSession.outputVolume
                
        // Check if the output route is using the speaker
        for output in currentRoute.outputs {
            if output.portType == .builtInSpeaker {
                return true
            }
        }
        
        return false
    }
}

extension CallManager {
    
    func twilioTokenReceived(_ token: String) {
        self.callToken = token
        self.registerWithTwilio()

        // Resume any call that was deferred while waiting for a token refresh.
        if let contact = pendingCall {
            pendingCall = nil
            makeVoiceCall(contact)
        }
    }
    
    func credentialsUpdated(_ token: Data) {
        self.deviceToken = token
        self.registerWithTwilio()
    }
    
    func registerWithTwilio() {
        guard let accessToken = self.callToken, let deviceToken = self.deviceToken else {
            return
        }
        
        //guard (registrationRequired() || UserDefaults.standard.data(forKey: kCachedDeviceToken) != deviceToken) else {  return  }
        
        /*
        * Perform registration if a new device token is detected.
        */
        TwilioVoiceSDK.register(accessToken: accessToken, deviceToken: deviceToken) { error in
            if let error = error {
                Log.calls.error("An error occurred while registering: \(error.localizedDescription)")
            } else {
                Log.calls.notice("Successfully registered for VoIP push notifications.")
                    
                // Save the device token after successfully registered.
                UserDefaults.standard.set(deviceToken, forKey: self.kCachedDeviceToken)
                    
                /**
                * The TTL of a registration is 1 year. The TTL for registration for this device/identity
                * pair is reset to 1 year whenever a new registration occurs or a push notification is
                * sent to this device/identity pair.
                */
                UserDefaults.standard.set(Date(), forKey: self.kCachedBindingDate)
            }
        }
    }
    
    func unregisterWithTwilio() {
        guard let accessToken = self.callToken, let deviceToken = self.deviceToken else {
            return
        }
        
        TwilioVoiceSDK.unregister(accessToken: accessToken, deviceToken: deviceToken)
    }
    
    /**
    * The TTL of a voip registration is 1 year. The TTL for registration for this device/identity pair is reset to
    * 1 year whenever a new registration occurs or a push notification is sent to this device/identity pair.
    * This method checks if binding exists in UserDefaults, and if half of TTL has been passed then the method
    * will return true, else false.
    */
    func registrationRequired() -> Bool {
        guard
            let lastBindingCreated = UserDefaults.standard.object(forKey: kCachedBindingDate)
        else { return true }
            
        let date = Date()
        var components = DateComponents()
        components.setValue(kRegistrationTTLInDays/2, for: .day)
        let expirationDate = Calendar.current.date(byAdding: components, to: lastBindingCreated as! Date)!

        if expirationDate.compare(date) == ComparisonResult.orderedDescending {
            return false
        }
        return true;
    }
    
    func incomingCallReceived(callInfo: [AnyHashable : Any]) {
        // The Voice SDK will use main queue to invoke `cancelledCallInviteReceived:error:` when delegate queue is not passed
        TwilioVoiceSDK.handleNotification(callInfo, delegate: self, delegateQueue: nil)
    }
}

// MARK: - CallDelegate (Twilio Voice SDK – outgoing calls)
// Incoming calls use VoiceCallViewController as their CallDelegate; this extension
// handles only outgoing calls initiated via performMakeVoiceCall.

extension CallManager: CallDelegate {

    public func callDidStartRinging(call: Call) {
        Log.calls.notice("CallManager callDidStartRinging")
    }

    public func callDidConnect(call: Call) {
        Log.calls.notice("CallManager callDidConnect")
        activeCall = call
        // Fulfill any pending incoming-call answer action (no-op for outgoing)
        currentCall?.answerCallAction?.fulfill(withDateConnected: Date())
        reportCallConnected(uuid: call.uuid, connectTime: Date())
        callKitCompletionCallback?(true)
        callKitCompletionCallback = nil
        // Tell the UI delegate the call is connected so it can update status and start timer
        gcdelegate?.setStatus("connected")
    }

    public func callIsReconnecting(call: Call, error: Error) {
        Log.calls.notice("CallManager callIsReconnecting: \(error.localizedDescription)")
    }

    public func callDidReconnect(call: Call) {
        Log.calls.notice("CallManager callDidReconnect")
    }

    public func callDidFailToConnect(call: Call, error: Error) {
        Log.calls.error("CallManager callDidFailToConnect: \(error.localizedDescription)")
        callKitCompletionCallback?(false)
        callKitCompletionCallback = nil
        if let uuid = call.uuid {
            performEndCallAction(uuid: uuid, userInitiated: false)
        }
        activeCall = nil
    }

    public func callDidDisconnect(call: Call, error: Error?) {
        if let error = error {
            Log.calls.notice("CallManager callDidDisconnect with error: \(error.localizedDescription)")
        } else {
            Log.calls.notice("CallManager callDidDisconnect")
        }
        // Capture before reportCallDisconnected resets the flag
        let wasUserInitiated = userInitiatedDisconnect
        if let uuid = call.uuid {
            reportCallDisconnected(uuid: uuid, error: error)
        }
        // For remote hang-up the gcdelegate hasn't been notified yet; for user
        // hang-up it was already notified via CXEndCallAction → disconnectCall.
        if !wasUserInitiated {
            gcdelegate?.disconnectCall(false)
        }
        activeCall = nil
    }

    public func callDidReceiveQualityWarnings(call: Call, currentWarnings: Set<NSNumber>, previousWarnings: Set<NSNumber>) {
        // Quality-warning handling can be added later
    }
}

extension CallManager: NotificationDelegate {
    public func callInviteReceived(callInvite: CallInvite) {
        Log.calls.notice("callInviteReceived:")
        
        /**
         * The TTL of a registration is 1 year. The TTL for registration for this device/identity
         * pair is reset to 1 year whenever a new registration occurs or a push notification is
         * sent to this device/identity pair.
         */
        UserDefaults.standard.set(Date(), forKey: kCachedBindingDate)
        
        let callerInfo: TVOCallerInfo = callInvite.callerInfo
        if let verified: NSNumber = callerInfo.verified {
            if verified.boolValue {
                Log.calls.notice("Call invite received from verified caller number!")
            }
        }
        Log.calls.notice("Call invite received with uuid \(callInvite.uuid) and sid \(callInvite.callSid)!")
        
        activeCallInvite = callInvite
        if let from = callInvite.from?.replacingOccurrences(of: "client:", with: "") {
            let callId = callInvite.callSid
            let onCall = (self.currentCall != nil)
            self.reportIncomingCall(uuid: callInvite.uuid, callId: callId, caller: from, isVoice: true) { _ in
                if self.activeCall != nil || onCall {
                    Log.calls.notice("ending call from callInviteReceived")
                    self.endedCall = true
                    let endCallAction = CXEndCallAction(call: callInvite.uuid)
                    let transaction = CXTransaction(action: endCallAction)

                    self.callKitCallController.request(transaction) { error in
                        self.callKitProvider.reportCall(with: callInvite.uuid, endedAt: Date(), reason: .answeredElsewhere)
                    }
                }
            }
        }
    }
    
    public func cancelledCallInviteReceived(cancelledCallInvite: CancelledCallInvite, error: Error) {
        Log.calls.notice("cancelledCallInviteCanceled:error:, error: \(error.localizedDescription)")
        
        if let callUuid = self.currentCall?.callUuid {
            performEndCallAction(uuid: callUuid, userInitiated: false)
            activeCallInvite = nil
        }
    }
}

extension CallManager: CXCallObserverDelegate {
    public func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        //
    }
    
    // Method to check if there's any active call
    func isCallActive() -> Bool {
        guard let calls = callObserver?.calls else { return false }
        for call in calls {
            if call.hasConnected && !call.hasEnded {
                return true // Call is active
            }
        }
        return false // No active call
    }
    
    func getNewUnconnectedCall() -> CXCall? {
        guard let calls = callObserver?.calls else { return nil }
        for call in calls {
            if !call.hasConnected && !call.hasEnded {
                return call // Call is active
            }
        }
        return nil // No unconnected call
    }
}
