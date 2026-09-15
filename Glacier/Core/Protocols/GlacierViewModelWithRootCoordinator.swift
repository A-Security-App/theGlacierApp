//
//  GlacierViewModelWithRootCoordinator.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 27/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 GlacierViewModelWithRootCoordinator defines common requirements for view models that need to have root coordinator for managing root level screen nagivations.
 */
protocol GlacierViewModelWithRootCoordinator: AnyObject {
    
    /**
     It is reference to the app root coordinator that helps presenting/dismissing progress indicator, alerts, sheets, etc at root level.
     */
    var rootCoordinator: any GlacierRootCoordinator { get }
    
    /**
     It sets the given root screen type as the app root screen
     */
    func setRootScreen(_ screen: GlacierScreen)
    
    /**
     This is called to bring in new screen over the current screen.
     For example: Bringing in settings screen over the home screen.
     */
    func presentScreen(_ screen: GlacierScreen)
    
    /**
     This is called to dismiss the presented screen over the current screen.
     For example: Dismissing the settings screen, displaying over the home screen.
     */
    func dismissPresentedScreen()
    
    /**
     It presents given sheet type as the sheet view over the current screen
     */
    func presentSheet(_ sheet: Sheet)
    
    /**
     It dismisses the presented sheet view
     */
    func dismissSheet()
    
    /**
     It presents the popup view (alerts, confirmation, input field, etc) over the current screen
     */
    func presentPopup(with configuration: PopupConfiguration)
    
    /**
     It checks if a popup is presented over the current app window
     */
    func isPresentingPopup() async -> Bool
    
    /**
     It dismisses the presented popup view
     */
    func dismissPopup()
    
    /**
     Presents an alert with given title and description above the root view
     */
    func presentAlertWith(title: String?, description: String?, buttonTitle: String)
    
    /**
     It displays the progress indicator over the curren screen
     */
    func presentProgressIndicator()
    
    /**
     It hides the presented progress indicator
     */
    func dismissProgressIndicator()
}

extension GlacierViewModelWithRootCoordinator {
    
    func setRootScreen(_ screen: GlacierScreen) {
        guard let appRootCoordinator = rootCoordinator as? GlacierAppRootCoordinator else {
            return
        }
        appRootCoordinator.setScreen(screen)
    }
    
    func presentScreen(_ screen: GlacierScreen) {
        guard let appRootCoordinator = rootCoordinator as? GlacierAppRootCoordinator else {
            return
        }
        appRootCoordinator.presentScreen(screen)
    }
    
    func dismissPresentedScreen() {
        guard let appRootCoordinator = rootCoordinator as? GlacierAppRootCoordinator else {
            return
        }
        appRootCoordinator.dismissPresentedScreen()
    }
    
    func presentSheet(_ sheet: Sheet) {
        guard let appRootCoordinator = rootCoordinator as? GlacierAppRootCoordinator else {
            return
        }
        appRootCoordinator.presentSheet(sheet)
    }
    
    func dismissSheet() {
        guard let appRootCoordinator = rootCoordinator as? GlacierAppRootCoordinator else {
            return
        }
        appRootCoordinator.dismissSheet()
    }
    
    func presentPopup(with configuration: PopupConfiguration) {
        guard let appRootCoordinator = rootCoordinator as? GlacierAppRootCoordinator else {
            return
        }
        appRootCoordinator.presentPopup(with: configuration)
    }
    
    func dismissPopup() {
        guard let appRootCoordinator = rootCoordinator as? GlacierAppRootCoordinator else {
            return
        }
        appRootCoordinator.dismissPopup()
    }
    
    func isPresentingPopup() async -> Bool {
        await MainActor.run {
            return OverlayViewManager.shared.isPresentingPopupView()
        }
    }
    
    func presentAlertWith(
        title: String?,
        description: String?,
        buttonTitle: String = NSLocalizedString("Ok", comment: "Ok button title")
    ) {
        guard let appRootCoordinator = rootCoordinator as? GlacierAppRootCoordinator else {
            return
        }
        let popupConfiguration = PopupConfiguration(
            title: title,
            description: description,
            buttons: [
                PopupButton(
                    style: .primary,
                    title: buttonTitle,
                    onTap: {
                        self.rootCoordinator.dismissPopup()
                    }
                )
            ]
        )
        appRootCoordinator.presentPopup(with: popupConfiguration)
    }

