//
//  VPNSettingsViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 21/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import UIKit
import Foundation
import NetworkExtension

/**
 VPNLocation represents one of the available VPN server locations.
 */
struct VPNLocation: Equatable {
    let displayName: String
    let regionCode: String
}

/**
 VPNSettingsViewModel defines requirements for VPN settings screen view models.
 */
protocol VPNSettingsViewModel: GlacierViewModelWithRootCoordinator {

    var isConnectedToVPN: Bool { get set }
    var isVPNActive: Bool { get }
    var vpnConnectionStatus: String { get }
    var vpnConnectionStatusDetails: String { get }
    var vpnActivationStatusOverWifiNetwork: String { get }
    var shouldActivateOnCellular: Bool { get set }
    var shouldActivateOnWiFi: Bool { get set }
    var vpnLocations: [VPNLocation] { get }
    var selectedLocation: VPNLocation? { get set }

    init(rootCoordinator: any GlacierRootCoordinator)

    func initialize()
    func refreshNetworkActivationState()
    func presentWiFiSettingsScreen()
}

/**
 VPNSettingsVM defines data/state and business logic for VPN settings screen UI/UX and functional flows.
 */
final class VPNSettingsVM: VPNSettingsViewModel, ObservableObject {

    // MARK: - Public properties

    @Published var isConnectedToVPN: Bool = false {
        didSet {
            guard !isVPNSettingsUpdateInProgress else { return }
            if isConnectedToVPN {
                guard hasVPNConfiguration() else {
                    if needsFirstTimeVPNSetup { hasPendingFirstTimeVPNSetup = true }
                    presentAddVPNConfirmationPrompt()
                    return
                }

                if needsFirstTimeVPNSetup {
                    enableVPNWithWiFiOnDemandAndPresentSetup()
                } else {
                    beginVPNOperation()
                    toggleVPNConnection(true)
                }
            } else {
                beginVPNOperation()
                toggleVPNConnection(false)
            }
        }
    }

    @Published var shouldActivateOnCellular: Bool = false {
        didSet {
            guard !isVPNSettingsUpdateInProgress else { return }
            if shouldActivateOnCellular && !oldValue {
                presentCellularVPNConfirmation()
            } else {
                beginVPNOperation()
                updateVPNActivation(for: .cellular, isEnabled: shouldActivateOnCellular)
            }
        }
    }

    @Published var shouldActivateOnWiFi: Bool = false {
        didSet {
            guard !isVPNSettingsUpdateInProgress else { return }
            beginVPNOperation()
            updateVPNActivation(for: .wiFi, isEnabled: shouldActivateOnWiFi)
        }
    }

    @Published var isVPNActive: Bool = false

    @Published var selectedLocation: VPNLocation? {
        didSet {
            guard !isVPNSettingsUpdateInProgress, let location = selectedLocation else { return }
            handleLocationSelection(location)
        }
    }

    @Published private(set) var vpnConnectionStatus: String = ""
    @Published private(set) var vpnConnectionStatusDetails: String = ""
    @Published private(set) var vpnActivationStatusOverWifiNetwork: String = ""

    let vpnLocations: [VPNLocation] = VPNSettingsVM.availableLocations

    let rootCoordinator: any GlacierRootCoordinator

    // MARK: - Private properties

    static let availableLocations: [VPNLocation] = [
        VPNLocation(displayName: "N. Virginia",   regionCode: "us-east-1"),
        VPNLocation(displayName: "Ohio",          regionCode: "us-east-2"),
        VPNLocation(displayName: "N. California", regionCode: "us-west-1"),
        VPNLocation(displayName: "Oregon",        regionCode: "us-west-2"),
    ]

    private var currentInstalledRegion: String {
        get { UserDefaults.standard.string(forKey: "glacier_vpn_installed_region") ?? "us-east-1" }
        set { UserDefaults.standard.set(newValue, forKey: "glacier_vpn_installed_region") }
    }

    private func location(forRegion code: String) -> VPNLocation? {
        VPNSettingsVM.availableLocations.first { $0.regionCode == code }
    }

