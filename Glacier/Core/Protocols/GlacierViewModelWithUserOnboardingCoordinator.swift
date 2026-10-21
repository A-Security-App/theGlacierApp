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
            finishOnboarding()
        }
    }
}

extension GlacierViewModelWithRootCoordinator {

    /// Every way out of onboarding ends here. Turns on DNS if it was set up during onboarding,
    /// then shows the "How did you first hear about Glacier?" screen when this account still has
    /// to answer it, or goes straight to the main screen.
    ///
    /// - Parameter flag: The onboarding flag to set once the user reaches the main screen. Skip
    ///   paths pass their own flag rather than `isUserOnboardingCompleted`.
    func finishOnboarding(marking flag: KeyPath<UserDefaultsService.LocalStorageKeys, String> = \.isUserOnboardingCompleted) {
        connectDNSIfSetUpDuringOnboarding()
        // Only while onboarding is on screen: the phone-number picker also finishes onboarding
        // when a user who skipped it earlier picks a number from the main app.
        if DiscoverySurveyService.shared.shouldAsk,
           (rootCoordinator as? GlacierAppRootCoordinator)?.currentScreen == .userOnboarding,
           let onboardingCoordinator = UserOnboardingCoordinator.active {
            onboardingCoordinator.showDiscoverySurvey(completionFlag: flag)
        } else {
            completeOnboarding(marking: flag)
        }
    }

    /// Marks onboarding as finished and goes to the main screen.
    func completeOnboarding(marking flag: KeyPath<UserDefaultsService.LocalStorageKeys, String> = \.isUserOnboardingCompleted) {
        UserDefaultsService.shared.set(true, for: flag)
        setRootScreen(.main)
    }
}