    func presentEmergencyServicesUnavailableAlert() {
        presentAlertWith(
            title: nil,
            description: CallManager.emergencyServicesUnavailableMessage
        )
    }

    /**
     `true` when the signed-in account's phone lines are granted by the *web* (Stripe)
     subscription rather than by Apple.

     Reads the persisted last-known backend value instead of re-querying, so this stays
     synchronous and never blocks a tap on the network. The value is refreshed on every launch
     and foreground by `refreshBackendSubscription()`.
     */
    var hasWebManagedPhoneSubscription: Bool {
        (GlacierAccountModel.getGlacierAccount()?.lastKnownBackendPhoneNumbers ?? 0) > 0
    }

    /**
     Gates the "add / upgrade phone lines" tap.

     A user whose lines come from the web subscription is warned instead of being sent to
     StoreKit. Apple cannot upgrade a web subscription: the App Store sees a first-time purchase
     in the add-on group, charges full price with no proration, and the web subscription keeps
     billing — so the user pays twice. Only the *backend* line count matters for this gate; the
     Apple side is 0 by definition for these users, and once it isn't, StoreKit handles
     same-group upgrades (with proration) itself.

     Deliberately fails open: `lastKnownBackendPhoneNumbers` is 0 until the first successful
     `/status` response, so a web subscriber on a dead network slips past the warning rather than
     having a legitimate Apple purchase blocked by a blip. The window is narrow — with both
     sources reading 0 the user has no phone subscription and no upgrade affordance to begin with.

     The warning intentionally does not link out to the web checkout: a purchase-adjacent popup
     that steers to an external payment flow is what App Store Review Guideline 3.1.1 targets.
     Naming where the plan lives is enough to stop the double charge.
     */
    func presentPhoneNumberPlanPurchase(orWarnWebManaged proceed: () -> Void) {
        guard hasWebManagedPhoneSubscription else {
            proceed()
            return
        }

        presentAlertWith(
            title: NSLocalizedString(
                "Your plan is managed on the web",
                comment: "Web-managed phone subscription upgrade warning title"
            ),
            description: NSLocalizedString(
                "You subscribed to your phone lines through the Glacier website, so changes to your plan need to be made there. Subscribing here would start a second, separate subscription and you’d be billed for both.",
                comment: "Web-managed phone subscription upgrade warning description"
            )
        )
    }
    
    func presentProgressIndicator() {
        guard let appRootCoordinator = rootCoordinator as? GlacierAppRootCoordinator else {
            return
        }
        appRootCoordinator.presentProgressIndicator()
    }
    
    func dismissProgressIndicator() {
        guard let appRootCoordinator = rootCoordinator as? GlacierAppRootCoordinator else {
            return
        }
        appRootCoordinator.dismissProgressIndicator()
    }

    /// Called at each onboarding exit point. If the user set up DNS during onboarding
    /// without enabling VPN (which would have already activated DNS via `ensureEnabledForVPN`),
    /// this enables DNS so it behaves as if the user tapped "Connect" on the main screen.
    func connectDNSIfSetUpDuringOnboarding() {
        let didSetUpDNS: Bool = UserDefaultsService.shared.get(for: \.didCompleteDNSSetupDuringOnboarding) ?? false
        UserDefaultsService.shared.remove(for: \.didCompleteDNSSetupDuringOnboarding)
        guard didSetUpDNS else { return }
        let dnsController = DnsOverTlsController.shared
        let saved = dnsController.loadSavedConfiguration()
        guard !saved.isEnabled, saved.urlString != nil else { return }
        UserDefaults(suiteName: kGlacierGroup)?.set(SecuredConnectionType.dns.rawValue, forKey: kLastConnectionTypeKey)
        // `apply` persists `isEnabled` asynchronously (well after we navigate to Main), so the first
        // Home screen scan can't tell from the saved flag that DNS was just enabled. Leave a one-shot
        // marker so that scan runs a retry-until-verified probe and rides out the DoT activation
        // latency instead of settling on a spurious "Disconnected". Consumed in `HomeVM.refreshStatus`.
        UserDefaultsService.shared.set(true, for: \.dnsActivationPendingFromOnboarding)
        dnsController.apply(configuration: DnsOverTlsConfiguration(urlString: saved.urlString, isEnabled: true)) { _ in }
    }
}
