//
//  PhoneNumberMenuViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 26/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import UIKit
import Foundation

/**
 PhoneNumberMenuViewModelDelegate takes on the responsibility to route to these screens when user taps on
 phone menu view buttons for navigation,
 - phone number selection view
 - phone number plan purchase view
 - manage phone numbers view
 */
protocol PhoneNumberMenuViewModelDelegate {
    func presentPhoneNumberSelectionLimitationPrompt()
    func presentPhoneNumberSelectionView()
    func presentPhoneNumberPlanPurchaseView()
    func presentManagePhoneNumbersView()
    func setActivePhoneNumber(_ phoneNumber: PhoneAccountModel)
}

/**
 PhoneNumberMenuViewModel defines requirements for PhoneNumberMenuView view models.
 */
protocol PhoneNumberMenuViewModel {
    var phoneNumbers: [PhoneAccountModel] { get }
    var activePhoneNumber: String? { get }
    var activePhoneNumberPlan: GlacierPhoneNumberSubscriptionPlan? { get }
    var canUpgradeToHigherPhoneNumberPlan: Bool { get }
    
    init(delegate: PhoneNumberMenuViewModelDelegate?)
    
    func initialize()
    func getUserPhoneNumbers()
    func setActivePhoneNumber(_ phoneNumber: PhoneAccountModel)
    func presentPhoneNumberSelectionView()
    func presentPhoneNumberPlanPurchaseView()
    func presentManagePhoneNumbersView()
}

/**
 PhoneNumberMenuVM defines data/state and business logic for PhoneNumberMenuView.
 */
final class PhoneNumberMenuVM: PhoneNumberMenuViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var phoneNumbers: [PhoneAccountModel] = []
    @Published var activePhoneNumber: String?
    @Published var activePhoneNumberPlan: GlacierPhoneNumberSubscriptionPlan? {
        didSet {
            guard let activePlan = activePhoneNumberPlan else {
                canUpgradeToHigherPhoneNumberPlan = false
                return
            }
            canUpgradeToHigherPhoneNumberPlan = activePlan != .fiveNumbers
        }
    }
    
    @Published var canUpgradeToHigherPhoneNumberPlan: Bool = false
    
    // MARK: - Private properties
    
    private var delegate: PhoneNumberMenuViewModelDelegate?
    
    // MARK: - Initializer
    
    init(delegate: PhoneNumberMenuViewModelDelegate?) {
        self.delegate = delegate
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public methods
    
    func initialize() {
        registerForNotifications()
        
        activePhoneNumberPlan = GlacierPhoneNumberSubscriptionPlan.activePlan
        getUserPhoneNumbers()
    }
    
    func getUserPhoneNumbers() {
        phoneNumbers.removeAll()
        phoneNumbers = PhoneAccountModel.allAccountsSortedByDisplayName()
        
        if let activeNumber: String = UserDefaultsService.shared.get(for: \.activePhoneNumber) {
            activePhoneNumber = activeNumber
        } else {
            guard let firstNumber = phoneNumbers.first else { return }
            activePhoneNumber = firstNumber.grdbRecord?.phoneNumber
            setActivePhoneNumber(firstNumber)
        }
    }
    
    func setActivePhoneNumber(_ phoneNumber: PhoneAccountModel) {
        
        // Let's set selected phone number as TwilioBackendManager selectedAccount
        TwilioBackendManager.sharedMgr().selectedAccount = phoneNumber
        
        // Let's save selected phone number reference as active phone number for UI/UX updates
        guard let number = phoneNumber.grdbRecord?.phoneNumber else { return }
        activePhoneNumber = number
        UserDefaultsService.shared.set(number, for: \.activePhoneNumber)
        
        delegate?.setActivePhoneNumber(phoneNumber)
    }
    
    func presentPhoneNumberSelectionView() {
        delegate?.presentPhoneNumberSelectionView()
    }
    
    func presentPhoneNumberPlanPurchaseView() {
        delegate?.presentPhoneNumberPlanPurchaseView()
    }
    
    func presentManagePhoneNumbersView() {
        delegate?.presentManagePhoneNumbersView()
    }
    
    // MARK: - Private methods
    
    private func registerForNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPhoneNumberPlanPurchaseSuccessful),
            name: .phoneNumberPlanPurchaseSuccessful,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onNewPhoneNumberAdded),
            name: .newPhoneNumberAdded,
            object: nil
        )
    }
    
    @MainActor
    @objc private func onPhoneNumberPlanPurchaseSuccessful() {
        DispatchQueue.main.async {
            self.activePhoneNumberPlan = GlacierPhoneNumberSubscriptionPlan.activePlan
            self.getUserPhoneNumbers()
        }
    }
    
    @MainActor
    @objc private func onNewPhoneNumberAdded() {
        DispatchQueue.main.async {
            self.getUserPhoneNumbers()
        }
    }
}
