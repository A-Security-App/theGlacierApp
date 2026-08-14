//
//  WifiSetupViewModel.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Network
import NetworkExtension

/**
 WifiSetupViewModel defines requirements for WifiSetupScreen view models.
 */
protocol WifiSetupViewModel: GlacierViewModelWithRootCoordinator {
    init(rootCoordinator: any GlacierRootCoordinator)
    func addCurrentWifiAsTrusted()
    func skip()
}

/**
 WifiSetupVM provides data/state and business logic for WifiSetupScreen.
 Marks VPN first-time setup complete and pops both mini-onboarding screens off the stack when done.
 */
final class WifiSetupVM: NSObject, WifiSetupViewModel, ObservableObject {

    // MARK: - Public properties

    let rootCoordinator: any GlacierRootCoordinator

    // MARK: - Private properties

    private let wireGuardManager = WireGuardManager.shared()

    private var currentInstalledRegion: String {
        UserDefaults.standard.string(forKey: "glacier_vpn_installed_region") ?? "us-east-2"
    }

    // MARK: - Initializer

    required init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        super.init()
    }

    // MARK: - Public methods

    func addCurrentWifiAsTrusted() {
        // Adapt the options to context: offer the current-network shortcut only
        // when on Wi-Fi and that network isn't already trusted; otherwise (off
        // Wi-Fi, SSID unavailable, or already trusted) go straight to manual
        // entry so this step is still usable when we can't read the SSID.
        NEHotspotNetwork.fetchCurrent { [weak self] hotspotNetwork in
            guard let self else { return }
            DispatchQueue.main.async {
                let currentSSID = hotspotNetwork?.ssid
                let alreadyTrusted: Bool = {
                    guard let currentSSID else { return false }
                    return self.currentTrustedSSIDs().contains {
                        $0.caseInsensitiveCompare(currentSSID) == .orderedSame
                    }
                }()

                if let currentSSID, !alreadyTrusted {
                    self.presentAddTrustedNetworkChooserPopup(currentSSID: currentSSID)
                } else {
                    self.presentManualSSIDEntryPopup()
                }
            }
        }
    }

    func skip() {
        completeAndDismiss()
    }

    // MARK: - Private methods

    /// Returns the SSIDs already stored as trusted networks on the tunnel.
    private func currentTrustedSSIDs() -> [String] {
        guard let tunnelMgr = wireGuardManager.tunnelsManager,
              let tunnel = tunnelMgr.tunnel(named: currentInstalledRegion) else {
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
        let description = NSLocalizedString(
            "VPN turns off on '%@' network and back on when you disconnect.",
            comment: "Wifi setup screen popup description"
        )
        let formattedDescription = String(format: description, arguments: [networkName])

        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("Trust this network?", comment: "Wifi setup screen popup title"),
            description: formattedDescription,
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                    onTap: { self.dismissPopup() }
                ),
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Add", comment: "Trust network button title"),
                    onTap: {
                        self.commitTrustedNetwork(networkName)
                        self.dismissPopup()
                        self.completeAndDismiss()
                    }
                )
            ]
        )
        presentPopup(with: popupConfiguration)
    }

    private func commitTrustedNetwork(_ networkName: String) {
        guard let tunnelMgr = wireGuardManager.tunnelsManager,
              let tunnel = tunnelMgr.tunnel(named: currentInstalledRegion),
              let tunnelConfig = tunnel.tunnelConfiguration else { return }

        let model = ActivateOnDemandViewModel(tunnel: tunnel)
        model.isWiFiInterfaceEnabled = true
        model.ssidOption = .exceptSpecificSSIDs
        // Append (with dedup) rather than replace, so adding a second network
        // doesn't overwrite one that was already trusted.
        if !model.selectedSSIDs.contains(where: { $0.caseInsensitiveCompare(networkName) == .orderedSame }) {
            model.selectedSSIDs.append(networkName)
        }

        let onDemandOption = model.toOnDemandOption()
        tunnelMgr.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfig, onDemandOption: onDemandOption) { [weak self] error in
            if error != nil {
                let errorText = NSLocalizedString(
                    "Something went wrong while adding '%@' as a trusted network. Please try again.",
                    comment: "Wifi setup screen add trusted network error"
                )
                self?.presentAlertWith(
                    title: .errorText,
                    description: String(format: errorText, arguments: [networkName])
                )
            }
        }
    }

    private func completeAndDismiss() {
        UserDefaultsService.shared.set(true, for: \.hasCompletedVPNFirstTimeSetup)
        // Pop both wifiSetup and cellularSetup off the navigation stack atomically.
        if let appCoordinator = rootCoordinator as? GlacierAppRootCoordinator {
            let toRemove = min(2, appCoordinator.path.count)
            if toRemove > 0 {
                appCoordinator.path.removeLast(toRemove)
            }
        }
    }
}
