//
//  WiFiSettingsViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 21/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Network
import NetworkExtension
import SystemConfiguration.CaptiveNetwork
import UIKit

/**
 WiFiSettingsViewModel defines requirements for Wifi settings screen view models.
 */
protocol WiFiSettingsViewModel: GlacierViewModelWithRootCoordinator {
    
    var selectedVPNActivationPolicy: VPNActivationOverWiFiPolicy { get set }
    var trustedNetworks: [TrustedNetwork] { get }
    
    init(rootCoordinator: any GlacierRootCoordinator)
    
    func initialize()
    func getConfirmationForVPNActivationPolicyChange(to policy: VPNActivationOverWiFiPolicy)
    func removeTrustedNetwork(_ networkName: String)
    func presentAddTrustedNetworkPopup()
}

/**
 WiFiSettingsVM defines data/states and business logic for WiFI settings screen UI/UX and functionality.
 */
final class WiFiSettingsVM: WiFiSettingsViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var selectedVPNActivationPolicy: VPNActivationOverWiFiPolicy = .activeOnAllNetworks
    @Published var trustedNetworks: [TrustedNetwork] = []
    
    let rootCoordinator: any GlacierRootCoordinator
    
    // MARK: - Private properties

    private let wireGuardManager: WireGuardManager = WireGuardManager.shared()
    private let securityCenter: SecurityCenter = SecurityCenter()
    private let dnsController: DnsOverTlsController = DnsOverTlsController.shared
    private var selectedVPNProfile: TunnelContainer?
    /// Set when the user chose "Open Settings" from the DoT warning popup so we can
    /// re-check and commit the trusted network once they return to the app.
    private var pendingTrustedNetworkName: String?

    // MARK: - Initializer

    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator

        if let policyValue: String = UserDefaultsService.shared.get(for: \.vpnActivationOverWiFiPolicy), let policy = VPNActivationOverWiFiPolicy(rawValue: policyValue) {
            selectedVPNActivationPolicy = policy
        } else {
            selectedVPNActivationPolicy = .activeOnAllNetworks
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAppBecameActive),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public methods

    func initialize() {
        setupWireGuardManager()
    }
    
    func getConfirmationForVPNActivationPolicyChange(to policy: VPNActivationOverWiFiPolicy) {
        if policy == .activeOnAllNetworks {
            presentRemoveAllTrustedNetworksConfirmationPopup { [weak self] didConfirm in
                self?.dismissPopup()
                guard let strongSelf = self, didConfirm else {
                    return
                }
                
                strongSelf.selectedVPNActivationPolicy = .activeOnAllNetworks
                strongSelf.updateTunnelOnDemandRules(forOption: .anySSID, trustedNetworkNames: [])
            }
        } else {
            selectedVPNActivationPolicy = policy
            let trustedNetworkNames = trustedNetworks.map { $0.name }
            updateTunnelOnDemandRules(forOption: .exceptSpecificSSIDs, trustedNetworkNames: trustedNetworkNames)
        }
    }
    
    func removeTrustedNetwork(_ networkName: String) {
        guard let tunnelMgr = wireGuardManager.tunnelsManager,
              let tunnel = tunnelMgr.tunnelInOperation(),
              let tunnelConfig = tunnel.tunnelConfiguration else {
            return
        }
        
        let model = ActivateOnDemandViewModel(tunnel: tunnel)
        if let index = model.selectedSSIDs.firstIndex(where: { $0.lowercased() == networkName.lowercased() }) {
            model.selectedSSIDs.remove(at: index)
        }
        
        let onDemandOption = model.toOnDemandOption()
        tunnelMgr.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfig, onDemandOption: onDemandOption) { [weak self] error in
            guard let strongSelf = self,
                  error == nil else {
                let errorText = NSLocalizedString(
                    "Something went wrong while removing '%@' as a trusted network. Please try again.",
                    comment: "Trusted networks setup screen remove trusted network error")
                self?.presentAlertWith(
                    title: .errorText,
                    description: String(format: errorText, arguments: [networkName])
                )
                return
            }
            strongSelf.getTrustedNetworks()
        }
    }
    
    func presentAddTrustedNetworkPopup() {
        NEHotspotNetwork.fetchCurrent { [weak self] hotspotNetwork in
            guard let strongSelf = self else { return }
            guard let network = hotspotNetwork else {
                DispatchQueue.main.async {
                    let iswifi = WiFiSettingsVM.isCurrentlyOnWiFi()
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
                strongSelf.presentAddTrustedNetworkPopup(for: network.ssid)
            }
        }
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
    
    @objc private func onAppBecameActive() {
        guard let networkName = pendingTrustedNetworkName else { return }
        // User returned from iOS Settings — re-check whether they selected the DoT profile.
        if securityCenter.isDoTVerifiedActive {
            pendingTrustedNetworkName = nil
            commitTrustedNetwork(networkName)
            return
        }
        NEDNSSettingsManager.shared().loadFromPreferences { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingTrustedNetworkName = nil
                if NEDNSSettingsManager.shared().isEnabled {
                    // Profile is now selected — commit the trusted network silently.
                    self.commitTrustedNetwork(networkName)
                }
                // If still not selected, do nothing — the user chose not to select it.
            }
        }
    }

    private func setupWireGuardManager() {
        wireGuardManager.onTunnelsManagerReady = { [weak self] tunnelManager in
            guard let strongSelf = self else { return }
            strongSelf.selectedVPNProfile = tunnelManager.tunnelInOperation()
            strongSelf.getTrustedNetworks()
        }
        wireGuardManager.initWGClient()
    }
    
    private func getTrustedNetworks() {
        guard let tunnel = wireGuardManager.tunnelsManager?.tunnelInOperation() else {
            return
        }

        trustedNetworks.removeAll()
        let model = ActivateOnDemandViewModel(tunnel: tunnel)
        trustedNetworks = model.selectedSSIDs.map { TrustedNetwork(name: $0) }

        // Keep the policy picker in sync with the actual tunnel state.
        selectedVPNActivationPolicy = trustedNetworks.isEmpty ? .activeOnAllNetworks : .offOnTrustedNetworks
    }
    
    private func presentRemoveAllTrustedNetworksConfirmationPopup(completion: @escaping (Bool) -> Void) {
        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("Active on all networks", comment: "VPN active on all wifi networks title"),
            description: NSLocalizedString(
                "This will remove all trusted networks. You can add them again any time.",
                comment: "Wifi network settings screen remove all trusted networks confirmation popup description"
            ),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Switch & Remove", comment: "Wifi network settings screen remove all trusted networks button title"),
                    titleColor: .ember,
                    onTap: {
                        completion(true)
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                    onTap: {
                        completion(false)
                    }
                )
            ],
            buttonsAlignment: .vertical
        )
        presentPopup(with: popupConfiguration)
    }
    
    private func presentAddTrustedNetworkPopup(for networkName: String) {
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
                        self.dismissPopup()
                        self.updateTunnelOnDemandRules(for: networkName)
                    }
                )
            ]
        )
        presentPopup(with: popupConfiguration)
    }
    
    private func updateTunnelOnDemandRules(for networkName: String) {
        // Before committing a trusted-network rule (which lets the VPN go down on that
        // network), verify the DoT profile is selected in iOS Settings. Without it,
        // DNS will be unprotected whenever the tunnel is suppressed.
        checkDoTProfileSelectedThenSave(networkName: networkName)
    }

    private func checkDoTProfileSelectedThenSave(networkName: String) {
        // Prefer the verified probe result: `doDNSCheck` resolves a unique host and only
        // sees `DNS_CHECK_IP` when iOS is routing DNS through the Glacier DoT profile.
        // Fall back to `NEDNSSettingsManager.isEnabled`, which can be stale relative to
        // the user's selection in iOS Settings.
        if securityCenter.isDoTVerifiedActive {
            commitTrustedNetwork(networkName)
            return
        }
        NEDNSSettingsManager.shared().loadFromPreferences { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if NEDNSSettingsManager.shared().isEnabled {
                    self.commitTrustedNetwork(networkName)
                } else {
                    self.presentDoTWarningPopup(for: networkName)
                }
            }
        }
    }

    private func presentDoTWarningPopup(for networkName: String) {
        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString(
                "DNS Protection Required",
                comment: "Trusted network DNS warning popup title"
            ),
            description: NSLocalizedString(
                "When your VPN turns off on this trusted network, DNS protection requires our profile to be selected in iOS Settings.\n\nIn Settings page, navigate to:\n\nGeneral →\nVPN & Device Management →\nDNS →\n\nThen select Glacier.",
                comment: "Trusted network DNS warning popup description"
            ),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Add Anyway", comment: "Add trusted network anyway button"),
                    onTap: {
                        self.dismissPopup()
                        self.commitTrustedNetwork(networkName)
                    }
                ),
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Open Settings", comment: "Open settings button title"),
                    onTap: {
                        self.dismissPopup()
                        // Save the pending network name so we can re-check on return.
                        self.pendingTrustedNetworkName = networkName
                        guard let url = URL(string: UIApplication.settingsRootURL) else { return }
                        UIApplication.shared.open(url)
                    }
                )
            ]
        )
        presentPopup(with: popupConfiguration)
    }

    private func commitTrustedNetwork(_ networkName: String) {
        let errorText = NSLocalizedString(
            "Something went wrong while adding '%@' as a trusted network. Please try again.",
            comment: "Wifi settings screen remove trusted network error")

        guard let tunnelMgr = wireGuardManager.tunnelsManager,
              let tunnel = tunnelMgr.tunnelInOperation(),
              let tunnelConfig = tunnel.tunnelConfiguration else {
            presentAlertWith(
                title: .errorText,
                description: String(format: errorText, arguments: [networkName])
            )
            return
        }

        let model = ActivateOnDemandViewModel(tunnel: tunnel)
        model.ssidOption = .exceptSpecificSSIDs

        // SSID exceptions only take effect when WiFi on-demand is active.
        // If it wasn't already enabled, turn it on so the exception isn't silently dropped.
        if !model.isWiFiInterfaceEnabled {
            model.isWiFiInterfaceEnabled = true
        }

        guard !model.selectedSSIDs.contains(networkName) else {
            let text = NSLocalizedString(
                "'%@' is already added as a trusted network.",
                comment: "Wifi setup screen network is already added as trusted network"
            )
            presentAlertWith(title: nil, description: String(format: text, arguments: [networkName]))
            return
        }

        model.selectedSSIDs.append(networkName)

        let onDemandOption = model.toOnDemandOption()
        tunnelMgr.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfig, onDemandOption: onDemandOption) { [weak self] error in
            guard let strongSelf = self,
                  error == nil else {
                self?.presentAlertWith(
                    title: .errorText,
                    description: String(format: errorText, arguments: [networkName])
                )
                return
            }
            strongSelf.getTrustedNetworks()
            // The trusted network will suppress the VPN tunnel on this network,
            // so DoT must be active to keep DNS protected. Ensure it is enabled
            // now — this also self-heals existing users whose DoT isEnabled flag
            // was never set to true before this logic existed.
            strongSelf.dnsController.ensureEnabledForVPN(
                urlProvider: { [weak strongSelf] callback in
                    strongSelf?.securityCenter.getDNSProfile { profile in
                        callback(WiFiSettingsVM.buildDoTURL(from: profile))
                    }
                },
                completion: { _ in }
            )
        }
    }

    private static func buildDoTURL(from profile: String?) -> String? {
        guard let profile else { return nil }
        guard !profile.hasPrefix("tls://"), profile.contains(SecurityCenter.DNS_BACKUP) else {
            return profile
        }
        let deviceID = DnsOverTlsController.shared.shortDeviceID(length: 12)
        if deviceID.hasSuffix("-unknown") { return "tls://\(profile)" }
        return "tls://\(deviceID)-\(profile)"
    }
    
    private func updateTunnelOnDemandRules(forOption: ActivateOnDemandViewModel.OnDemandSSIDOption, trustedNetworkNames: [String]) {
        guard let tunnelMgr = wireGuardManager.tunnelsManager,
              let tunnel = tunnelMgr.tunnelInOperation(),
              let tunnelConfig = tunnel.tunnelConfiguration else {
            return
        }
        
        let model = ActivateOnDemandViewModel(tunnel: tunnel)
        
        guard model.ssidOption != forOption else {
            return
        }
        
        if case .anySSID = forOption {
            model.ssidOption = .anySSID
            model.selectedSSIDs.removeAll()
        } else if case .exceptSpecificSSIDs = forOption {
            model.ssidOption = .exceptSpecificSSIDs
            model.selectedSSIDs = trustedNetworkNames
        }
        
        let onDemandOption = model.toOnDemandOption()
        tunnelMgr.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfig, onDemandOption: onDemandOption) { [weak self] error in
            guard let strongSelf = self,
                  error == nil else {
                self?.presentAlertWith(title: .errorText, description: error?.localizedDescription)
                return
            }
            
            strongSelf.getTrustedNetworks()
        }
    }
}
