//
//  HomeViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI
import IOSSecuritySuite
import NetworkExtension
import WidgetKit

/**
 HomeViewModel defines requirements for the home screen view models.
 */
protocol HomeViewModel: GlacierViewModelWithRootCoordinator {
    
    var isScanningDevice: Bool { get set }
    var isFirstDeviceScanCompleted: Bool { get }
    
    var isUserDeviceSecured: Bool { get set }
    var isConnectButtonEnabled: Bool { get }
    
    var securityStatusText: String { get }
    var securityIssueText: String? { get }
    
    var isUpdatingBlockedTrackersCount: Bool { get }
    var blockedTrackersInfoText: String { get }
    
    var isRefreshingSecurityStatus: Bool { get }
    
    var connectionStatusText: String { get }
    var activeConnectionLabel: String? { get }
    var isConnectedToDNS: Bool { get }
    var isConnectedToVPN: Bool { get }
    
    var deviceSecuritySettingsStatus: [DeviceSecuritySetting] { get set }
    
    init(rootCoordinator: any GlacierRootCoordinator)
    
    func refreshStatus()
    func refreshDeviceSecurityStatus()
    func connectToSecuredNetwork()
    func disconnectFromSecuredNetwork()
    func presentDeviceSettings(for setting: DeviceSecuritySettingType)
    func presentVPNSettingsScreen()
}

/**
 HomeVM defines data/state and business for the home screen.
 */
