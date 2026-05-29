//
//  SettingsViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 04/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 SettingsViewModel defines requirements for setting screen view models.
 */
protocol SettingsViewModel: GlacierViewModelWithRootCoordinator {
    var userEmail: String? { get }
    var isDarkModeEnabled: Bool { get set }
    var isRebootReminderEnabled: Bool { get set }
    var shouldShowVPNSettingsOption: Bool { get }
    var shouldShowResetPasswordOption: Bool { get }
    
    func presentVPNSettingsScreen()
    func presentAppearanceSettingsScreen()
    func presentWidgetSettingsScreen()
    func presentResetPasswordScreen()
    func dismissResetPasswordScreen()
    
    @MainActor
    func signOut()
}

/**
 SettingsVM provides data/states and business logic for settings screen.
 */
final class SettingsVM: SettingsViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var userEmail: String?
    @Published var isDarkModeEnabled: Bool = false
    @Published var shouldShowVPNSettingsOption: Bool = false
    @Published var shouldShowResetPasswordOption: Bool = false

    /// Backs the Reboot Reminder toggle. Persisted and reflected to the scheduled
    /// notification. The initial value is set in `init` (which does not trigger
    /// `didSet`), so toggling in the UI is the only path that re-schedules.
    @Published var isRebootReminderEnabled: Bool = true {
        didSet {
            UserDefaultsService.shared.set(isRebootReminderEnabled, for: \.isRebootReminderEnabled)
            if isRebootReminderEnabled {
                GlacierApplicationDelegate.appDelegate.scheduleWeeklyRebootReminder()
            } else {
                GlacierApplicationDelegate.appDelegate.cancelWeeklyRebootReminder()
            }
        }
    }

    // MARK: - Private properties

    var rootCoordinator: any GlacierRootCoordinator

    // MARK: - Initializer

    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        self.isRebootReminderEnabled = UserDefaultsService.shared.get(for: \.isRebootReminderEnabled) ?? true
        getUserDetails()
    }
    
    // MARK: - Public methods
    
    func presentVPNSettingsScreen() {
        presentScreen(.vpnSettings)
    }
    
    func presentAppearanceSettingsScreen() {
        presentSheet(.appearanceSettings)
    }

    func presentWidgetSettingsScreen() {
        presentSheet(.widgetSettings)
    }

    func presentResetPasswordScreen() {
        presentSheet(.passwordReset)
    }
    
    func dismissResetPasswordScreen() {
        dismissSheet()
    }
    
    @MainActor
    func signOut() {
        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("Are you sure?", comment: "Setting screen signout confirmation title"),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                    onTap: {
                        self.dismissPopup()
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Yes, Sign Out", comment: "Yes sign out button title"),
                    titleColor: .ember,
                    onTap: {
                        Task { @MainActor in
                            do {
                                self.dismissPopup()

                                // Let's sign user out from the Auth system.
                                // We always proceed with local cleanup regardless of the sign-out result,
                                // since the user has explicitly confirmed they want to sign out.
                                // For Hosted UI (Apple/Google) users, Amplify opens an ASWebAuthenticationSession
                                // for the Cognito sign-out; if that is cancelled or fails, we still clean up
                                // local state so the user always lands on the login screen.
                                self.teardownVPNIfNeeded()

                                let service = AmplifyAuthenticationService()
                                _ = await service.signOut()

                                // Let's reset user authentication related user defaults settings
                                UserDefaultsService.shared.remove(for: \.userEmail)
                                UserDefaultsService.shared.remove(for: \.isUserLoggedIn)
                                UserDefaultsService.shared.remove(for: \.hostedUIProvider)
                                UserDefaultsService.shared.remove(for: \.isUserAccountCreated)
                                UserDefaultsService.shared.remove(for: \.isUserAccountConfirmed)

                                // Let's reset gradient avatars for the phone numbers so that they
                                // could be assigned afresh on next login
                                UserDefaultsService.shared.remove(for: \.phoneNumberGradientAvatarDictionary)

                                // Let's remove user added phone numbers from local storage
                                UserDefaultsService.shared.remove(for: \.activePhoneNumber)

                                // Reset onboarding state so the next account goes through onboarding
                                // fresh. These keys are not per-user, so without clearing them the
                                // next account would inherit the previous account's onboarding and
                                // subscription state (including the TestFlight bypass flags).
                                UserDefaultsService.shared.remove(for: \.isUserOnboardingCompleted)
                                UserDefaultsService.shared.remove(for: \.inProgressUserOnboardingScreen)
                                UserDefaultsService.shared.remove(for: \.didSkipPhoneNumberPurchaseDuringOnboarding)
                                UserDefaultsService.shared.remove(for: \.didSkipPhoneNumberSelectionDuringOnboarding)
                                UserDefaultsService.shared.remove(for: \.activeGlacierSubscriptionPlanId)
                                UserDefaultsService.shared.remove(for: \.activePhoneNumberSubscriptionPlanId)
                                UserDefaultsService.shared.remove(for: \.hasEverSubscribedToGlacierPlan)
                                UserDefaultsService.shared.remove(for: \.hasEverSubscribedToPhoneNumberPlan)
                                
                                UserDefaultsService.shared.remove(for: \.cachedDeviceToken)
                                UserDefaultsService.shared.remove(for: \.cachedBindingDate)
                                
                                CallManager.sharedCallManager().unregisterWithTwilio()

                                // Navigate immediately — don't block on DB cleanup.
                                // DB removal runs fire-and-forget in the background so that
                                // navigation always happens even when the phone-number list is empty.
                                self.setRootScreen(.userAuthentication)
                                self.dismissPresentedScreen()
                                self.removeUserAddedPhoneNumbersFromDB()
                            }
                        }
                    }
                )
            ],
            buttonsAlignment: .horizontal
        )
        presentPopup(with: popupConfiguration)
    }
    
    // MARK: - Private methods
    
    private func getUserDetails() {
        guard let userAccount = GlacierAccountModel.getGlacierAccount() else {
            shouldShowVPNSettingsOption = false
            return
        }
        
        userEmail = userAccount.username
        shouldShowVPNSettingsOption = userAccount.hasActiveSubscription
        shouldShowResetPasswordOption = UserDefaultsService.shared.get(for: \.hostedUIProvider) as String? == nil
    }
    
    private func teardownVPNIfNeeded() {
        guard let tunnelMgr = WireGuardManager.shared().tunnelsManager,
              let tunnel = tunnelMgr.tunnelInOperation() else { return }
        tunnelMgr.setOnDemandEnabled(false, on: tunnel) { _ in
            tunnelMgr.startDeactivation(of: tunnel)
        }
    }

    private func removeUserAddedPhoneNumbersFromDB() {
        let internalQueue = DispatchQueue(label: "settings-module-queue", qos: .userInitiated)
        internalQueue.async {
            PhoneAccount.allSMSAccounts().forEach { $0.remove {} }
        }
    }
}
