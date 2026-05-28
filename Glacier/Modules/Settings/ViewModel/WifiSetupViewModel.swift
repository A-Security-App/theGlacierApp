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
        UserDefaults.standard.string(forKey: "glacier_vpn_installed_region") ?? "us-east-1"
    }

    // MARK: - Initializer

    required init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        super.init()
    }

    // MARK: - Public methods

    func addCurrentWifiAsTrusted() {
        NEHotspotNetwork.fetchCurrent { [weak self] hotspotNetwork in
            guard let self else { return }
            guard let network = hotspotNetwork else {
                DispatchQueue.main.async {
                    let isWifi = WifiSetupVM.isCurrentlyOnWiFi()
                    let message = isWifi
                        ? NSLocalizedString(
                            "Something went wrong while fetching your network details. Please try again.",
                            comment: "Wifi setup screen unable to fetch SSID"
                          )
                        : NSLocalizedString(
                            "You are not currently using Wi-Fi and can try again later when connected to your Wi-Fi network.",
                            comment: "Wifi setup screen not connected to Wi-Fi"
                          )
                    let title: String = isWifi ? .errorText : .wifiText
                    self.presentAlertWith(title: title, description: message)
                }
                return
            }
            DispatchQueue.main.async {
                self.presentConfirmationPopup(for: network.ssid)
            }
        }
    }

    func skip() {
        completeAndDismiss()
    }

    // MARK: - Private methods

    private static func isCurrentlyOnWiFi() -> Bool {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.start(queue: .global())
        let onWiFi = monitor.currentPath.status == .satisfied
        monitor.cancel()
        return onWiFi
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
                    title: NSLocalizedString("Trust Network", comment: "Trust network button title"),
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
        model.selectedSSIDs = [networkName]

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
