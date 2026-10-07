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
    var shouldShowVPNSettingsOption: Bool { get }
    var shouldShowResetPasswordOption: Bool { get }

    func presentVPNSettingsScreen()
    func presentSubscriptionSettingsScreen()
    func presentAppearanceSettingsScreen()
    func presentWidgetSettingsScreen()
    func presentNotificationSettingsScreen()
    func presentResetPasswordScreen()
    func dismissResetPasswordScreen()

    @MainActor
    func signOut()

    @MainActor
    func deleteAccount()

    @MainActor
    func manageSubscription()
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

    // MARK: - Private properties

    var rootCoordinator: any GlacierRootCoordinator

    // MARK: - Initializer

    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        getUserDetails()
    }
    
    // MARK: - Public methods
    
    func presentVPNSettingsScreen() {
        presentScreen(.vpnSettings)
    }
    
    func presentSubscriptionSettingsScreen() {
        presentScreen(.subscriptionSettings)
    }

    func presentAppearanceSettingsScreen() {
        presentSheet(.appearanceSettings)
    }

    func presentWidgetSettingsScreen() {
        presentSheet(.widgetSettings)
    }

    func presentNotificationSettingsScreen() {
        presentSheet(.notificationSettings)
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
                            self.teardownVPNAndDNS()

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
        // Capture where any subscription is billed now: the persisted values are read before
        // local cleanup clears the account record, and no network call belongs on this path.
        let billingRoute = DeletionBillingRoute(account: GlacierAccountModel.getGlacierAccount())

        var description = NSLocalizedString(
            "This permanently deletes your Glacier account and associated data. This action cannot be undone.",
            comment: "Settings screen delete account confirmation description"
        )
        if let note = billingRoute.confirmationNote {
            description += "\n\n" + note
        }

        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("Delete Account?", comment: "Settings screen delete account confirmation title"),
            description: description,
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
                        self.presentDeletionReasonPopup(billingRoute: billingRoute)
                    }
                )
            ],
            buttonsAlignment: .horizontal
        )
        presentPopup(with: popupConfiguration)
    }

    /// Opens Apple's manage-subscriptions sheet so the user can cancel or change their plan.
    /// Also offered on the lapse paywall, where Settings is unreachable.
    @MainActor
    func manageSubscription() {
        Task { @MainActor in
            await showManageSubscriptionsSheet()
        }
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

    /// Swaps the delete confirmation for the "why are you leaving?" question. Answering is
    /// optional; only backing out of it leaves the account in place.
    ///
    /// Talks to `OverlayViewManager` directly because the coordinator's popup calls are
    /// asynchronous: dismissing through it and presenting straight after would present first,
    /// get ignored (a popup is still up), and then dismiss.
    @MainActor
    private func presentDeletionReasonPopup(billingRoute: DeletionBillingRoute) {
        let overlay = OverlayViewManager.shared
        overlay.dismissPopupView()
        overlay.presentPopupView(
            AccountDeletionReasonPopup(
                onDelete: { feedback in
                    overlay.dismissPopupView()
                    Task { @MainActor in
                        await self.performAccountDeletion(feedback: feedback, billingRoute: billingRoute)
                    }
                },
                onCancel: {
                    overlay.dismissPopupView()
                }
            )
        )
    }

    /// Deletes the account, sending the user's answer with the request, then tells them about
    /// any subscription that outlives it before returning to the login screen.
    @MainActor
    private func performAccountDeletion(feedback: AccountDeletionFeedback?, billingRoute: DeletionBillingRoute) async {
        // Tear down and remove the VPN + DoT DNS before deleting so no
        // tunnel keeps running and no DNS profile stays installed for an
        // account that no longer exists.
        teardownVPNAndDNS()

        // Delete the account on the Glacier backend. The backend
        // deletes the Cognito user *and* performs the associated
        // server-side cleanup (website subscription, phone numbers, etc.).
        presentProgressIndicator()
        let didDelete = await AccountDeletionManager.shared.deleteAccount(feedback: feedback)
        dismissProgressIndicator()
        guard didDelete else {
            // The account still exists, so leave local state intact and
            // let the user retry instead of stranding them on the login screen.
            presentAccountDeletionFailurePopup()
            return
        }

        // The backend deleted the Cognito user, but this device still
        // holds a cached Amplify session. Sign out locally to clear it
        // before local cleanup so the next login starts clean.
        let service = AmplifyAuthenticationService()
        _ = await service.signOut()

        // App Store and Google Play subscriptions can't be cancelled for the user, so if one is
        // still billing we say where before navigating away. Otherwise finish immediately.
        if billingRoute.outlivingStores.isEmpty {
            clearLocalUserStateAndNavigateToLogin()
        } else {
            presentStillSubscribedNotice(for: billingRoute)
        }
    }

    /// Shown after a successful account deletion when a subscription is still billing.
    ///
    /// When Apple bills any of it, the user is offered Apple's manage-subscriptions sheet.
    /// Otherwise the notice only names where the subscription lives: a purchase-adjacent popup
    /// that links out to another store or payment flow is what App Store Review Guideline 3.1.1
    /// targets. Either way the user ends up on the login screen.
    @MainActor
    private func presentStillSubscribedNotice(for billingRoute: DeletionBillingRoute) {
        let stores = billingRoute.outlivingStores
        let description: String
        if stores.contains(.unknown) {
            description = NSLocalizedString(
                "Your account has been deleted, but your subscription is still active. Remember to cancel it where you subscribed so you aren't billed again.",
                comment: "Still-subscribed notice when the billing store isn't known"
            )
        } else if stores == [.apple] {
            description = NSLocalizedString(
                "Your account has been deleted, but your App Store subscription is still active. Cancel it to stop being billed.",
                comment: "Still-subscribed notice for an App Store subscription"
            )
        } else if stores == [.googlePlay] {
            description = NSLocalizedString(
                "Your account has been deleted, but your Google Play subscription is still active. Cancel it in the Google Play Store to stop being billed.",
                comment: "Still-subscribed notice for a Google Play subscription"
            )
        } else {
            description = NSLocalizedString(
                "Your account has been deleted, but your App Store and Google Play subscriptions are still active. Cancel each one to stop being billed.",
                comment: "Still-subscribed notice for App Store and Google Play subscriptions"
            )
        }

        let buttons: [PopupButton]
        if stores.contains(.apple) {
            buttons = [
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
            ]
        } else {
            buttons = [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Ok", comment: "Ok button title"),
                    onTap: {
                        self.dismissPopup()
                        self.clearLocalUserStateAndNavigateToLogin()
                    }
                )
            ]
        }

        presentPopup(with: PopupConfiguration(
            title: stores.contains(.apple)
                ? NSLocalizedString("Manage Your Subscription", comment: "Manage subscription follow-up title")
                : NSLocalizedString("Cancel Your Subscription", comment: "Still-subscribed notice title"),
            description: description,
            buttons: buttons,
            buttonsAlignment: .horizontal
        ))
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
    
    /// Turns off *and* fully removes both the VPN tunnel and the DoT DNS profile
    /// from the device. Used on manual sign-out and account deletion so a
    /// signed-out (or deleted) account never leaves a tunnel running or a
    /// system-wide DoT resolver installed — matching what an uninstall does.
    ///
    /// Removing an NE profile both stops it and deletes it from system
    /// preferences, and neither removal requires a user permission prompt
    /// (only *adding* a profile does). We first signal the live tunnel to stop
    /// so the data path drops promptly even if profile removal lags, then remove
    /// the tunnel and DoT profiles.
    private func teardownVPNAndDNS() {
        WireGuardManager.shared().turnOffCore()
        WireGuardManager.shared().removeAllTunnels()
        DnsOverTlsController.shared.removeDoTProfile()
        // The cached profile id belongs to the account that just signed out. Leaving it behind
        // would let the next user's DNS fall back to — or be healed onto — someone else's
        // profile, putting their queries in that account's logs.
        UserDefaultsService.shared.remove(for: \.lastKnownDNSProfileID)
        UserDefaultsService.shared.remove(for: \.lastDNSProfileHealAttempt)
        // Both profiles are gone now, so any pending "enforcement turned this off, put it back"
        // record is stale — and must not re-arm protection for whoever signs in next.
        BaseSubscriptionLifecycleHandler.shared.clearEnforcementRestoreState()
    }

    private func removeUserAddedPhoneNumbersFromDB() {
        let internalQueue = DispatchQueue(label: "settings-module-queue", qos: .userInitiated)
        internalQueue.async {
            PhoneAccount.allSMSAccounts().forEach { $0.remove {} }
        }
    }
}