final class HomeVM: HomeViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var isScanningDevice: Bool = false
    @Published var isFirstDeviceScanCompleted: Bool = false
    @Published var isUserDeviceSecured: Bool = false
    
    @Published private(set) var isConnectButtonEnabled: Bool = false
    
    @Published private(set) var securityStatusText: String = ""
    @Published private(set) var securityIssueText: String? = nil
    
    @Published private(set) var isUpdatingBlockedTrackersCount: Bool = true
    @Published private(set) var blockedTrackersInfoText: String = ""
    @Published private(set) var isRefreshingSecurityStatus: Bool = false
    
    @Published private(set) var connectionStatusText: String = ""
    @Published private(set) var activeConnectionLabel: String? = nil

    @Published private(set) var isConnectedToDNS: Bool = false
    @Published private(set) var isConnectedToVPN: Bool = false
    
    @Published var deviceSecuritySettingsStatus: [DeviceSecuritySetting] =
        DeviceSecuritySettingType.allCases.map { DeviceSecuritySetting(type: $0, isEnabled: false) }
    
    let rootCoordinator: any GlacierRootCoordinator
    
    // MARK: - Private properties
    
    private let securityCenter: SecurityCenter = SecurityCenter()
    private let dnsController: DnsOverTlsController = DnsOverTlsController.shared
    private let wireGuardManager: WireGuardManager = WireGuardManager.shared()
    private var numberOfBlockedTrackers: Int = 0
    
    private var currentInstalledRegion: String {
        UserDefaults.standard.string(forKey: "glacier_vpn_installed_region") ?? "us-east-1"
    }

    private var isGlacierDNSEnabledIniOSSettings = false
    private var hasPendingRequestForDNSConnection = false
    private var hasPendingRequestForVPNConnection = false
    private var hasPendingFirstTimeVPNSetup = false
    private var didUserTappedDNSConnectionButton: Bool = false
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        
        registerForNotifications()
        securityCenter.dnsStatusDelegate = self
        setupWireGuardManager()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public methods
    
    func refreshStatus() {
        scanDeviceForSecuritySettings()
        showBlockedTrackerAnalytics()
        securityCenter.doDNSCheck()
    }
    
    func refreshDeviceSecurityStatus() {
        refreshDeviceSecurityStatus(suppressScanAnimation: false)
    }

    private func refreshDeviceSecurityStatus(suppressScanAnimation: Bool) {
        if !suppressScanAnimation {
            isScanningDevice = true
        }
        checkSecuredConnectionStatus()
        // When called from dnsStatusUpdated (the only caller that passes
        // suppressScanAnimation: true), doDNSCheck just ran and the foreground
        // path already kicked off an analytics query — skip the redundant one
        // so the "Status loading" rectangle doesn't flash a second time.
        scanDeviceForSecurityIssues(skipAnalyticsRefresh: suppressScanAnimation)
    }
    
    func connectToSecuredNetwork() {
        presentSheet(.connectionTypeSelection)
    }
    
    /// Called by the iOS 16 widget deep link (glacierapp://vpn/toggle).
    /// Mirrors the AppIntent logic: disconnects if connected, or reconnects to the
    /// last chosen type if disconnected. Skips the VPN confirmation popup since the
    /// action is already an explicit user gesture on the widget.
    func handleWidgetToggle() {
        if isConnectedToVPN {
            toggleVPNConnection(false)
            toggleDNSConnection(false)
        } else if isConnectedToDNS {
            toggleDNSConnection(false)
        } else {
            let lastType = UserDefaults(suiteName: kGlacierGroup)?.string(forKey: kLastConnectionTypeKey) ?? SecuredConnectionType.dns.rawValue
            if lastType == SecuredConnectionType.vpn.rawValue {
                guard hasVPNConfiguration() else { return }
                recordLastConnectionType(.vpn)
                toggleVPNConnection(true)
            } else {
                guard hasDNSConfiguration() else { return }
                recordLastConnectionType(.dns)
                didUserTappedDNSConnectionButton = true
                toggleDNSConnection(true)
            }
        }
    }

    func disconnectFromSecuredNetwork() {
        if isConnectedToVPN {
            let popupConfiguration = PopupConfiguration(
                description: NSLocalizedString("Are you sure?", comment: "Home screen VPN disconnection confirmation"),
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
                        title: NSLocalizedString("Disconnect", comment: "Disconnect button title"),
                        titleColor: .ember,
                        onTap: {
                            self.dismissPopup()
                            self.toggleVPNConnection(false)
                            self.toggleDNSConnection(false)
                        }
                    )
                ]
            )
            presentPopup(with: popupConfiguration)
        } else if isConnectedToDNS {
            toggleDNSConnection(false)
        }
    }
    
    func presentDeviceSettings(for setting: DeviceSecuritySettingType) {
        let popupConfiguration = PopupConfiguration(
            title: setting.popupTitle,
            description: setting.popupDescription,
            descriptionAlignment: .leading,
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
                    title: NSLocalizedString("Open Settings", comment: "Open settings button title"),
                    onTap: {
                        self.dismissPopup()
                        
                        //guard let url = URL(string: UIApplication.openSettingsURLString),
                        guard let url = URL(string: UIApplication.settingsRootURL),
                              UIApplication.shared.canOpenURL(url) else {
                            return
                        }
                        UIApplication.shared.open(url)
                    }
                )
            ]
        )
        presentPopup(with: popupConfiguration)
    }
    
    func presentVPNSettingsScreen() {
        presentScreen(.vpnSettings)
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
            selector: #selector(onUserSelectedConnectionType(_:)),
            name: .userSelectedConnectionType,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onWidgetToggleRequested),
            name: .widgetVPNDNSToggleRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onWidgetDisconnectRequested),
            name: .widgetDisconnectRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onWidgetConnectRequested),
            name: .widgetConnectRequested,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAppBecameActive),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAccessTokenUpdated),
            name: .twilioAccessTokenUpdated,
            object: nil
        )

        registerForWidgetDarwinNotification()
    }

    /// Registers a Darwin (cross-process) notification observer so the widget's
    /// AppIntent can trigger a real NE toggle while the app is backgrounded.
    /// The widget cannot call NE APIs directly (permission denied), so it stores
    /// the intended action in UserDefaults and the app executes it here.
    private func registerForWidgetDarwinNotification() {
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let vm = Unmanaged<HomeVM>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { vm.executeWidgetRequestedAction() }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            callback,
            kWidgetDarwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }
    
    private func setupWireGuardManager() {
        if let tunnelManager = wireGuardManager.tunnelsManager {
            // TunnelsManager is already ready — skip redundant initWGClient call
            // to avoid concurrent NETunnelProviderManager.loadAllFromPreferences calls.
            tunnelManager.activationDelegate = self
            self.checkSecuredConnectionStatus()
        } else {
            wireGuardManager.onTunnelsManagerReady = { tunnelManager in
                tunnelManager.activationDelegate = self
                self.checkSecuredConnectionStatus()
            }
            wireGuardManager.initWGClient()
        }
    }
    
    private func checkSecuredConnectionStatus() {
        DispatchQueue.main.async {
            self.isConnectedToVPN = self.wireGuardManager.tunnelsManager?.tunnelInOperation() != nil
            self.isConnectedToDNS = self.isGlacierDNSEnabledIniOSSettings && self.dnsController.loadSavedConfiguration().isEnabled
            self.updateConnectionStatusText()
        }
    }
    
    private func markDeviceSercurityStatusRefreshAsCompleted() {
        if self.isScanningDevice {
            self.isScanningDevice = false
        }
        
        if !self.isFirstDeviceScanCompleted {
            self.isFirstDeviceScanCompleted = true
        }
    }
    
    private func scanDeviceForSecurityIssues(skipAnalyticsRefresh: Bool = false) {
        if !skipAnalyticsRefresh {
            queryForDNSAnalytics()
        }

        var issues: [String] = []
        let jailStatus = IOSSecuritySuite.amIJailbrokenWithFailMessage()
        let reverseStatus = IOSSecuritySuite.amIReverseEngineeredWithFailedChecks()
        
        if jailStatus.jailbroken {
            issues.append(
                NSLocalizedString("Your system shows signs of being jailbroken.", comment: "Home screen jailbreak detection")
            )
        }
        
        if reverseStatus.reverseEngineered {
            issues.append(
                NSLocalizedString("This app appears to be running in a modified or analyzed environment.", comment: "Home screen reverse engineering detection")
            )
        }
        
        if IOSSecuritySuite.amIProxied() {
            issues.append(
                NSLocalizedString("Unusual network activity or modification tools have been identified.", comment: "Home screen tampering detection")
            )
        }
        
        if IOSSecuritySuite.amIDebugged() {
            issues.append(
                NSLocalizedString("The app is currently running in a development or debugging environment.", comment: "Home screen debugger detection")
            )
        }
        
        if IOSSecuritySuite.amIRunInEmulator() {
            issues.append(
                NSLocalizedString("The app appears to be running in a simulated environment.", comment: "Home screen running in emulator detection")
            )
        }
        
        DispatchQueue.main.async {
            let systemAtRiskText = NSLocalizedString("Your system may be at risk.", comment: "Home screen system at risk")
            if !issues.isEmpty {
                self.isUserDeviceSecured = false
                self.securityStatusText = systemAtRiskText
                self.securityIssueText = issues.first ?? ""
            } else if !self.isConnectedToDNS && !self.isConnectedToVPN {
                self.isUserDeviceSecured = false
                self.securityStatusText = systemAtRiskText
                self.securityIssueText = NSLocalizedString(
                    "Connect to DNS to block malicious sites and trackers.",
                    comment: "Home screen connect to DNS to block trackers"
                )
            } else {
                self.isUserDeviceSecured = true
                self.securityStatusText = NSLocalizedString(
                    "All clear. \nNo issues found.", comment: "Home screen security status text"
                )
                self.securityIssueText = nil
            }
            self.writeSecurityIssueToSharedDefaults(self.securityIssueText)
        }
    }
    
    private func scanDeviceForSecuritySettings() {
        let passcodeEnabled = securityCenter.devicePasscodeEnabled()
        updateDeviceSettingsStatus(for: .screenLock, isEnabled: passcodeEnabled)
        
        let biometricsEnabled = securityCenter.deviceBiometricsEnabled()
        updateDeviceSettingsStatus(for: .bioMetrics, isEnabled: biometricsEnabled)

        securityCenter.getLatestVersions { [weak self] didGetVersions in
            guard let strongSelf = self else { return }
            guard didGetVersions else {
                // Couldn't verify versions — default to up to date to avoid false alarms
                strongSelf.updateDeviceSettingsStatus(for: .glacierAndiOSVersionUpdated, isEnabled: true)
                return
            }
            let secInfo = strongSelf.securityCenter.getSecurityInfo().securityInfo
            let glacierUpToDate = secInfo.glacier_version_outdated == false
            strongSelf.updateDeviceSettingsStatus(for: .glacierAndiOSVersionUpdated, isEnabled: glacierUpToDate)
        }
    }
    
    private func updateDeviceSettingsStatus(for settingsType: DeviceSecuritySettingType, isEnabled: Bool) {
        guard let index = deviceSecuritySettingsStatus.firstIndex(where: { $0.type.title == settingsType.title }) else {
            return
        }
        DispatchQueue.main.async {
            self.deviceSecuritySettingsStatus[index].isEnabled = isEnabled
        }
    }
    
    private var isVPNTunnelActuallyRunning: Bool {
        guard let tunnel = wireGuardManager.tunnelsManager?.tunnelInOperation() else { return false }
        return tunnel.status != .inactive && tunnel.status != .deactivating
    }

    private func updateConnectionStatusText() {
        DispatchQueue.main.async {
            // Use actual tunnel connection state, not just whether VPN is configured/on-demand
            // enabled. When on-demand rules suppress the tunnel (e.g. trusted network), the
            // tunnel is inactive even though isConnectedToVPN remains true.
            let tunnelActuallyConnected = self.securityCenter.isVpnTunnelConnected()
            if tunnelActuallyConnected {
                self.connectionStatusText = NSLocalizedString("Connected", comment: "Home screen connected to network text")
                self.activeConnectionLabel = SecuredConnectionType.vpn.label
                self.writeActiveConnectionType(.vpn)
            } else if self.isConnectedToDNS || self.isConnectedToVPN {
                // VPN is onDemand-enabled but not actively running (e.g. trusted network), or DNS only.
                // Either way DoT is providing protection — show DNS once.
                self.connectionStatusText = NSLocalizedString("Connected", comment: "Home screen connected to network text")
                self.activeConnectionLabel = SecuredConnectionType.dns.label
                self.writeActiveConnectionType(.dns)
            } else {
                self.connectionStatusText = NSLocalizedString("Disconnected from DNS", comment: "Home screen disconnected from DNS text")
                self.activeConnectionLabel = nil
                self.writeActiveConnectionType(nil)
            }
        }
    }

    /// Persists the active connection type to the shared App Group so the widget can read it,
    /// then asks WidgetKit to reload immediately.
    private func writeActiveConnectionType(_ type: SecuredConnectionType?) {
        let defaults = UserDefaults(suiteName: kGlacierGroup)
        if let type {
            defaults?.set(type.rawValue, forKey: kActiveConnectionTypeKey)
        } else {
            defaults?.removeObject(forKey: kActiveConnectionTypeKey)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Persists the current security issue text to the shared App Group so the widget
    /// can display it. An empty string signals "all clear" to avoid a false positive on
    /// first launch before the app has completed its security checks.
    private func writeSecurityIssueToSharedDefaults(_ text: String?) {
        UserDefaults(suiteName: kGlacierGroup)?.set(text ?? "", forKey: kWidgetSecurityIssueKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    private func connectToDNSIfRequired() {
        guard hasPendingRequestForDNSConnection else {
            return
        }
        
        hasPendingRequestForDNSConnection = false
        toggleDNSConnection(true)
    }
    
    private func connectToVPNIfRequired() {
        if hasPendingFirstTimeVPNSetup {
            hasPendingFirstTimeVPNSetup = false
            enableVPNWithWiFiOnDemandAndPresentSetup()
        } else {
            guard hasPendingRequestForVPNConnection else { return }
            hasPendingRequestForVPNConnection = false
            toggleVPNConnection(true)
        }
    }
    
    private func showBlockedTrackerAnalytics() {
        let blockedTrackersCountText = NSLocalizedString("%@ web trackers blocked", comment: "Home screen blocked trackers count text")
        self.blockedTrackersInfoText = String(format: blockedTrackersCountText, arguments: ["\(numberOfBlockedTrackers)"])
    }
    
    @objc private func onUserSelectedConnectionType(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let requestedConnectionType = userInfo[GlacierNotificationProperties.connectionType] as? String else {
            return
        }

        if requestedConnectionType == SecuredConnectionType.dns.label {
            guard hasDNSConfiguration() else {
                presentDNSSetupConfirmationPrompt(shouldDownloadAndAddDNSProfile: true)
                return
            }
            recordLastConnectionType(.dns)
            didUserTappedDNSConnectionButton = true
            toggleDNSConnection(true)
        } else if requestedConnectionType == SecuredConnectionType.vpn.label {
            guard hasVPNConfiguration() else {
                if needsFirstTimeVPNSetup { hasPendingFirstTimeVPNSetup = true }
                presentAddVPNConfirmationPrompt()
                return
            }
            recordLastConnectionType(.vpn)
            if needsFirstTimeVPNSetup {
                enableVPNWithWiFiOnDemandAndPresentSetup()
            } else {
                toggleVPNConnection(true)
            }
        }
    }

    private func recordLastConnectionType(_ type: SecuredConnectionType) {
        UserDefaults(suiteName: kGlacierGroup)?.set(type.rawValue, forKey: kLastConnectionTypeKey)
    }

    @objc private func onWidgetToggleRequested() {
        handleWidgetToggle()
    }

    /// Widget Link: glacierapp://widget/disconnect
    /// Action is explicit in the URL — no need to guess from NE/UserDefaults state.
    @objc private func onWidgetDisconnectRequested() {
        toggleVPNConnection(false)
        toggleDNSConnection(false)
    }

    /// Widget Link: glacierapp://widget/connect
    /// Reconnects to whichever type was last used.
    @objc private func onWidgetConnectRequested() {
        let lastType = UserDefaults(suiteName: kGlacierGroup)?.string(forKey: kLastConnectionTypeKey)
            ?? SecuredConnectionType.dns.rawValue
        if lastType == SecuredConnectionType.vpn.rawValue {
            guard hasVPNConfiguration() else { return }
            recordLastConnectionType(.vpn)
            toggleVPNConnection(true)
        } else {
            guard hasDNSConfiguration() else { return }
            recordLastConnectionType(.dns)
            didUserTappedDNSConnectionButton = true
            toggleDNSConnection(true)
        }
    }

    @objc func onVPNStatusChange() {
        refreshDeviceSecurityStatus()
        // When the tunnel goes inactive (e.g. on-demand suppressed by a trusted-network
        // rule), fire a DNS check so we immediately detect whether DoT is still routing
        // and prompt the user to select the profile in iOS Settings if needed.
        if !securityCenter.isVpnTunnelConnected() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.securityCenter.doDNSCheck()
            }
        }
    }
    
    @objc private func onAppBecameActive() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.consumeWidgetPendingToggleIfNeeded()
            self.connectToVPNIfRequired()
            self.connectToDNSIfRequired()
            self.scanDeviceForSecurityIssues()
            self.scanDeviceForSecuritySettings()
            self.securityCenter.doDNSCheck()
            self.queryDnsAnalyticsIfNeededAfterForeground()
        }
    }

    /// Executes a widget-requested action if the app was killed when the widget
    /// button was tapped (Darwin notification path covers the backgrounded case).
    private func consumeWidgetPendingToggleIfNeeded() {
        let defaults = UserDefaults(suiteName: kGlacierGroup)
        guard defaults?.bool(forKey: kWidgetPendingToggleKey) == true else { return }
        executeWidgetRequestedAction()
    }

    /// Reads the action the widget stored in UserDefaults and executes the real NE toggle.
    ///
    /// The widget extension cannot call NEDNSSettingsManager/NETunnelProviderManager
    /// (permission denied), so it writes "disconnect" or "connect" to kWidgetRequestedActionKey
    /// and signals the main app via Darwin notification or the pending-toggle flag.
    /// The main app (this method) holds the actual NE permission and performs the change.
    ///
    /// Intentionally does NOT read isConnectedToDNS/isConnectedToVPN — those combine
    /// NE state with the UserDefaults enabled flag, which may be stale at this point.
    /// Instead, toggleDNSConnection/toggleVPNConnection go straight to NEDNSSettingsManager
    /// / NETunnelProviderManager and update UserDefaults as a side effect.
    private func executeWidgetRequestedAction() {
        let defaults = UserDefaults(suiteName: kGlacierGroup)
        guard let action = defaults?.string(forKey: kWidgetRequestedActionKey) else { return }
        defaults?.removeObject(forKey: kWidgetRequestedActionKey)
        defaults?.removeObject(forKey: kWidgetPendingToggleKey)

        if action == "disconnect" {
            toggleVPNConnection(false)
            toggleDNSConnection(false)
        } else {
            // "connect" — reconnect to whichever type was last used.
            let lastType = defaults?.string(forKey: kLastConnectionTypeKey)
                ?? SecuredConnectionType.dns.rawValue
            if lastType == SecuredConnectionType.vpn.rawValue {
                guard hasVPNConfiguration() else { return }
                recordLastConnectionType(.vpn)
                toggleVPNConnection(true)
            } else {
                guard hasDNSConfiguration() else { return }
                recordLastConnectionType(.dns)
                didUserTappedDNSConnectionButton = true
                toggleDNSConnection(true)
            }
        }
    }


    private func queryDnsAnalyticsIfNeededAfterForeground() {
        guard isGlacierDNSEnabledIniOSSettings,
              !securityCenter.isVpnEnabled() else {
            return
        }
        securityCenter.queryForDNSAnalytics()
    }

    @objc private func onAccessTokenUpdated() {
        securityCenter.doDNSCheck()
        if !securityCenter.hasVersionsForToday() {
            scanDeviceForSecuritySettings()
        }
    }
}

