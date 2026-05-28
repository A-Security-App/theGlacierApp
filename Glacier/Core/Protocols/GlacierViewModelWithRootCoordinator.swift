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
        dnsController.apply(configuration: DnsOverTlsConfiguration(urlString: saved.urlString, isEnabled: true)) { _ in }
    }
}
