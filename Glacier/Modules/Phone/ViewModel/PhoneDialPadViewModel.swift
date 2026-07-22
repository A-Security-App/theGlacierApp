//
//  PhoneDialPadViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 25/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Combine
import Foundation
import UIKit

/**
 PhoneDialPadViewModel defines view model requirements for PhoneDialPadView.
 */
protocol PhoneDialPadViewModel: GlacierViewModelWithRootCoordinator {
    var phoneNumber: String { get set }
    
    init(rootCoordinator: any GlacierRootCoordinator)
    
    func appendDigit(_ digit: String)
    func addPlusSign()
    func deleteDigit()
    func startAutoDeleteOfDigits()
    func stopAutoDeleteOfDigits()
    func formatNumber(with mask: String, number: String)
    
    func startCall()
}

/**
 PhoneDialPadVM defines data/state and business logic for PhoneDialPadView.
 */
final class PhoneDialPadVM: PhoneDialPadViewModel, ObservableObject, PhoneNumberMenuCoordinator {
    
    // MARK: - Public Properties
    
    @Published var phoneNumber: String = ""
    
    let id: String = UUID().uuidString
    let rootCoordinator: any GlacierRootCoordinator
    
    // MARK: - Private properties
    
    private var timer: Timer? = nil
    private let numberFormatForUSA: String = "(XXX) XXX-XXXX"
    private let allowedCharacters: String = "[^0-9+*#]"
    private let allowedDigits: String = "[^0-9]"
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        registerForNotifications()
    }
    
    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public methods
    
    func appendDigit(_ digit: String) {
        hidePhoneNumberMenu()
        
        if phoneNumber.count < 16 {
            phoneNumber.append(digit)
            formatNumber(with: numberFormatForUSA, number: phoneNumber)
            giveHapticFeedback(style: .light)
        }
    }

    func addPlusSign() {
        if phoneNumber.isEmpty {
            phoneNumber = "+"
            giveHapticFeedback(style: .medium)
        }
    }

    func deleteDigit() {
        hidePhoneNumberMenu()
        
        guard !phoneNumber.isEmpty else { return }
        phoneNumber.removeLast()
        let raw = phoneNumber.replacingOccurrences(of: allowedCharacters, with: "", options: .regularExpression)
        formatNumber(with: numberFormatForUSA, number: raw)
        giveHapticFeedback(style: .light)
    }
    
    func startAutoDeleteOfDigits() {
        stopAutoDeleteOfDigits()
        deleteDigit()
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            
            if strongSelf.phoneNumber.isEmpty {
                strongSelf.stopAutoDeleteOfDigits()
            } else {
                strongSelf.deleteDigit()
            }
        }
    }
    
    func stopAutoDeleteOfDigits() {
        timer?.invalidate()
        timer = nil
    }
    
    func formatNumber(with mask: String, number: String) {
        let raw = number.replacingOccurrences(of: allowedCharacters, with: "", options: .regularExpression)
        if raw.starts(with: "+") {
            // International numbers (e.g. pasted from iOS Recents) shouldn't get
            // the US mask applied — keep the value as-is instead of dropping it.
            phoneNumber = raw
            return
        }
        
        let numbers = raw.replacingOccurrences(of: allowedDigits, with: "", options: .regularExpression)
        var result = ""
        var index = numbers.startIndex
        for ch in mask where index < numbers.endIndex {
            if ch == "X" {
                result.append(numbers[index])
                index = numbers.index(after: index)
            } else {
                result.append(ch)
            }
        }
        
        phoneNumber = result.isEmpty ? raw : result
    }
    
    // MARK: - Private methods
    
    private func registerForNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPhoneCallEnded),
            name: .phoneCallEnded,
            object: nil
        )
    }
    
    private func giveHapticFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
    
    @objc private func onPhoneCallEnded() {
        phoneNumber = ""
    }
}

// MARK: - Start and End call flows

extension PhoneDialPadVM {
    
    func startCall() {
        guard !SecurityCenter.isProxyDetected else { return }
        hidePhoneNumberMenu()
        giveHapticFeedback(style: .light)

        // If no number is entered, recall the most recent outgoing call (mimics iOS Phone behavior)
        if phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let recentOutgoing = CallRecord.allMessages().first(where: { !$0.isIncoming }),
                  !recentOutgoing.phoneNumber.isEmpty else { return }
            formatNumber(with: numberFormatForUSA, number: recentOutgoing.phoneNumber)
            return
        }
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
                                GlacierNotificationProperties.phoneNumber: self.phoneNumber,
                                GlacierNotificationProperties.personName: ""
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
}

// MARK: - Conformence to Identifiable and Hashable protocols

extension PhoneDialPadVM: Identifiable, Hashable {
    static func == (lhs: PhoneDialPadVM, rhs: PhoneDialPadVM) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