// MARK: - DNS configuration checkup, setup and connection toggle

extension HomeVM {
    
    private func toggleDNSConnection(_ shouldConnect: Bool) {
        var dnsConfiguration = dnsController.loadSavedConfiguration()
        guard let url = dnsConfiguration.urlString,
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentDNSSetupConfirmationPrompt(shouldDownloadAndAddDNSProfile: true)
            return
        }
        
        dnsConfiguration.isEnabled = shouldConnect
        applyDNSConfig(dnsConfiguration)
    }
    
    private func applyDNSConfig(_ configuration: DnsOverTlsConfiguration) {
        dnsController.apply(configuration: configuration) { [weak self] _ in
            self?.securityCenter.doDNSCheck()
        }
    }
    
    private func hasDNSConfiguration() -> Bool {
        let dnsConfiguration = dnsController.loadSavedConfiguration()
        guard let url = dnsConfiguration.urlString else {
            return false
        }
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private func queryForDNSAnalytics() {
        isUpdatingBlockedTrackersCount = true
        securityCenter.queryForDNSAnalytics { [weak self] didUpdateDNSAnalytics in
            let delay: Double = didUpdateDNSAnalytics ? 0.3 : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self?.markDeviceSercurityStatusRefreshAsCompleted()
                self?.isUpdatingBlockedTrackersCount = false
            }
        }
    }
    
    /// Shown when a DNS profile exists and is enabled but doDNSCheck() found that
    /// the device is not routing through Glacier DNS — user needs to select the
    /// profile in iOS Settings (General → VPN & Device Management → DNS).
    private func presentDNSSetupConfirmationPrompt(shouldDownloadAndAddDNSProfile: Bool = true) {
        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString(
                "Enable Glacier DNS in Settings",
                comment: "DNS setup popup title"
            ),
            description: NSLocalizedString(
                "In Settings page, navigate to:\n\nGeneral →\nVPN & Device Management →\nDNS →\n\nThen select Glacier.",
                comment: "DNS setup popup description"
            ),
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
                    title: NSLocalizedString("Open Settings", comment: "Open settings button title"),
                    onTap: {
                        self.dismissPopup()
                        self.hasPendingRequestForDNSConnection = true
                        
                        if shouldDownloadAndAddDNSProfile {
                            // Let's add Glacier DNS configuration to user device
                            self.addDNSConfigurationToUserDevice()
                        } else {
                            // Let's open iOS settings app
                            guard let url = URL(string: UIApplication.settingsRootURL) else { return }
                            UIApplication.shared.open(url)
                        }
                    }
                )
            ],
            buttonsAlignment: .horizontal
        )
        presentPopup(with: popupConfiguration)
    }

    private func addDNSConfigurationToUserDevice() {
        let dnsOverTlsController = DnsOverTlsController.shared
        let securityCenter = self.securityCenter
        
        presentProgressIndicator()
        securityCenter.getDNSProfile { [weak self] dnsProfile in
            DispatchQueue.main.async {
                self?.dismissProgressIndicator()
            }
            
            guard let strongSelf = self,
                  let profile = dnsProfile else {
                return
            }
            
            var finalProfile = profile
            if !profile.hasPrefix("tls://"), profile.contains(SecurityCenter.DNS_BACKUP) {
                if let deviceID = strongSelf.getShortDeviceID(length: 12) {
                    finalProfile = "tls://\(deviceID)-\(profile)"
                } else {
                    finalProfile = "tls://\(profile)"
                }
            }
            dnsOverTlsController.storeNewConfiguration(finalProfile)
            
            let configuration = dnsOverTlsController.loadSavedConfiguration()
            dnsOverTlsController.apply(configuration: configuration) { result in
                guard case .success(_) = result else {
                    DispatchQueue.main.async {
                        strongSelf.presentAlertWith(
                            title: .errorText,
                            description: NSLocalizedString("Something went wrong while adding DNS configuration. Please try again.", comment: "DNS setup screen add DNS configuration error")
                        )
                    }
                    return
                }
                
                // Let's open iOS settings so that user can select Glacier DNS
                //guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                guard let url = URL(string: UIApplication.settingsRootURL) else { return }
                UIApplication.shared.open(url)
            }
        }
    }
    
    private func getShortDeviceID(length: Int) -> String? {
        let deviceId = DnsOverTlsController.shared.shortDeviceID(length: length)
        let invalidSuffix = "-unknown"
        if deviceId.hasSuffix(invalidSuffix) {
            return nil
        }
        return deviceId
    }

    /// Normalises a raw DNS profile string returned by the server into a tls:// URL,
    /// prepending a device-specific sub-identifier when the backup host is used.
    /// Returns nil if the input is nil.
    func buildDoTURL(from profile: String?) -> String? {
        guard let profile else { return nil }
        guard !profile.hasPrefix("tls://"), profile.contains(SecurityCenter.DNS_BACKUP) else {
            return profile
        }
        if let deviceID = getShortDeviceID(length: 12) {
            return "tls://\(deviceID)-\(profile)"
        }
        return "tls://\(profile)"
    }
}