    private let securityCenter: SecurityCenter = SecurityCenter()
    private let dnsController: DnsOverTlsController = DnsOverTlsController.shared
    private let wireGuardManager: WireGuardManager = WireGuardManager.shared()

    private var shouldToggleVPNConnection: Bool = false
    private var onDemandViewModel: ActivateOnDemandViewModel?
    private var hasPendingRequestForVPNConnection = false
    private var hasPendingFirstTimeVPNSetup = false
    private var trustedNetworkNames: [String] = []
    private var isVPNSettingsUpdateInProgress: Bool = false
    private var isRegionSwitchInProgress: Bool = false

    // Spinner state for VPN connection / on-demand toggles. The underlying NetworkExtension
    // calls take 1–5s to settle and previously left the screen with no visual feedback.
    private var isVPNOperationInProgress: Bool = false
    private var hasSeenStatusChangeForCurrentVPNOperation: Bool = false
    private var vpnOperationTimeoutWorkItem: DispatchWorkItem?

    // MARK: - Initializer

    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public methods

    func initialize() {
        registerForNotifications()
        setupWireGuardManager()

        refreshNetworkActivationState()
        setTrustedNetworksStatus()
    }

    func refreshNetworkActivationState() {
        guard let tunnel = wireGuardManager.tunnelsManager?.tunnelInOperation() else {
            isVPNSettingsUpdateInProgress = true

            onDemandViewModel = nil

            isConnectedToVPN = false
            isVPNActive = false
            setVPNActivationStatus(.inactive)

            shouldActivateOnCellular = false
            shouldActivateOnWiFi = false

            trustedNetworkNames.removeAll()
            setTrustedNetworksStatus()

            isVPNSettingsUpdateInProgress = false
            return
        }

        isVPNSettingsUpdateInProgress = true

        let model = ActivateOnDemandViewModel(tunnel: tunnel)
        onDemandViewModel = model

        isConnectedToVPN = true
        isVPNActive = tunnel.status == .active
        setVPNActivationStatus(tunnel.status)

        shouldActivateOnCellular = model.isNonWiFiInterfaceEnabled
        shouldActivateOnWiFi = model.isWiFiInterfaceEnabled

        trustedNetworkNames = model.selectedSSIDs
        setTrustedNetworksStatus()

        isVPNSettingsUpdateInProgress = false
    }

    func presentWiFiSettingsScreen() {
        presentScreen(.wifiSettings)
    }

    // MARK: - Private methods

