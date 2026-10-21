//
//  UserOnboardingCoordinator.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 `UserOnboardingCoordinator` is used specifically for user onboarding flow.
 It helps setting up the desired onboarding screen based on user interaction, application state and various checks.
 
 Presentation of sheet views, popups and progress indicator is still managed by `GlacierAppRootCoordinator`.
 */
final class UserOnboardingCoordinator: GlacierCoordinator, ObservableObject {
    
    typealias Screen = OnboardingScreen
    
    // MARK: - Public properties
    
    @Published var path: NavigationPath = NavigationPath()
    
    @Published private(set) var currentScreen: Screen?
    @Published private(set) var presentedScreen: Screen?

    /// The coordinator of the onboarding flow on screen, if any. Lets onboarding exits that only
    /// hold the root coordinator, like the phone-number picker sheet, end on the survey screen.
    private(set) static weak var active: UserOnboardingCoordinator?
    
    // MARK: - Private properties
    
    private var rootCoordinator: any GlacierRootCoordinator
    /// The flag the survey screen sets when it finishes onboarding. See `finishOnboarding(marking:)`.
    private var discoverySurveyCompletionFlag: KeyPath<UserDefaultsService.LocalStorageKeys, String> = \.isUserOnboardingCompleted
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        Self.active = self
        // A new onboarding flow may be a different account, so start from a fresh survey status
        // and fetch it while the user works through the earlier screens.
        DiscoverySurveyService.shared.reset()
        DiscoverySurveyService.shared.prefetchStatus()
        setCurrentScreen()
    }

    /// Starts on `screen` rather than restoring saved progress, which reads the account database.
    /// For unit tests: the database crashes on purpose when the keychain isn't available.
    init(rootCoordinator: any GlacierRootCoordinator, startingAt screen: Screen) {
        self.rootCoordinator = rootCoordinator
        Self.active = self
        DiscoverySurveyService.shared.reset()
        setScreen(screen)
    }
    
    // MARK: - Public methods
    
    func setScreen(_ screen: Screen) {
        self.currentScreen = screen
        // Retries a status fetch that failed earlier, e.g. on a bad connection.
        DiscoverySurveyService.shared.prefetchStatus()
    }

    /// Ends onboarding on the survey screen. Its Submit and Skip set `completionFlag` and go to the
    /// main screen.
    func showDiscoverySurvey(completionFlag: KeyPath<UserDefaultsService.LocalStorageKeys, String>) {
        discoverySurveyCompletionFlag = completionFlag
        setScreen(.discoverySurvey)
    }
    
    func presentScreen(_ screen: Screen) {
        self.presentedScreen = screen
        path.append(screen)
    }
    
    func dismissPresentedScreen() {
        path.removeLast()
    }
    
    @ViewBuilder
    func build(_ screen: OnboardingScreen) -> some View {
        switch screen {
        case .userOnboardingHome:
            UserOnboardingHomeScreen()
        case .dnsSetup:
            let viewModel = DNSSetupVM(rootCoordinator: rootCoordinator, userOnboardingCoordinator: self)
            DNSSetupScreen(viewModel: viewModel)
        case .vpnSetup:
            let viewModel = VPNSetupVM(rootCoordinator: rootCoordinator, userOnboardingCoordinator: self)
            VPNSetupScreen(viewModel: viewModel)
        case .trustedNetworksSetup:
            let viewModel = TrustedNetworksSetupVM(rootCoordinator: rootCoordinator, userOnboardingCoordinator: self)
            TrustedNetworksSetupScreen(viewModel: viewModel)
        case .phoneNumberPlanPurchaseHome:
            let viewModel = PhoneNumberPlanPurchaseHomeVM(rootCoordinator: rootCoordinator, userOnboardingCoordinator: self)
            PhoneNumberPlanPurchaseHomeScreen(viewModel: viewModel)
        case .userPermissions:
            let viewModel = UserPermissionsVM(rootCoordinator: rootCoordinator, userOnboardingCoordinator: self)
            UserPermissionsScreen(viewModel: viewModel)
        case .phoneNumberSelectionHome:
            let viewModel = PhoneNumberSelectionHomeVM(rootCoordinator: rootCoordinator)
            PhoneNumberSelectionHomeScreen(viewModel: viewModel)
        case .discoverySurvey:
            let viewModel = DiscoverySurveyVM(rootCoordinator: rootCoordinator, completionFlag: discoverySurveyCompletionFlag)
            DiscoverySurveyScreen(viewModel: viewModel)
        }
    }
    
    // MARK: - Private methods
    
    private func setCurrentScreen() {
        let account = GlacierAccountModel.getGlacierAccount()
        let isBaseSubscribed = account?.hasActiveSubscription == true
        let isPhoneSubscribed = account?.hasActivePhoneNumberSubscription == true

        // Paywall enforcement: if no base subscription, always start at the paywall
        // regardless of any previously-saved in-progress screen.  Without this guard,
        // a saved "dnsSetup" (or any post-paywall screen) would be restored unconditionally,
        // bypassing the paywall entirely.
        guard isBaseSubscribed else {
            setScreen(.userOnboardingHome)
            return
        }

        guard let inProgressOnboardingScreenName: String = UserDefaultsService.shared.get(for: \.inProgressUserOnboardingScreen) else {
            // No in-progress screen: skip the Glacier plan paywall if already subscribed.
            setScreen(isBaseSubscribed ? .dnsSetup : .userOnboardingHome)
            return
        }

        if let onboardingScreen = OnboardingScreen(rawValue: inProgressOnboardingScreenName) {
            // If the user was last at the welcome screen but is now subscribed, skip the paywall.
            if onboardingScreen == .userOnboardingHome && isBaseSubscribed {
                setScreen(.dnsSetup)
            // If the user was last at the phone plan purchase screen but is now subscribed, skip it.
            } else if onboardingScreen == .phoneNumberPlanPurchaseHome && isPhoneSubscribed {
                setScreen(.phoneNumberSelectionHome)
            } else {
                setScreen(onboardingScreen)
            }
        } else {
            switch inProgressOnboardingScreenName {
            case Sheet.glacierPlanPurchase.name:
                // Was mid-purchase; skip paywall if now confirmed subscribed.
                setScreen(isBaseSubscribed ? .dnsSetup : .userOnboardingHome)
            case Sheet.phoneNumberPlanPurchase.name:
                setScreen(isPhoneSubscribed ? .phoneNumberSelectionHome : .phoneNumberPlanPurchaseHome)
            case Sheet.phoneNumberSelection(false).name:
                setScreen(.phoneNumberSelectionHome)
            default: break
            }
        }
    }
}
