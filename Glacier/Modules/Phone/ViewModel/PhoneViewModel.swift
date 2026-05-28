//
//  PhoneViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 24/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 PhoneViewModel defines requirements for phone screen view models.
 */
protocol PhoneViewModel: GlacierViewModelWithRootCoordinator {
    var hasPhoneNumberSubscription: Bool { get }
    var phoneNumbers: [PhoneAccountModel] { get }
    
    init(rootCoordinator: any GlacierRootCoordinator)
    
    func initialize()
    func presentPhoneNumberPlanPurchaseView()
    func presentPhoneNumberSelectionView()
}

/**
 PhoneVM defines data/state and business logic for phoen screen
 */
final class PhoneVM: PhoneViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var hasPhoneNumberSubscription: Bool = false
    @Published var phoneNumbers: [PhoneAccountModel] = []
    
    let rootCoordinator: any GlacierRootCoordinator
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        
        registerForNotifications()
        checkPhoneNumberPlanSubscription()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public methods
    
    func initialize() {
        if hasPhoneNumberSubscription && phoneNumbers.isEmpty {
            TwilioBackendManager.sharedMgr().queryForNumbers()
        }
    }
    
    func presentPhoneNumberPlanPurchaseView() {
        presentSheet(.phoneNumberPlanPurchase)
    }
    
    func presentPhoneNumberSelectionView() {
        presentSheet(.phoneNumberSelection(true))
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
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onUserPhoneNumberDetailsUpdated),
            name: .userPhoneNumberDetailsUpdated,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPhoneSubscriptionStateDidChange),
            name: .phoneSubscriptionStateDidChange,
            object: nil
        )
    }
    
    private func checkPhoneNumberPlanSubscription() {
        guard let userAccountModel = GlacierAccountModel.getGlacierAccount() else {
            hasPhoneNumberSubscription = false
            return
        }
        hasPhoneNumberSubscription = userAccountModel.hasActivePhoneNumberSubscription
        phoneNumbers = hasPhoneNumberSubscription ? PhoneAccountModel.allAccountsSortedByDisplayName() : []
    }
    
    @MainActor
    @objc private func onPhoneNumberPlanPurchaseSuccessful() {
        hasPhoneNumberSubscription = true
        dismissSheet()
        TwilioBackendManager.sharedMgr().queryForNumbers()
    }
    
    /// Re-syncs phone subscription UI state after `applyBackendSubscription` writes the
    /// reconciled value. Handles both the launch race (PhoneVM may initialize before
    /// resolveSubscriptionStatus completes) and foreground-refresh transitions.
    @MainActor
    @objc private func onPhoneSubscriptionStateDidChange() {
        guard let userAccountModel = GlacierAccountModel.getGlacierAccount() else {
            hasPhoneNumberSubscription = false
            return
        }
        let hasSubscription = userAccountModel.hasActivePhoneNumberSubscription
        guard hasSubscription != hasPhoneNumberSubscription else { return }
        hasPhoneNumberSubscription = hasSubscription
        if hasSubscription && phoneNumbers.isEmpty {
            TwilioBackendManager.sharedMgr().queryForNumbers()
        }
    }
    
    @MainActor
    @objc private func onNewPhoneNumberAdded() {
        phoneNumbers.removeAll()
        phoneNumbers = PhoneAccountModel.allAccountsSortedByDisplayName()
    }
    
    @MainActor
    @objc private func onUserPhoneNumberDetailsUpdated() {
        phoneNumbers.removeAll()
        phoneNumbers = PhoneAccountModel.allAccountsSortedByDisplayName()
    }
}