    private func registerForNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onVPNStatusChange),
            name: .NEVPNStatusDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAppBecameActive),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    private func setupWireGuardManager() {
        if let tunnelManager = wireGuardManager.tunnelsManager {
            // TunnelsManager is already ready (singleton initialized at app startup)
            tunnelManager.activationDelegate = self
            tunnelManager.reloadDelegate = self
            isVPNSettingsUpdateInProgress = true
            selectedLocation = resolveInstalledLocation(from: tunnelManager)
            isVPNSettingsUpdateInProgress = false
        } else {
            wireGuardManager.onTunnelsManagerReady = { [weak self] tunnelManager in
                guard let strongSelf = self else { return }
                tunnelManager.activationDelegate = strongSelf
                tunnelManager.reloadDelegate = strongSelf
                strongSelf.isVPNSettingsUpdateInProgress = true
                strongSelf.selectedLocation = strongSelf.resolveInstalledLocation(from: tunnelManager)
                strongSelf.isVPNSettingsUpdateInProgress = false
            }
            wireGuardManager.initWGClient()
        }
    }

    /// Determines the installed VPN location by first checking the currently-running tunnel
    /// (the true source of truth), then falling back to UserDefaults, then any installed
    /// known-region tunnel. Also keeps UserDefaults in sync.
    ///
    /// Using tunnel(at: 0) was wrong because tunnels are sorted alphabetically, so N.Virginia
    /// (us-east-1) was always returned even when Oregon (us-west-2) was the active region,
    /// corrupting UserDefaults and breaking disconnect from HomeScreen.
    private func resolveInstalledLocation(from tunnelManager: TunnelsManager) -> VPNLocation? {
        // Prefer the currently-operating tunnel as the source of truth.
        if let operatingTunnel = tunnelManager.tunnelInOperation(),
           let match = VPNSettingsVM.availableLocations.first(where: { $0.regionCode == operatingTunnel.name }) {
            currentInstalledRegion = match.regionCode
            return match
        }
        // Fall back to UserDefaults if that tunnel still exists.
        if tunnelManager.tunnel(named: currentInstalledRegion) != nil {
            return location(forRegion: currentInstalledRegion)
        }
        // Last resort: find any installed known-region tunnel.
        for loc in VPNSettingsVM.availableLocations {
            if tunnelManager.tunnel(named: loc.regionCode) != nil {
                currentInstalledRegion = loc.regionCode
                return loc
            }
        }
        return nil
    }

    private func connectToVPNIfRequired() {
        if hasPendingFirstTimeVPNSetup {
            hasPendingFirstTimeVPNSetup = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.enableVPNWithWiFiOnDemandAndPresentSetup()
            }
        } else {
            guard hasPendingRequestForVPNConnection else { return }
            hasPendingRequestForVPNConnection = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.toggleVPNConnection(true)
            }
        }
    }

    private func activateVPN(_ vpn: TunnelContainer) {
        guard let tunnelMgr = wireGuardManager.tunnelsManager,
              let tunnel = tunnelMgr.tunnel(named: vpn.name),
              (tunnel.status != .active && tunnel.status != .activating && tunnel.status != .restarting) else {
            return
        }

        let onDemandOption = ActivateOnDemandViewModel(tunnel: tunnel).toOnDemandOption()

        let activate = {
            if case .off = onDemandOption {
                tunnelMgr.startActivation(of: tunnel)
            } else {
                tunnelMgr.setOnDemandEnabled(true, on: tunnel, completionHandler: { _ in
                    tunnelMgr.startActivation(of: tunnel)
                })
            }
        }

        if let tunnelInOperation = tunnelMgr.tunnelInOperation(), tunnelInOperation.name != tunnel.name {
            // A different tunnel is running — deactivate it first.
            tunnelMgr.setOnDemandEnabled(false, on: tunnelInOperation, completionHandler: { _ in
                tunnelMgr.startDeactivation(of: tunnelInOperation)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { activate() }
            })
        } else {
            // No other tunnel running (or tunnelInOperation is already this tunnel).
            activate()
        }
    }

    private func handleLocationSelection(_ location: VPNLocation) {
        guard hasVPNConfiguration() else {
            // No config yet — the isConnectedToVPN toggle handles first-time setup
            return
        }

        if location.regionCode == currentInstalledRegion {
            // Same region: activate the existing tunnel
            guard let tunnelMgr = wireGuardManager.tunnelsManager,
                  let tunnel = tunnelMgr.tunnel(named: location.regionCode) else { return }
            activateVPN(tunnel)
            return
        }

        // Show the spinner immediately and mark the switch in-progress so that
        // onVPNStatusChange doesn't dismiss it when the tunnel deactivates.
        isRegionSwitchInProgress = true
        presentProgressIndicator()

        // The location picker is only visible while VPN is connected, so the active
        // WireGuard tunnel is routing all device traffic. queryForProfiles makes an
        // outbound HTTP request that would travel through the tunnel and time out
        // because the profile endpoint isn't reachable from the WireGuard server.
        // Deactivate the tunnel first; once it's fully down the OS routes traffic
        // normally and the request succeeds.
        if let tunnelMgr = wireGuardManager.tunnelsManager,
           let activeTunnel = tunnelMgr.tunnelInOperation() {
            // Capture on-demand rules before disabling them so they can be applied
            // to the new region's tunnel after the profile is installed.
            let preservedOnDemand = ActivateOnDemandViewModel(tunnel: activeTunnel).toOnDemandOption()

            if activeTunnel.status == .inactive {
                // Tunnel is already down (e.g. on a trusted network) — skip deactivation
                // and go straight to fetching the profile. Still disable on-demand first
                // so iOS can't reconnect during the download/apply.
                tunnelMgr.setOnDemandEnabled(false, on: activeTunnel) { [weak self] _ in
                    self?.fetchAndApplyProfile(for: location, onDemandOption: preservedOnDemand)
                }
            } else {
                activeTunnel.onDeactivated = { [weak self] in
                    self?.fetchAndApplyProfile(for: location, onDemandOption: preservedOnDemand)
                }
                tunnelMgr.setOnDemandEnabled(false, on: activeTunnel) { _ in
                    tunnelMgr.startDeactivation(of: activeTunnel)
                }
            }
        } else {
            fetchAndApplyProfile(for: location, onDemandOption: .off)
        }
    }

    private func fetchAndApplyProfile(for location: VPNLocation, onDemandOption: ActivateOnDemandOption = .off) {
        // Spinner is already showing from handleLocationSelection.
        wireGuardManager.queryForProfiles(region: location.regionCode, onDemandOption: onDemandOption) { [weak self] success in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isRegionSwitchInProgress = false
                self.dismissProgressIndicator()
                if success {
                    self.currentInstalledRegion = location.regionCode
                    // Reconnect the tunnel with the preserved on-demand rules.
                    if let tunnelMgr = self.wireGuardManager.tunnelsManager,
                       let newTunnel = tunnelMgr.tunnel(named: location.regionCode) {
                        self.activateVPN(newTunnel)
                    }
                } else {
                    // Revert selection to the currently installed region
                    self.isVPNSettingsUpdateInProgress = true
                    self.selectedLocation = self.location(forRegion: self.currentInstalledRegion)
                    self.isVPNSettingsUpdateInProgress = false
                    self.presentAlertWith(
                        title: .errorText,
                        description: NSLocalizedString(
                            "Something went wrong while switching VPN location. Please try again.",
                            comment: "VPN location switch error"
                        )
                    )
                }
            }
        }
    }

    private func presentCellularVPNConfirmation() {
        let configuration = PopupConfiguration(
            title: NSLocalizedString("Are you sure?", comment: "Cellular VPN confirmation popup title"),
            description: NSLocalizedString(
                "Glacier recommends leaving VPN off while on cellular for best performance.",
                comment: "Cellular VPN confirmation popup description"
            ),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                    onTap: {
                        self.dismissPopup()
                        self.isVPNSettingsUpdateInProgress = true
                        self.shouldActivateOnCellular = false
                        self.isVPNSettingsUpdateInProgress = false
                    }
                ),
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Enable", comment: "Enable cellular VPN button title"),
                    onTap: {
                        self.dismissPopup()
                        self.beginVPNOperation()
                        self.updateVPNActivation(for: .cellular, isEnabled: true)
                    }
                )
            ]
        )
        presentPopup(with: configuration)
    }

    private func updateVPNActivation(for interface: NEOnDemandRuleInterfaceType, isEnabled: Bool) {
        guard let tunnelManager = wireGuardManager.tunnelsManager,
              let tunnel = tunnelManager.tunnelInOperation(),
              let tunnelConfig = tunnel.tunnelConfiguration else {
            endVPNOperation()
            return
        }

        // Always read a fresh model from the tunnel so we never write stale SSID lists.
        let model = ActivateOnDemandViewModel(tunnel: tunnel)

        switch interface {
        case .cellular:
            guard model.isNonWiFiInterfaceEnabled != isEnabled else {
                endVPNOperation()
                return
            }
            model.isNonWiFiInterfaceEnabled = isEnabled

        case .wiFi:
            guard model.isWiFiInterfaceEnabled != isEnabled else {
                endVPNOperation()
                return
            }
            model.isWiFiInterfaceEnabled = isEnabled
        default:
            endVPNOperation()
            return
        }

        let onDemandOption = model.toOnDemandOption()
        tunnelManager.modify(
            tunnel: tunnel,
            tunnelConfiguration: tunnelConfig,
            onDemandOption: onDemandOption
        ) { [weak self] _ in
            // Both interfaces are now off — deactivate the tunnel so it no longer
            // appears in the iOS status bar.
            if case .off = onDemandOption {
                tunnelManager.startDeactivation(of: tunnel)
            }
            self?.refreshNetworkActivationState()
            self?.dismissVPNOperationIfQuiescent()
        }
    }

    @objc func onVPNStatusChange() {
        // Don't dismiss the spinner during a region switch — the tunnel deactivation
        // is intentional and fetchAndApplyProfile will dismiss it when done.
        if isRegionSwitchInProgress {
            // No-op — fetchAndApplyProfile owns dismissal.
        } else if isVPNOperationInProgress {
            // Keep the spinner up while the tunnel is transitioning; dismiss once it
            // settles at a stable state (active or fully inactive).
            hasSeenStatusChangeForCurrentVPNOperation = true
            let status = wireGuardManager.tunnelsManager?.tunnelInOperation()?.status ?? .inactive
            if status == .active || status == .inactive {
                endVPNOperation()
            }
        } else {
            dismissProgressIndicator()
        }
        refreshNetworkActivationState()
    }

    /// Shows the progress overlay for a VPN connection or on-demand toggle and arms a
    /// safety timeout so the spinner can never get stuck.
    private func beginVPNOperation() {
        isVPNOperationInProgress = true
        hasSeenStatusChangeForCurrentVPNOperation = false
        presentProgressIndicator()
        vpnOperationTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.endVPNOperation()
        }
        vpnOperationTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: workItem)
    }

    private func endVPNOperation() {
        vpnOperationTimeoutWorkItem?.cancel()
        vpnOperationTimeoutWorkItem = nil
        isVPNOperationInProgress = false
        hasSeenStatusChangeForCurrentVPNOperation = false
        dismissProgressIndicator()
    }

    /// Dismisses the spinner if the underlying preferences-save chain has completed but
    /// no tunnel status transition followed (e.g. toggling cellular on-demand while on
    /// Wi-Fi — config saved, no tunnel state change). The 1.5s grace window lets any
    /// genuine NEVPNStatusDidChange arrive first; if it does, the status handler keeps
    /// the spinner up until the tunnel reaches a stable state.
    private func dismissVPNOperationIfQuiescent() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard self.isVPNOperationInProgress else { return }
            guard !self.hasSeenStatusChangeForCurrentVPNOperation else { return }
            self.endVPNOperation()
        }
    }

    private func setVPNActivationStatus(_ status:TunnelStatus) {
        // Setting VPN status
        switch status {
        case .inactive:
            vpnConnectionStatus = NSLocalizedString("Not in Use", comment: "VPN settings screen not in use status")
        case .activating:
            vpnConnectionStatus = NSLocalizedString("In Progress", comment: "VPN settings screen in progress status")
        case .active:
            vpnConnectionStatus = NSLocalizedString("In Use", comment: "VPN settings screen in use status")
        case .deactivating:
            vpnConnectionStatus = NSLocalizedString("Not in Use", comment: "VPN settings screen inactive status")
        case .reasserting:
            vpnConnectionStatus =  NSLocalizedString("In Progress", comment: "VPN settings screen in progress status")
        case .restarting:
            vpnConnectionStatus = NSLocalizedString("Restarting", comment: "VPN settings screen in restarting status")
        case .waiting:
            vpnConnectionStatus = NSLocalizedString("Transition in Progress", comment: "VPN settings screen in transition in progress status")
        }

        // Setting reason for VPN current status
        if status == .active {
            vpnConnectionStatusDetails = NSLocalizedString("Your VPN is currently activated.", comment: "VPN settings screen VPN currently activated")
        } else if status == .inactive, wireGuardManager.tunnelsManager?.hasActiveOnDemandTunnel() == true {
            let curssid = TunnelsManager.retrieveCurrentSSID()
            if self.onDemandViewModel?.isWiFiInterfaceEnabled == false, curssid != nil {
                vpnConnectionStatusDetails = NSLocalizedString("Not active — you're on Wi-Fi", comment: "VPN settings screen inactive due to wifi network")
            } else if self.onDemandViewModel?.isNonWiFiInterfaceEnabled == false, curssid == nil {
                vpnConnectionStatusDetails = NSLocalizedString("Not active — you're on cellular data", comment: "VPN settings screen inactive due to cellular network")
            } else if self.onDemandViewModel?.isWiFiInterfaceEnabled == true, let ssid = curssid, self.onDemandViewModel?.selectedSSIDs.contains(ssid) == true {
                let statusText = NSLocalizedString("Not active — you're on trusted network: %@", comment: "VPN settings screen inactive due to trusted network")
                vpnConnectionStatusDetails = String(format: statusText, arguments: [ssid])
            }
        }
    }

    private func setTrustedNetworksStatus() {
        if trustedNetworkNames.isEmpty {
            vpnActivationStatusOverWifiNetwork = NSLocalizedString(
                "Active on all networks.",
                comment: "VPN settings screen active on all wifi networks"
            )
        } else {
            let statusText = NSLocalizedString(
                "Disabled on %@ trusted network(s)",
                comment: "VPN settings screen disaled on trusted networks"
            )
            vpnActivationStatusOverWifiNetwork = String(format: statusText, arguments: ["\(trustedNetworkNames.count)"])
        }
    }

    @objc private func onAppBecameActive() {
        connectToVPNIfRequired()
    }
}