// MARK: - VPN configuration checkup, setup and connection toggle

extension HomeVM {
    
    private func toggleVPNConnection(_ shouldConnect: Bool) {
        guard let tunnelsManager = wireGuardManager.tunnelsManager else { return }

        tunnelsManager.activationDelegate = self
        if shouldConnect {
            guard let tunnel = tunnelsManager.tunnel(named: currentInstalledRegion) else { return }
            // Ensure the DoT profile is fully enabled before the tunnel comes up so that
            // DNS remains protected if on-demand rules later suppress the tunnel.
            dnsController.ensureEnabledForVPN(urlProvider: { [weak self] callback in
                self?.securityCenter.getDNSProfile { profile in
                    callback(self?.buildDoTURL(from: profile))
                }
            }) { _ in
                // Proceed with tunnel activation regardless of DoT result —
                // the tunnel's own DNS proxy protects the user while it is running.
            }
            // Only re-enable on-demand if the tunnel has actual rules configured.
            // Without rules, enabling on-demand has no benefit and may cause
            // unexpected auto-reconnect behavior.
            let onDemandOption = ActivateOnDemandViewModel(tunnel: tunnel).toOnDemandOption()
            if case .off = onDemandOption {
                tunnelsManager.startActivation(of: tunnel)
            } else {
                tunnelsManager.setOnDemandEnabled(true, on: tunnel, completionHandler: { _ in
                    tunnelsManager.startActivation(of: tunnel)
                })
            }
        } else {
            // For disconnect use tunnelInOperation() so we always stop the actually-running
            // tunnel. If UserDefaults is stale (e.g., corrupted to us-east-1 while Oregon is
            // running), currentInstalledRegion would find the wrong tunnel and leave Oregon
            // connected. tunnelInOperation() is the reliable source of truth here.
            guard let tunnel = tunnelsManager.tunnelInOperation()
                    ?? tunnelsManager.tunnel(named: currentInstalledRegion) else { return }
            // Disable on-demand first so iOS cannot auto-reconnect after deactivation.
            tunnelsManager.setOnDemandEnabled(false, on: tunnel, completionHandler: { _ in
                tunnelsManager.startDeactivation(of: tunnel)
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
                    callback(self?.buildDoTURL(from: profile))
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
            }
        }
    }
}

// MARK: - DNSStatusDelegate methods

extension HomeVM: DNSStatusDelegate {
    
