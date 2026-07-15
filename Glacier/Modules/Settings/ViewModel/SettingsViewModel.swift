//
//  SettingsViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 04/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import StoreKit
import UIKit

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

    @MainActor
    func deleteAccount()
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

                            self.clearLocalUserStateAndNavigateToLogin()
                        }
                    }
                )
            ],
            buttonsAlignment: .horizontal
        )
        presentPopup(with: popupConfiguration)
    }

    @MainActor
    func deleteAccount() {
        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("Delete Account?", comment: "Settings screen delete account confirmation title"),
            description: NSLocalizedString(
                "This permanently deletes your Glacier account and associated data. This action cannot be undone.",
                comment: "Settings screen delete account confirmation description"
            ),
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
                    title: NSLocalizedString("Yes, Delete", comment: "Yes delete account button title"),
                    titleColor: .ember,
                    onTap: {
                        Task { @MainActor in
                            self.dismissPopup()

                            // Capture subscription state before we tear down local state,
                            // since the local account record is cleared during cleanup.
                            let hasActiveSubscription = GlacierAccountModel.getGlacierAccount()?.hasActiveSubscription ?? false

                            // Tear down the VPN before deleting so no tunnel keeps running
                            // for an account that no longer exists.
                            self.teardownVPNIfNeeded()

                            let service = AmplifyAuthenticationService()
                            do {
                                // Permanently delete the Cognito user. On success Amplify
                                // also signs the user out locally.
                                try await service.deleteUser()
                            } catch {
                                // The account still exists, so leave local state intact and
                                // let the user retry instead of stranding them on the login screen.
                                self.presentAccountDeletionFailurePopup()
                                return
                            }

                            // App Store subscriptions can't be cancelled programmatically, so
                            // if the user has an active subscription, offer to open Apple's
                            // manage sheet before navigating away. Otherwise finish immediately.
                            if hasActiveSubscription {
                                self.presentManageSubscriptionFollowUp()
                            } else {
                                self.clearLocalUserStateAndNavigateToLogin()
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

    /// Returns the active foreground window scene, used to anchor StoreKit sheets.
    @MainActor
    private func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Opens the App Store subscriptions page in the browser as a fallback when the
    /// native manage-subscriptions sheet is unavailable.
    @MainActor
    private func openManageSubscriptionsFallbackURL() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }

    /// Shown after a successful account deletion when the user still has an active
    /// subscription. App Store subscriptions can't be cancelled programmatically,
    /// so we offer to open Apple's native manage-subscriptions sheet. Either choice
    /// finishes local cleanup and routes the user back to the login screen.
    @MainActor
    private func presentManageSubscriptionFollowUp() {
        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("Manage Your Subscription", comment: "Manage subscription follow-up title"),
            description: NSLocalizedString(
                "Your account has been deleted, but your subscription is managed through Apple and remains active.",
                comment: "Manage subscription follow-up description"
            ),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Not Now", comment: "Not now button title"),
                    onTap: {
                        self.dismissPopup()
                        self.clearLocalUserStateAndNavigateToLogin()
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Manage", comment: "Manage subscription button title"),
                    onTap: {
                        self.dismissPopup()
                        Task { @MainActor in
                            // Wait for the manage-subscriptions sheet to dismiss before
                            // navigating, so changing the root screen doesn't close it.
                            await self.showManageSubscriptionsSheet()
                            self.clearLocalUserStateAndNavigateToLogin()
                        }
                    }
                )
            ],
            buttonsAlignment: .horizontal
        )
        presentPopup(with: popupConfiguration)
    }

    /// Presents Apple's native manage-subscriptions sheet, falling back to the
    /// App Store subscriptions web page if the sheet can't be presented.
    @MainActor
    private func showManageSubscriptionsSheet() async {
        guard let scene = activeWindowScene() else {
            openManageSubscriptionsFallbackURL()
            return
        }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            openManageSubscriptionsFallbackURL()
        }
    }

    /// Presents a popup informing the user that account deletion failed.
    @MainActor
    private func presentAccountDeletionFailurePopup() {
        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("Couldn't Delete Account", comment: "Account deletion failure title"),
            description: NSLocalizedString(
                "Something went wrong while deleting your account. Please check your connection and try again.",
                comment: "Account deletion failure description"
            ),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("OK", comment: "OK button title"),
                    onTap: {
                        self.dismissPopup()
                    }
                )
            ],
            buttonsAlignment: .horizontal
        )
        presentPopup(with: popupConfiguration)
    }

    /// Clears all locally persisted user/session state and routes the user back
    /// to the authentication screen. Shared by sign-out and account deletion so
    /// the next account always starts from a clean slate.
    @MainActor
    private func clearLocalUserStateAndNavigateToLogin() {
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

        // Remove the persisted account record so the next login starts from a
        // clean slate. Without this the old account's username (and other
        // per-user state) survives logout, and login skips re-creating the
        // account — leaving Settings showing the previous user's email.
        GlacierAccountModel.getGlacierAccount()?.removeAccount()

        // Navigate immediately — don't block on DB cleanup.
        // DB removal runs fire-and-forget in the background so that
        // navigation always happens even when the phone-number list is empty.
        self.setRootScreen(.userAuthentication)
        self.dismissPresentedScreen()
        self.removeUserAddedPhoneNumbersFromDB()
    }
    
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