// MARK: - VPN configuration checkup, setup and connection toggle

extension VPNSettingsVM {

    private func toggleVPNConnection(_ shouldConnect: Bool) {
        let isConnected = securityCenter.isVpnEnabled()
        guard isConnected != shouldConnect,
              let tunnelsManager = wireGuardManager.tunnelsManager,
              let tunnel = tunnelsManager.tunnel(named: currentInstalledRegion) else {
            endVPNOperation()
            return
        }

        tunnelsManager.activationDelegate = self
        if shouldConnect {
            // Ensure the DoT profile is fully enabled before the tunnel comes up so that
            // DNS remains protected if on-demand rules later suppress the tunnel.
            dnsController.ensureEnabledForVPN(urlProvider: { [weak self] callback in
                self?.securityCenter.getDNSProfile { profile in
                    callback(VPNSettingsVM.buildDoTURL(from: profile))
                }
            }) { _ in
                // Proceed with tunnel activation regardless of DoT result —
                // the tunnel's own DNS proxy protects the user while it is running.
            }
            // Only re-enable on-demand if the tunnel has actual rules configured.
            let onDemandOption = ActivateOnDemandViewModel(tunnel: tunnel).toOnDemandOption()
            if case .off = onDemandOption {
                tunnelsManager.startActivation(of: tunnel)
                dismissVPNOperationIfQuiescent()
            } else {
                tunnelsManager.setOnDemandEnabled(true, on: tunnel, completionHandler: { [weak self] _ in
                    tunnelsManager.startActivation(of: tunnel)
                    self?.dismissVPNOperationIfQuiescent()
                })
            }
        } else {
            // Disable on-demand first so iOS cannot auto-reconnect after deactivation.
            tunnelsManager.setOnDemandEnabled(false, on: tunnel, completionHandler: { [weak self] _ in
                tunnelsManager.startDeactivation(of: tunnel)
                // A tunnel suppressed by on-demand is already .inactive, so startDeactivation is
                // a no-op and no NEVPNStatusDidChange / tunnelDeactivating follows. Recompute the
                // toggle state explicitly so isConnectedToVPN reflects that on-demand is now off
                // instead of snapping back ON.
                self?.refreshNetworkActivationState()
                self?.dismissVPNOperationIfQuiescent()
            })
        }
    }

