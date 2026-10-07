//
//  GlacierViewModelWithRootCoordinator.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 27/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import StoreKit
import UIKit

/**
 The Glacier website, where website (Stripe) subscriptions are managed.

 Linking to it from a purchase-adjacent screen is steering under App Store Review Guideline 3.1.1
 everywhere except the United States storefront, where since May 2025 apps may include links to
 outside purchase flows without an entitlement. So the link is offered only on the US storefront;
 elsewhere the app just names the website.
 */
enum GlacierWebsite {

    /// The console's root page. The app's universal links claim only the `/…-securityapp` paths
    /// (see the site's apple-app-site-association), so this opens in Safari, not back in the app.
    static let manageSubscriptionURL = URL(string: "https://console.theglacierapp.com/")!

    /**
     Whether the App Store account on this device is on the US storefront, and so whether the app
     may link to the website. `false` when StoreKit doesn't answer within `timeout`: hiding a link
     is always allowed, showing one where it isn't is a rejection.
     */
    static func canLinkToWebsite(timeout: TimeInterval = 1.5) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await Storefront.current?.countryCode == "USA" }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    @MainActor
    static func openManageSubscription() {
        UIApplication.shared.open(manageSubscriptionURL)
    }
}

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
     Gates the "add / upgrade phone lines" tap.

     Buying through StoreKit is only safe when Apple already bills the lines, or nothing does.
     Apple can't change a subscription another store bills: the App Store sees a first-time
     purchase in the add-on group, charges full price, and the other subscription keeps billing,
     so the user pays twice. In that case the user is told where the plan lives instead.

     Who bills the lines is decided in this order:
     1. **The backend reports no lines:** nothing bills them, so go straight to StoreKit. This is
        also the fail-open path before the first successful `mobile/status` response.
     2. **StoreKit on this device holds the add-on:** Apple bills them, and StoreKit handles
        same-group upgrades (with proration) itself. Checked at tap time rather than read from
        `hasActivePhoneNumberSubscription`, which merges Apple and backend grants. The backend's
        line count includes Apple lines, so it can't tell the two apart on its own.
     3. **Otherwise, the backend's `phoneLineSource`:** website, Google Play, or Apple on a
        different Apple Account. With no source (an older backend), the lines are assumed to be
        the website's, as before.

     The warnings don't link out to Google Play, and link to the website only on the US storefront
     (see `GlacierWebsite`): elsewhere, a purchase-adjacent popup that steers to an external payment
     flow is what App Store Review Guideline 3.1.1 targets. Naming where the plan lives is enough
     to stop the double charge.
     */
    func presentPhoneNumberPlanPurchase(orWarnManagedElsewhere proceed: @escaping @MainActor () -> Void) {
        guard let account = GlacierAccountModel.getGlacierAccount(),
              account.lastKnownBackendPhoneNumbers > 0 else {
            Task { @MainActor in proceed() }
            return
        }
        let phoneLineSource = account.lastKnownBackendPhoneLineSource

        Task { @MainActor in
            let appleEntitlement = await GlacierPhoneNumberSubscriptionPlan.appleEntitlement()
            if appleEntitlement == .active {
                proceed()
                return
            }

            switch phoneLineSource {
            case .apple:
                // Apple bills the lines, but not to the App Store account on this device — or
                // StoreKit didn't answer in time. Only a definite "not held" means a different
                // Apple Account; if StoreKit is just slow, let its own sheet handle the upgrade.
                guard appleEntitlement == .notHeld else {
                    proceed()
                    return
                }
                // "Not held" is also what lines that just expired on this Apple Account look like
                // while the backend's 3-day grace still counts them. Buying again then can't
                // double-bill: nothing is still billing. An unanswered history check keeps the
                // warning, since a wrong "go ahead" could start a second subscription.
                if await GlacierPhoneNumberSubscriptionPlan.appleLinesEndedRecently() == true {
                    proceed()
                    return
                }
                self.presentAlertWith(
                    title: NSLocalizedString(
                        "Your plan is on another Apple Account",
                        comment: "Phone plan billed to a different Apple Account warning title"
                    ),
                    description: NSLocalizedString(
                        "Your phone lines are billed through the App Store on a different Apple Account. To change your plan, sign in to the App Store with that account. Subscribing here would start a second, separate subscription and you’d be billed for both.",
                        comment: "Phone plan billed to a different Apple Account warning description"
                    )
                )

            case .googlePlay:
                self.presentAlertWith(
                    title: NSLocalizedString(
                        "Your plan is managed in Google Play",
                        comment: "Google Play-managed phone subscription upgrade warning title"
                    ),
                    description: NSLocalizedString(
                        "You subscribed to your phone lines through Google Play, so changes to your plan need to be made there. Subscribing here would start a second, separate subscription and you’d be billed for both.",
                        comment: "Google Play-managed phone subscription upgrade warning description"
                    )
                )

            case .stripe, nil:
                let title = NSLocalizedString(
                    "Your plan is managed on the web",
                    comment: "Web-managed phone subscription upgrade warning title"
                )
                let description = NSLocalizedString(
                    "You subscribed to your phone lines through the Glacier website, so changes to your plan need to be made there. Subscribing here would start a second, separate subscription and you’d be billed for both.",
                    comment: "Web-managed phone subscription upgrade warning description"
                )
                guard await GlacierWebsite.canLinkToWebsite() else {
                    self.presentAlertWith(title: title, description: description)
                    return
                }
                self.presentPopup(with: PopupConfiguration(
                    title: title,
                    description: description,
                    buttons: [
                        PopupButton(
                            style: .tertiary,
                            title: NSLocalizedString("Not Now", comment: "Not now button title"),
                            onTap: {
                                self.dismissPopup()
                            }
                        ),
                        PopupButton(
                            style: .tertiary,
                            title: NSLocalizedString("Go to Website", comment: "Open the Glacier website button title"),
                            onTap: {
                                self.dismissPopup()
                                Task { @MainActor in GlacierWebsite.openManageSubscription() }
                            }
                        )
                    ],
                    buttonsAlignment: .horizontal
                ))
            }
        }
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
