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
        // Adapt the options to context: offer the current-network shortcut only
        // when on Wi-Fi and that network isn't already trusted; otherwise (off
        // Wi-Fi, SSID unavailable, or already trusted) go straight to manual
        // entry so the step is still actionable.
        NEHotspotNetwork.fetchCurrent { [weak self] hotspotNetwork in
            guard let strongSelf = self else { return }
            DispatchQueue.main.async {
                let currentSSID = hotspotNetwork?.ssid
                let alreadyTrusted: Bool = {
                    guard let currentSSID else { return false }
                    return strongSelf.currentTrustedSSIDs().contains {
                        $0.caseInsensitiveCompare(currentSSID) == .orderedSame
                    }
                }()

                if let currentSSID, !alreadyTrusted {
                    strongSelf.presentAddTrustedNetworkChooserPopup(currentSSID: currentSSID)
                } else {
                    strongSelf.presentManualSSIDEntryPopup()
                }
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

    /// Returns the SSIDs already stored as trusted networks on the tunnel.
    private func currentTrustedSSIDs() -> [String] {
        let installedRegion = UserDefaults.standard.string(forKey: "glacier_vpn_installed_region") ?? "us-east-2"
        guard let tunnelMgr = WireGuardManager.shared().tunnelsManager,
              let tunnel = tunnelMgr.tunnel(named: installedRegion) else {
            return []
        }
        return ActivateOnDemandViewModel(tunnel: tunnel).selectedSSIDs
    }

    /// Chooser shown when the device is on a Wi-Fi network that isn't already
    /// trusted: add the current network with one tap, or type a network name.
    private func presentAddTrustedNetworkChooserPopup(currentSSID: String) {
        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("Add trusted network", comment: "WiFi settings screen add trusted networks button title"),
            description: NSLocalizedString(
                "Add the network you're on now, or enter a network name to trust.",
                comment: "Add trusted network chooser popup description"
            ),
            buttons: [
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Add current network", comment: "Add the currently connected Wi-Fi network button title"),
                    onTap: {
                        self.dismissPopup()
                        self.presentConfirmationPopup(for: currentSSID)
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Enter network name", comment: "Manually enter a Wi-Fi network name button title"),
                    onTap: {
                        self.dismissPopup()
                        self.presentManualSSIDEntryPopup()
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                    onTap: {
                        self.dismissPopup()
                    }
                )
            ],
            buttonsAlignment: .vertical
        )
        presentPopup(with: popupConfiguration)
    }

    /// Prompts the user to type an SSID, then routes the trimmed, non-empty
    /// value into the same confirmation flow used for the current network.
    private func presentManualSSIDEntryPopup() {
        var enteredSSID = ""
        let inputTextConfiguration = PopupInputTextConfiguration(
            placeholder: NSLocalizedString("Network name", comment: "Manual SSID entry text field placeholder"),
            onInputTextChange: { text in enteredSSID = text }
        )
        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("Enter network name", comment: "Manually enter a Wi-Fi network name button title"),
            description: NSLocalizedString(
                "Type the Wi-Fi network name (SSID) you want to trust.",
                comment: "Manual SSID entry popup description"
            ),
            inputTextConfiguration: inputTextConfiguration,
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
                    title: NSLocalizedString("Next", comment: "Continue to trusted-network confirmation button title"),
                    onTap: {
                        let ssid = enteredSSID.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.dismissPopup()
                        guard !ssid.isEmpty else {
                            self.presentAlertWith(
                                title: nil,
                                description: NSLocalizedString(
                                    "Please enter a network name.",
                                    comment: "Empty SSID validation message"
                                )
                            )
                            return
                        }
                        self.presentConfirmationPopup(for: ssid)
                    }
                )
            ]
        )
        presentPopup(with: popupConfiguration)
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
                    title: NSLocalizedString("Add", comment: "Trust network button title"),
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
        let installedRegion = UserDefaults.standard.string(forKey: "glacier_vpn_installed_region") ?? "us-east-2"
        guard let tunnelMgr = WireGuardManager.shared().tunnelsManager,
              let tunnel = tunnelMgr.tunnel(named: installedRegion),
              let tunnelConfig = tunnel.tunnelConfiguration else {
            return
        }

        let model = ActivateOnDemandViewModel(tunnel: tunnel)
        model.isWiFiInterfaceEnabled = true
        model.ssidOption = .exceptSpecificSSIDs
        // Append (with dedup) rather than replace, so adding a second network
        // during onboarding doesn't overwrite one that was already trusted.
        if !model.selectedSSIDs.contains(where: { $0.caseInsensitiveCompare(networkName) == .orderedSame }) {
            model.selectedSSIDs.append(networkName)
        }

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