    private var needsFirstTimeVPNSetup: Bool {
        let hasCompleted: Bool = UserDefaultsService.shared.get(for: \.hasCompletedVPNFirstTimeSetup) ?? false
        if hasCompleted { return false }
        guard let tunnelMgr = wireGuardManager.tunnelsManager,
              let tunnel = tunnelMgr.tunnel(named: currentInstalledRegion) else {
            return true
        }
        if case .off = ActivateOnDemandViewModel(tunnel: tunnel).toOnDemandOption() {
            return true
        }
        // Tunnel already has on-demand rules → user is already set up; mark complete.
        UserDefaultsService.shared.set(true, for: \.hasCompletedVPNFirstTimeSetup)
        return false
    }

    private func enableVPNWithWiFiOnDemandAndPresentSetup() {
        guard let tunnelMgr = wireGuardManager.tunnelsManager,
              let tunnel = tunnelMgr.tunnel(named: currentInstalledRegion),
              let tunnelConfig = tunnel.tunnelConfiguration else {
            toggleVPNConnection(true)
            return
        }

        let model = ActivateOnDemandViewModel(tunnel: tunnel)
        model.isWiFiInterfaceEnabled = true
        model.isNonWiFiInterfaceEnabled = false

        let onDemandOption = model.toOnDemandOption()
        tunnelMgr.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfig, onDemandOption: onDemandOption) { [weak self] _ in
            guard let self else { return }
            dnsController.ensureEnabledForVPN(urlProvider: { [weak self] callback in
                self?.securityCenter.getDNSProfile { profile in
                    callback(VPNSettingsVM.buildDoTURL(from: profile))
                }
            }) { _ in }
            tunnelMgr.setOnDemandEnabled(true, on: tunnel) { _ in
                tunnelMgr.startActivation(of: tunnel)
            }
        }