    /**
     This tells us, if user has selected Glacier DNS in iOS Settings.
     If selected, we get `enabled` as true, else as false.
     */
    func dnsStatusUpdated(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self else { return }
            
            strongSelf.isGlacierDNSEnabledIniOSSettings = enabled
            
            /**
             We consider DNS connection state when,
             1. User has selected DNS profile in iOS settings i.e. `enabled == true`
             2. DnsOverTlsConfiguration.enabled is set to true. It is updated with `dnsController.apply(configuration)` call.
             */
            
            // Update DNS connection status without restarting the scan animation cycle.
            // The gradient's onChange(of: isSecured) handles the smooth transition.
            strongSelf.refreshDeviceSecurityStatus(suppressScanAnimation: true)
            
            if !enabled, strongSelf.dnsController.loadSavedConfiguration().isEnabled {
                // DNS config is marked enabled but the check IP wasn't returned —
                // the user hasn't selected Glacier DNS in iOS Settings yet.

                // Show the prompt when:
                // 1. User explicitly tapped the DNS connection button, OR
                // 2. VPN is configured with on-demand but the tunnel is currently suppressed
                //    (trusted-network rule fired) — DNS should be routed through DoT but isn't
                //    because the profile hasn't been selected in iOS Settings.
                let isVPNSuppressedByOnDemand = strongSelf.securityCenter.isVpnEnabled()
                                             && !strongSelf.securityCenter.isVpnTunnelConnected()
                if strongSelf.didUserTappedDNSConnectionButton || isVPNSuppressedByOnDemand {
                    strongSelf.presentDNSSetupConfirmationPrompt(shouldDownloadAndAddDNSProfile: false)
                }
            }

            strongSelf.didUserTappedDNSConnectionButton = false
        }
    }

