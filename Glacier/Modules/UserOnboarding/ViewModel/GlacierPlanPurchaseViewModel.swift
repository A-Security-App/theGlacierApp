//
//  GlacierPlanPurchaseViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 04/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI
import StoreKit

/**
 GlacierPlanPurchaseViewModel defines requirements for GlacierPlanPurchaseScreen view models.
 */
protocol GlacierPlanPurchaseViewModel: GlacierViewModelWithRootCoordinator, GlacierViewModel {

    var availablePlans: [Product] { get }
    var selectedPlan: Product? { get set }
    var isPurchaseButtonEnabled: Bool { get set }

    init(rootCoodinator: any GlacierRootCoordinator, service: GlacierPlanPurchaseService)

    @MainActor
    func loadAvailablePlans()

    func purchasePlan()
    func restorePurchase()
}

/**
 GlacierPlanPurchaseVM provides data/state and business logic for GlacierPlanPurchaseScreen.
 */
final class GlacierPlanPurchaseVM: GlacierPlanPurchaseViewModel, ObservableObject {

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
    /// `onGlacierPlanPurchaseVerificationFailed` can distinguish an actual failed
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

                if let activePlan = GlacierSubscriptionPlan.activePlan {
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
            selector: #selector(onGlacierPlanPurchaseVerified(_:)),
            name: .glacierPlanPurchaseVerified,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onGlacierPlanPurchaseVerificationFailed),
            name: .glacierPlanPurchaseVerificationFailed,
            object: nil
        )
    }

    @MainActor
    @objc private func onGlacierPlanPurchaseVerified(_ notification: Notification) {
        isExpectingVerification = false
        guard let userInfo = notification.userInfo,
              let planId = userInfo[GlacierNotificationProperties.activeGlacierPlanId] as? String else {
            self.presentErrorAlert()
            return
        }

        // Let's update subscription status for user account
        if let account = GlacierAccountModel.getGlacierAccount() {
            account.hasActiveSubscription = true
        }

        // Let's notify `UserOnboardingHomeScreen` so that it dismisses the glacier plan purchase sheet and takes user
        // to the DNS setup screen.
        NotificationCenter.default.post(
            name: .glacierPlanPurchaseSuccessful,
            object: nil,
            userInfo: nil
        )
    }

    @MainActor
    @objc private func onGlacierPlanPurchaseVerificationFailed() {
        // Only surface an error when the user explicitly initiated a purchase or restore.
        // Passive entitlement checks (e.g. refreshEntitlements() during app foreground or
        // login) also fire this notification when no subscription is active — in those cases
        // showing the popup is wrong because the user hasn't tried to do anything yet.
        guard isExpectingVerification else { return }
        isExpectingVerification = false
        presentErrorAlert()
    }

    private func presentErrorAlert() {
        presentAlertWith(
            title: NSLocalizedString("Your purchase could not be completed", comment: "Glacier plan purchase error title"),
            description: NSLocalizedString("Please try again.", comment: "Glacier plan purchase error description")
        )
    }
}
