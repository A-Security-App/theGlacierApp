//
//  PhoneNumberPlanPurchaseViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 08/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI
import StoreKit

/**
 PhoneNumberPlanPurchaseVM provides data/state and business logic for GlacierPlanPurchaseScreen.
 - It loads list of phone number plans
 - It connects to StoreKit to purchase user selected plan
 - It connects to StoreKit for restoring user purchases.
 */
final class PhoneNumberPlanPurchaseVM: GlacierPlanPurchaseViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    let rootCoordinator: any GlacierRootCoordinator
    @Published private(set) var availablePlans: [Product] = []
    @Published var selectedPlan: Product? {
        didSet {
            isPurchaseButtonEnabled = selectedPlan != nil
        }
    }
    @Published var isPurchaseButtonEnabled: Bool = false
    
    // MARK: - Private properties
    
    private let service: GlacierPlanPurchaseService
    /// Set to `true` immediately before a purchase or restore is initiated so that
    /// `onPhoneNumberPlanPurchaseVerificationFailed` can distinguish an actual failed
    /// purchase attempt from a passive entitlement check (where no active subscription
    /// is the expected result and should not surface an error popup).
    private var isExpectingVerification = false

    // MARK: - Initializer
    
    init(rootCoodinator: any GlacierRootCoordinator, service: GlacierPlanPurchaseService) {
        self.rootCoordinator = rootCoodinator
        self.service = service
        
        registerForNotifications()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public methods
    
    @MainActor
    func loadAvailablePlans() {
        Task {
            do {
                presentProgressIndicator()
                
                availablePlans = try await service.loadAvailablePlans()
        
                if let activePlan = GlacierPhoneNumberSubscriptionPlan.activePlan {
                    selectedPlan = availablePlans.first(where: { $0.id == activePlan.rawValue })
                } else {
                    selectedPlan = availablePlans.first
                }
                
                self.dismissProgressIndicator()
            } catch {
                self.dismissProgressIndicator()
                self.presentErrorAlert()
            }
        }
    }

    func purchasePlan() {
        Task { @MainActor in
            do {
                guard let plan = selectedPlan else { return }
                isExpectingVerification = true
                try await service.purchasePlan(plan)
            } catch GlacierPlanPurchaseError.userCancelled {
                // User dismissed the payment sheet intentionally — no error popup.
                isExpectingVerification = false
            } catch {
                isExpectingVerification = false
                presentErrorAlert()
            }
        }
    }

    func restorePurchase() {
        Task { @MainActor in
            do {
                isExpectingVerification = true
                try await service.restorePurchase()
            } catch GlacierPlanPurchaseError.userCancelled {
                // User dismissed the payment sheet intentionally — no error popup.
                isExpectingVerification = false
            } catch {
                isExpectingVerification = false
                presentErrorAlert()
            }
        }
    }
    
    // MARK: - Private methods
    
    private func registerForNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPhoneNumberPlanPurchaseVerified(_:)),
            name: .phoneNumberPlanPurchaseVerified,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPhoneNumberPlanPurchaseVerificationFailed),
            name: .phoneNumberPlanPurchaseVerificationFailed,
            object: nil
        )
    }
    
    @MainActor
    @objc private func onPhoneNumberPlanPurchaseVerified(_ notification: Notification) {
        isExpectingVerification = false
        guard let userInfo = notification.userInfo,
              let planId = userInfo[GlacierNotificationProperties.activePhoneNumberPlanId] as? String else {
            self.presentErrorAlert()
            return
        }
        
        // Let's save active phone number plan id for future references
        UserDefaultsService.shared.set(planId, for: \.activePhoneNumberSubscriptionPlanId)
        
        // Let's update subscription status for user account
        if let account = GlacierAccountModel.getGlacierAccount() {
            account.hasActivePhoneNumberSubscription = true
        }
        
        /**
         Let's try to fetch user's previously purchased phone numbers, if any.
         
         MainViewModel will get .userPhoneNumberDetailsUpdated notification when the numbers are loaded so that it main screen could
         update the UI/UX
         */
        TwilioBackendManager.sharedMgr().queryForNumbers()
        
        /**
         Let's notify the presenting screen (`PhoneNumberPlanPurchaseHomeScreen` or `ManagePhoneNumbersScreen`) so that it dismisses the phone number plan
         purchase sheet view, refreshes UI/UX and/or takes user to the next screen.
         */
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NotificationCenter.default.post(
                name: .phoneNumberPlanPurchaseSuccessful,
                object: nil,
                userInfo: nil
            )
        }
    }
    
    @MainActor
    @objc private func onPhoneNumberPlanPurchaseVerificationFailed() {
        guard isExpectingVerification else { return }
        isExpectingVerification = false
        presentErrorAlert()
    }
    
    private func presentErrorAlert() {
        presentAlertWith(
            title: NSLocalizedString("Your purchase could not be completed", comment: "Phone number plan purchase error title"),
            description: NSLocalizedString("Please try again.", comment: "Phone number plan purchase error description")
        )
    }
}
