//
//  PhoneCallViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 02/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 PhoneCallViewModel defines requirements for PhoneCallScreen view models.
 */
protocol PhoneCallViewModel: GlacierViewModelWithRootCoordinator {
    var phoneContact: PhoneContact? { get }
    var callStatus: PhoneCallStatus? { get }
    var callDurationLabel: String? { get }
    var activeAudioRoute: PhoneCallAudioRoute { get }
    var isBluetoothAvailable: Bool { get }
    var isMuted: Bool { get }
    var muteButtonTintColor: Color { get }
    var muteButtonBGColor: Color { get }

    init(rootCoordinator: any GlacierRootCoordinator)

    func setPhoneContact(_ phoneContact: PhoneContact)
    func setIsIncomingCall(_ isIncoming: Bool)
    func startCall()
    func toggleMuteAudio()
    func selectAudioRoute(_ route: PhoneCallAudioRoute)
    func endCall()
}

/**
 PhoneCallVM takes care of data/state and business logic flows for Twilio calls.
 It provides data/state and easy to use APIs to PhoneCallScreen for Twilio call related actions.
 */
final class PhoneCallVM: PhoneCallViewModel, ObservableObject, PhoneNumberMenuCoordinator, GlacierCallDelegateProtocol {
    
    // MARK: - Public properties
    
    @Published var phoneContact: PhoneContact?
    @Published var callStatus: PhoneCallStatus?
    @Published var callDurationLabel: String?
    @Published var activeAudioRoute: PhoneCallAudioRoute = .microphone
    @Published var isBluetoothAvailable: Bool = false
    @Published var isMuted: Bool = false
    @Published var muteButtonTintColor: Color = .white
    @Published var muteButtonBGColor: Color = Color.grey90
    
    let rootCoordinator: any GlacierRootCoordinator

    // MARK: - Private properties

    private var isIncomingCall: Bool = false
    private var callTimer: Timer?
    private var callDurationSeconds: Int = 0

    // MARK: - Initializer

    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
    }
    
    // MARK: - Public methods
    
    func setPhoneContact(_ phoneContact: PhoneContact) {
        self.phoneContact = phoneContact
    }

    func setIsIncomingCall(_ isIncoming: Bool) {
        self.isIncomingCall = isIncoming
    }

    func startCall() {
        // If a call is already in progress (user returned to screen mid-call), do nothing.
        // This VM is already registered as the CallManager delegate; re-registering would
        // trigger setStatus("connected"), restarting and duplicating the call timer.
        if let status = callStatus, status != .ended {
            return
        }

        if isIncomingCall {
            // For an answered incoming call the Twilio call is already established.
            // Register as gcdelegate so we receive status updates; setGlacierCallDelegate
            // will immediately call setStatus("connected") if the call is already active.
            CallManager.sharedCallManager().setGlacierCallDelegate(self)
            callStatus = .connecting
            return
        }

        guard phoneContact != nil else { return }
        initializeCall()
    }
    
    func toggleMuteAudio() {
        guard let uuid = CallManager.sharedCallManager().currentUuid else { return }
        CallManager.sharedCallManager().performMuteAction(uuid: uuid, isMuted: !isMuted)
    }
    
    func selectAudioRoute(_ route: PhoneCallAudioRoute) {
        // performSpeakerAction(isSelected:) uses the Twilio tvoaudioDevice block,
        // which is required for audio session changes to take effect during an active call.
        // Speaker on → isSelected: true. Earpiece or Bluetooth → isSelected: false,
        // which clears the speaker override and lets the system route to earpiece or a
        // connected BT device automatically.
        switch route {
        case .speaker:
            CallManager.sharedCallManager().performSpeakerAction(isSelected: true)
        case .microphone, .bluetooth:
            CallManager.sharedCallManager().performSpeakerAction(isSelected: false)
        }
        DispatchQueue.main.async {
            self.activeAudioRoute = route
        }
    }
    
    func endCall() {
        let callManager = CallManager.sharedCallManager()
        if let uuid = callManager.currentUuid {
            callManager.performEndCallAction(uuid: uuid, userInitiated: true)
        } else {
            // currentUuid is nil — Twilio/CallKit already tore down the call (e.g. the
            // remote hung up and callDidDisconnect fired) but the UI was not dismissed.
            // Force any call CallKit still shows to end, then drive cleanup directly so
            // neither the screen nor the CallKit call is left stuck.
            callManager.forceEndCallKitCalls()
            disconnectCall(true)
        }
    }

    // MARK: - Private methods

    private func initializeCall() {
        guard let contact = phoneContact else { return }
        // Reset the duration before connecting so a stale value from a prior call
        // can't flash when this call transitions to the connected state.
        resetCallTimer()
        CallManager.sharedCallManager().setGlacierCallDelegate(self)
        CallManager.sharedCallManager().makeVoiceCall(contact)
        callStatus = .ringing
    }

    private func startCallTimer() {
        stopCallTimer()
        resetCallTimer()
        callTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.callDurationSeconds += 1
            let minutes = self.callDurationSeconds / 60
            let seconds = self.callDurationSeconds % 60
            self.callDurationLabel = String(format: "%02d:%02d", minutes, seconds)
        }
    }

    private func stopCallTimer() {
        callTimer?.invalidate()
        callTimer = nil
    }

    /// Zeroes the elapsed duration and its label so the timer always starts fresh at 00:00.
    private func resetCallTimer() {
        callDurationSeconds = 0
        callDurationLabel = "00:00"
    }

}

// MARK: - GlacierCallDelegateProtocol

extension PhoneCallVM {
    func holdCall(_ onHold: Bool) {}

    func muteAudio(_ shouldMute: Bool) {
        DispatchQueue.main.async {
            self.isMuted = shouldMute
            self.muteButtonBGColor = shouldMute ? .white : Color.grey90
            self.muteButtonTintColor = shouldMute ? .black : .white
        }
    }

    func disconnectCall(_ userInitiated: Bool) {
        CallManager.sharedCallManager().finalizeVoiceCall()
        DispatchQueue.main.async {
            self.stopCallTimer()
            self.resetCallTimer()
            self.callStatus = .ended
            
            // Let's notifiy dial pad screen about call ended event
            NotificationCenter.default.post(name: .phoneCallEnded, object: nil, userInfo: nil)
            
            self.hidePhoneNumberMenu()
            self.dismissPresentedScreen()
        }
    }

    func isConnected() -> Bool {
        callStatus == .connected
    }

    func setStatus(_ status: String) {
        if status == "connected" {
            DispatchQueue.main.async {
                self.callStatus = .connected
                self.startCallTimer()
            }
        }
    }

    func setBluetoothEnabled(_ bluetoothEnabled: Bool) {
        DispatchQueue.main.async {
            self.isBluetoothAvailable = bluetoothEnabled
            self.activeAudioRoute = bluetoothEnabled ? .bluetooth : .microphone
        }
    }

    func handleAudioDenied() {}
}

// MARK: - Conformence to Identifiable and Hashable protocols

extension PhoneCallVM: Identifiable, Hashable {
    static func == (lhs: PhoneCallVM, rhs: PhoneCallVM) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
