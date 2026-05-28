//
//  GlacierViewModelWithUserOnboardingCoordinator.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 11/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 GlacierViewModelWithUserOnboardingCoordinator defines common requirements for view models that need to have user onboarding coordinator for presentation of onboarding screens.
 */
protocol GlacierViewModelWithUserOnboardingCoordinator: AnyObject {
    /**
     It's a reference to the user onboarding coordinator that manages presentation of user onboarding screens.
     */
    var userOnboardingCoordinator: any GlacierCoordinator { get }
    
    /**
     Presents given user onboarding screen
     */
    func setOnboardingScreen(_ screen: OnboardingScreen)
}

extension GlacierViewModelWithUserOnboardingCoordinator {

    func setOnboardingScreen(_ screen: OnboardingScreen) {
        guard let onboardingCoordinator = userOnboardingCoordinator as? UserOnboardingCoordinator else {
            return
        }
        onboardingCoordinator.setScreen(screen)
    }
}

extension GlacierViewModelWithUserOnboardingCoordinator where Self: GlacierViewModelWithRootCoordinator {

    /// Routes to the correct phone-number onboarding step based on the user's current state:
    /// - No phone subscription → phone plan purchase screen
    /// - Phone subscription, no numbers yet → phone number selection screen
    /// - Phone subscription + existing numbers → complete onboarding and go to main
    ///
    /// All skip paths (DNS, VPN, trusted networks) funnel through here so the same
    /// subscription-aware logic applies regardless of where the user is in the flow.
    func navigateToPhoneNumberOnboarding() {
        let account = GlacierAccountModel.getGlacierAccount()
        guard account?.hasActivePhoneNumberSubscription == true else {
            setOnboardingScreen(.phoneNumberPlanPurchaseHome)
            return
        }
        let existingNumbers = TwilioBackendManager.sharedMgr().getExistingAccounts()
        if existingNumbers.isEmpty {
            setOnboardingScreen(.phoneNumberSelectionHome)
        } else {
            UserDefaultsService.shared.set(true, for: \.isUserOnboardingCompleted)
            connectDNSIfSetUpDuringOnboarding()
            setRootScreen(.main)
        }
    }
}