        presentScreen(.cellularSetup)
    }

    private func hasVPNConfiguration() -> Bool {
        guard let manager = wireGuardManager.tunnelsManager else {
            return false
        }
        return manager.tunnel(named: currentInstalledRegion) != nil
    }

    private func presentAddVPNConfirmationPrompt() {
        presentProgressIndicator()

        wireGuardManager.queryForProfiles { [weak self] didLoadProfiles in
            guard let strongSelf = self else { return }
            DispatchQueue.main.async {
                strongSelf.dismissProgressIndicator()

                guard didLoadProfiles else {
                    strongSelf.presentAlertWith(
                        title: .errorText,
                        description:
                            NSLocalizedString(
                                "Something went wrong while adding VPN configuration. Please try again.",
                                comment: "VPN setup screen VPN configuration error"
                            )
                    )
                    return
                }

                strongSelf.hasPendingRequestForVPNConnection = true
                strongSelf.currentInstalledRegion = "us-east-1"
                strongSelf.isVPNSettingsUpdateInProgress = true
                strongSelf.selectedLocation = strongSelf.location(forRegion: "us-east-1")
                strongSelf.isVPNSettingsUpdateInProgress = false
            }
        }
    }
}

// MARK: - DNS connection management

extension VPNSettingsVM {
    private func disconnectFromDNSIfNeeded() {
        var dnsConfiguration = dnsController.loadSavedConfiguration()
        guard let url = dnsConfiguration.urlString,
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        dnsConfiguration.isEnabled = false
        dnsController.apply(configuration: dnsConfiguration) { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.securityCenter.doDNSCheck()
        }
    }

