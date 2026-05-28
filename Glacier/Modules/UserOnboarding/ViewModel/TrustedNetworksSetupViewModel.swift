//
//  TrustedNetworksSetupViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 07/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Network
import NetworkExtension
import SystemConfiguration.CaptiveNetwork

/**
 TrustedNetworksSetupViewModel defines requirements for TrustedNetworksSetupScreen view models.
 */
protocol TrustedNetworksSetupViewModel: GlacierViewModelWithRootCoordinator, GlacierViewModelWithUserOnboardingCoordinator {
    init(rootCoordinator: any GlacierRootCoordinator, userOnboardingCoordinator: any GlacierCoordinator)
    
    func addTrustedNetwork()
    func skip()
}

/**
 TrustedNetworksSetupVM provides data/state and business logic for TrustedNetworksSetupScreen.
 */
final class TrustedNetworksSetupVM: NSObject, TrustedNetworksSetupViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    let rootCoordinator: any GlacierRootCoordinator
    let userOnboardingCoordinator: any GlacierCoordinator
    
    // MARK: - Initializer
    
    required init(rootCoordinator: any GlacierRootCoordinator, userOnboardingCoordinator: any GlacierCoordinator) {
        self.rootCoordinator = rootCoordinator
        self.userOnboardingCoordinator = userOnboardingCoordinator
        
        super.init()
    }
    
    // MARK: - Public methods
    
    func addTrustedNetwork() {
        NEHotspotNetwork.fetchCurrent { [weak self] hotspotNetwork in
            guard let strongSelf = self else { return }
            guard let network = hotspotNetwork else {
                DispatchQueue.main.async {
                    let iswifi = TrustedNetworksSetupVM.isCurrentlyOnWiFi()
                    let message = iswifi
                        ? NSLocalizedString(
                            "Something went wrong while fetching your network details. Please try again.",
                            comment: "Trusted networks setup screen unable to fetch SSID"
                        )
                        : NSLocalizedString(
                            "You are not currently using Wi-Fi and can try again later when connected to your Wi-Fi network.",
                            comment: "Trusted networks setup screen not connected to Wi-Fi"
                        )
                    let title:String = iswifi ? .errorText : .wifiText
                    strongSelf.presentAlertWith(title: title, description: message)
                }
                return
            }
            DispatchQueue.main.async {
                strongSelf.presentConfirmationPopup(for: network.ssid)
            }
        }
    }
    
    func skip() {
        let hasVPN = (WireGuardManager.shared().tunnelsManager?.numberOfTunnels() ?? 0) > 0
        guard hasVPN else {
            navigateToPhoneNumberOnboarding()
            return
        }

        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("VPN is ready.", comment: "Trusted networks skip popup title"),
            description: NSLocalizedString("To enable, go to Glacier Settings.", comment: "Trusted networks skip popup description"),
            buttons: [
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("OK", comment: "OK button title"),
                    onTap: {
                        self.dismissPopup()
                        self.navigateToPhoneNumberOnboarding()
                    }
                )
            ]
        )
        presentPopup(with: popupConfiguration)
    }

    // MARK: - Private methods
    
    /// Returns true when the device has an active WiFi interface.
    /// NWPathMonitor populates currentPath synchronously after start(), so this
    /// can be called inline in a callback without blocking the main thread.
    private static func isCurrentlyOnWiFi() -> Bool {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.start(queue: .global())
        let onWiFi = monitor.currentPath.status == .satisfied
        monitor.cancel()
        return onWiFi
    }

    private func presentConfirmationPopup(for networkName: String) {
        let description = NSLocalizedString("VPN turns off on '%@' network and back on when you disconnect.", comment: "Wifi network setting screen popup description")
        let formattedDescription = String(format: description, arguments: [networkName])

        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("Trust this network?", comment: "Wifi network setting screen popup title"),
            description: formattedDescription,
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                    onTap: {
                        self.dismissPopup()
                    }
                ),
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Trust Network", comment: "Trust network button title"),
                    onTap: {
                        self.updateTunnelOnDemandRules(for: networkName)
                        self.dismissPopup()
                        self.navigateToPhoneNumberOnboarding()
                    }
                )
            ]
        )
        presentPopup(with: popupConfiguration)
    }
    
    // The DoT profile selection gate lives in WiFiSettingsViewModel (post-onboarding).
    // Here in onboarding the user has already completed the DNS and VPN setup steps
    // sequentially, so we commit the trusted network immediately without an async
    // pre-check — which would race with the navigation that follows this call.
    private func updateTunnelOnDemandRules(for networkName: String) {
        commitTrustedNetwork(networkName)
    }

    private func commitTrustedNetwork(_ networkName: String) {
        let installedRegion = UserDefaults.standard.string(forKey: "glacier_vpn_installed_region") ?? "us-east-1"
        guard let tunnelMgr = WireGuardManager.shared().tunnelsManager,
              let tunnel = tunnelMgr.tunnel(named: installedRegion),
              let tunnelConfig = tunnel.tunnelConfiguration else {
            return
        }

        let model = ActivateOnDemandViewModel(tunnel: tunnel)
        model.isWiFiInterfaceEnabled = true
        model.ssidOption = .exceptSpecificSSIDs
        model.selectedSSIDs = [networkName]

        let onDemandOption = model.toOnDemandOption()
        tunnelMgr.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfig, onDemandOption: onDemandOption) { [weak self] error in
            guard let strongSelf = self else { return }
            if error != nil {
                let errorText = NSLocalizedString(
                    "Something went wrong while adding '%@' as a trusted network. Please try again.",
                    comment: "Trusted networks setup screen add trusted network error")
                strongSelf.presentAlertWith(
                    title: .errorText,
                    description: String(format: errorText, arguments: [networkName])
                )
            }
        }
    }
}