    func dnsAnalyticsUpdated(_ analytics: Int) {
        DispatchQueue.main.async {
            self.numberOfBlockedTrackers = analytics
            self.showBlockedTrackerAnalytics()
            UserDefaults(suiteName: kGlacierGroup)?.set(analytics, forKey: kWidgetBlockedTrackersCountKey)
            WidgetCenter.shared.reloadAllTimelines()

            self.markDeviceSercurityStatusRefreshAsCompleted()
            self.isUpdatingBlockedTrackersCount = false
        }
    }
}

// MARK: - TunnelsManagerActivationDelegate methods

extension HomeVM: TunnelsManagerActivationDelegate {
    
    // StartTunnel wasn't called or failed
    func tunnelActivationAttemptFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationAttemptError) {}
    
    // StartTunnel succeeded
    func tunnelActivationAttemptSucceeded(tunnel: TunnelContainer) {}
    
    // Status changed to connected
    func tunnelActivationSucceeded(tunnel: TunnelContainer) {
        isConnectedToVPN = true
    }
    
    // Status didn't change to connected
    func tunnelActivationFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationError) {
        isConnectedToVPN = false
    }
    
    // Status changed to disconnected
    func tunnelDeactivating(tunnel: TunnelContainer) {
        isConnectedToVPN = false
    }
}