    /// Normalises a raw DNS profile string returned by the server into a tls:// URL,
    /// prepending a device-specific sub-identifier when the backup host is used.
    static func buildDoTURL(from profile: String?) -> String? {
        guard let profile else { return nil }
        guard !profile.hasPrefix("tls://"), profile.contains(SecurityCenter.DNS_BACKUP) else {
            return profile
        }
        let controller = DnsOverTlsController.shared
        let deviceID = controller.shortDeviceID(length: 12)
        if deviceID.hasSuffix("-unknown") {
            return "tls://\(profile)"
        }
        return "tls://\(deviceID)-\(profile)"
    }
}

// MARK: - TunnelsManagerActivationDelegate methods

extension VPNSettingsVM: TunnelsManagerActivationDelegate {

    // StartTunnel wasn't called or failed
    func tunnelActivationAttemptFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationAttemptError) {}

    // StartTunnel succeeded
    func tunnelActivationAttemptSucceeded(tunnel: TunnelContainer) {}

    // Status changed to connected
    func tunnelActivationSucceeded(tunnel: TunnelContainer) {
        onVPNStatusChange()
    }

    // Status didn't change to connected
    func tunnelActivationFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationError) {
        onVPNStatusChange()
    }

    // Status changed to disconnected
    func tunnelDeactivating(tunnel: TunnelContainer) {
        onVPNStatusChange()
    }
}

// MARK: - TunnelsManagerStatusDelegate delegate methods

extension VPNSettingsVM: TunnelsManagerStatusDelegate {
    func reloadComplete() {
        refreshNetworkActivationState()
    }

    func statusUpdate(_ status: TunnelStatus) {
        isVPNActive = status == .active
        setVPNActivationStatus(status)
    }
}