// MARK: - Deletion billing route

/**
 Where the account's subscriptions are billed, captured when the user confirms deletion, to say
 what happens to them. Built from persisted values only (`mobile/status` sources, the last-known
 backend state, and the reconciled StoreKit + backend flags), so it never waits on the network.

 Deleting the account cancels a website (Stripe) subscription on the backend (console#563).
 App Store and Google Play subscriptions can only be cancelled by the user, so they outlive it.
 */
struct DeletionBillingRoute: Equatable {

    enum OutlivingStore: Hashable {
        case apple, googlePlay
        /// Something is billing but the backend didn't say which store.
        case unknown
    }

    /// Stores that keep billing after the account is deleted.
    let outlivingStores: Set<OutlivingStore>
    /// `true` when part of the plan is billed on the website and is cancelled with the account.
    let cancelsWebsitePlan: Bool

    init(account: GlacierAccountModel?) {
        var stores = Set<OutlivingStore>()
        var cancelsWebsitePlan = false

        func add(_ source: BillingStore?, unknownMeansApple: Bool) {
            switch source {
            case .stripe: cancelsWebsitePlan = true
            case .apple: stores.insert(.apple)
            case .googlePlay: stores.insert(.googlePlay)
            case nil: stores.insert(unknownMeansApple ? .apple : .unknown)
            }
        }

        if let account {
            // A family member's plan is billed to whoever runs the family plan, not to them.
            if account.hasActiveSubscription && !account.lastKnownBackendFamilyMember {
                // No source (a backend before console#573, or no successful status call yet):
                // if the backend doesn't see a subscription either, StoreKit is what granted it.
                add(account.lastKnownBackendSubscriptionSource,
                    unknownMeansApple: !account.lastKnownBackendSubscribed)
            }
            if account.hasActivePhoneNumberSubscription {
                add(account.lastKnownBackendPhoneLineSource,
                    unknownMeansApple: account.lastKnownBackendPhoneNumbers == 0)
            }
        }

        self.outlivingStores = stores
        self.cancelsWebsitePlan = cancelsWebsitePlan
    }

    /// Added to the delete confirmation when part of the plan is billed on the website, which
    /// the backend cancels along with the account. `nil` otherwise.
    ///
    /// App Store, Google Play and unknown-store subscriptions aren't mentioned here: the notice
    /// after deletion (`presentStillSubscribedNotice`) tells the user about those, with a Manage
    /// button for Apple, so saying it here too would say it twice. The website plan gets no
    /// notice afterwards, so this is the only place it's mentioned.
    var confirmationNote: String? {
        guard cancelsWebsitePlan else { return nil }
        return NSLocalizedString(
            "Your subscription on the Glacier website will be canceled too.",
            comment: "Delete confirmation note for a website subscription"
        )
    }
}
