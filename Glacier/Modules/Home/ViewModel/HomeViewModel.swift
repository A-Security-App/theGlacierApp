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
        UserDefaults.standard.string(forKey: "glacier_vpn_installed_region") ?? "us-east-2"
    }

    private var isGlacierDNSEnabledIniOSSettings = false
    private var hasPendingRequestForDNSConnection = false
    private var hasPendingRequestForVPNConnection = false
    private var hasPendingFirstTimeVPNSetup = false
    private var didUserTappedDNSConnectionButton: Bool = false
    /// True while the "Enable Glacier DNS in Settings" popup we presented is on screen.
    /// Lets a later successful verification dismiss it (self-heal).
    private var isShowingDNSSetupPrompt = false
    /// Guards the DNS-setup prompt to at most once per connect attempt, so the early
    /// prompt and the final verdict don't both fire it (and it doesn't re-appear after
    /// the user has dismissed it).
    private var didPromptDNSSetupDuringVerification = false
    /// Guards the zero-tracker diagnostic below to one line per launch.
    private var didLogZeroTrackerDiagnostic = false
    /// Short per-instance id for the logs. If more than one HomeVM is alive, one instance can be
    /// querying while another renders the screen — which looks exactly like a refresh that does
    /// nothing. The tag makes that visible instead of invisible.
    private var instanceTag: String {
        String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xFFFF, radix: 16)
    }
    /// Gap between the foreground refresh's two samples. Both run under one shimmer, so this is
    /// how long that shimmer lasts — short enough to read as a single load, long enough to catch a
    /// backend cached aggregate rolling over. The second sample bypasses SecurityCenter's throttle,
    /// so this is a UX choice rather than a workaround for it.
    private static let foregroundAnalyticsResampleDelay: TimeInterval = 2
    /// True while the foreground refresh is running both samples under a single shimmer. The first
    /// sample's result must not drop the loading state: the second follows shortly and can replace
    /// the value if the backend's cache rolled over in between. Letting the shimmer resolve between
    /// them gave the worst shape — a settled number that silently corrected itself seconds later.
    private var isRunningForegroundAnalyticsRefresh = false
    /// True while the first security scan is deliberately held open waiting on the initial DNS
    /// verification. When DNS is enabled but not yet verified as the live resolver (e.g. right
    /// after onboarding), we keep the scanning gradient up rather than settle the card on an
    /// at-risk / "connect to DNS" verdict that would flip to All clear a moment later once the
    /// probe returns. Released by `finishInitialDNSGatedScan()`.
    private var isAwaitingInitialDNSVerification = false

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
        var dnsEnabled = dnsController.loadSavedConfiguration().isEnabled

        // When DNS was just enabled at the end of onboarding, `apply` persists `isEnabled`
        // asynchronously — after we've already navigated to Main and this first scan runs — so the
        // saved flag can still read `false` here (most visible now that onboarding can go straight
        // from DNS setup to Main). `connectDNSIfSetUpDuringOnboarding` leaves a one-shot marker so we
        // still treat DNS as enabled and ride out the activation latency with the retrying probe
        // below, instead of settling on a spurious "Disconnected" until the next foreground.
        if UserDefaultsService.shared.get(for: \.dnsActivationPendingFromOnboarding) ?? false {
            UserDefaultsService.shared.remove(for: \.dnsActivationPendingFromOnboarding)
            dnsEnabled = true
        }

        // Post-onboarding, DNS is enabled but the DoT profile can take a few seconds to become
        // the live system resolver, and the enabling `.dnsOverTlsConfigurationDidChange`
        // notification fires during onboarding — before HomeVM exists to observe it — so the
        // retry-budgeted verification never runs for the first appearance on its own.
        //
        // If DNS is enabled but not yet verified, hold the scanning gradient open until the
        // verification returns (or a safety timeout elapses) instead of letting the ~1s analytics
        // timer settle the card on an at-risk / "connect to DNS" verdict that would flip to All
        // clear a moment later. A retrying probe rides out the activation latency; the scan is
        // kept open in `markDeviceSercurityStatusRefreshAsCompleted()` until we hear back.
        if isScanningDevice && dnsEnabled && !securityCenter.isDoTVerifiedActive {
            isAwaitingInitialDNSVerification = true
            securityCenter.doDNSCheck(retryUntilVerified: true) { [weak self] _ in
                DispatchQueue.main.async { self?.finishInitialDNSGatedScan() }
            }
            // Safety net: never hold the gradient longer than this, even if the probe's
            // completion is delayed (it normally fires within the retry budget, ~9s).
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.finishInitialDNSGatedScan()
            }
        } else {
            // Already verified, or DNS is off (user skipped it — showing the "connect to DNS"
            // verdict is correct). A single probe keeps the normal cold-start behaviour.
            securityCenter.doDNSCheck(retryUntilVerified: dnsEnabled)
        }
    }

    /// Ends the initial DNS-gated scan: recompute the verdict from the now-known DNS state, then
    /// drop the scanning gradient so it animates straight to the resolved (All clear / at-risk)
    /// state. Guarded so exactly one of {verification completion, safety timeout} performs it.
    private func finishInitialDNSGatedScan() {
        guard isAwaitingInitialDNSVerification else { return }
        isAwaitingInitialDNSVerification = false
        // Recompute from the resolved DNS state first (the success path already refreshed via
        // dnsStatusUpdated; this also covers the paths that don't call the delegate), then end
        // the scan on a later run-loop tick so the verdict is applied before the gradient settles.
        checkSecuredConnectionStatus()
        scanDeviceForSecurityIssues(skipAnalyticsRefresh: true)
        DispatchQueue.main.async { [weak self] in
            self?.markDeviceSercurityStatusRefreshAsCompleted()
        }
    }
    
    func refreshDeviceSecurityStatus() {
        refreshDeviceSecurityStatus(suppressScanAnimation: false)
    }

    private func refreshDeviceSecurityStatus(suppressScanAnimation: Bool,
                                             context: String = #function) {
        if !suppressScanAnimation {
            isScanningDevice = true
        }
        checkSecuredConnectionStatus()
        // When called from dnsStatusUpdated (the only caller that passes
        // suppressScanAnimation: true), doDNSCheck just ran and the foreground
        // path already kicked off an analytics query — skip the redundant one
        // so the "Status loading" rectangle doesn't flash a second time.
        scanDeviceForSecurityIssues(skipAnalyticsRefresh: suppressScanAnimation, context: context)
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
                            // One tap turns off both VPN and DNS together. Turning the VPN off makes
                            // the tunnel go inactive, which fires onVPNStatusChange ->
                            // refreshDoTResolutionIfSuppressed; the DnsOverTlsController suppresses
                            // that heal for a few seconds after this explicit disable, so it can't
                            // re-enable the DoT profile we're deliberately turning off here.
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
        // The version row covers BOTH the Glacier app version and the iOS version, which have
        // different fixes (App Store vs. Settings → Software Update). Build the popup dynamically
        // so it only tells the user to fix whichever is actually outdated.
        if setting == .glacierAndiOSVersionUpdated {
            let secInfo = securityCenter.getSecurityInfo().securityInfo
            presentVersionUpdatePopup(
                glacierOutdated: secInfo.glacier_version_outdated == true,
                iosOutdated: secInfo.os_version_outdated == true
            )
            return
        }

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

    /// Builds the "Glacier & iOS Version" popup based on which version(s) are actually outdated.
    /// - A stale Glacier app is fixed in the App Store; a stale iOS is fixed in Settings → General
    ///   → Software Update. When both are stale we show both sets of steps and offer both buttons.
    private func presentVersionUpdatePopup(glacierOutdated: Bool, iosOutdated: Bool) {
        let glacierSteps = NSLocalizedString(
            "Update Glacier: \n→ Open the App Store \n→ On the Glacier page, tap “Update”",
            comment: "Popup steps to update the Glacier app from the App Store"
        )
        let iosSteps = NSLocalizedString(
            "Update iOS: \n→ Open Settings \n→ General \n→ Software Update",
            comment: "Popup steps to update the iOS version from Settings"
        )

        // If neither flag is set (defensive fallback — e.g. the row was tapped after the state
        // changed), show both fixes so the popup is never empty.
        let neitherFlagged = !glacierOutdated && !iosOutdated
        let showGlacierButton = glacierOutdated || neitherFlagged
        let showiOSButton = iosOutdated || neitherFlagged

        // Assemble the description from whichever fix(es) apply.
        var sections: [String] = []
        if showGlacierButton { sections.append(glacierSteps) }
        if showiOSButton { sections.append(iosSteps) }
        let description = sections.joined(separator: "\n\n")

        var buttons: [PopupButton] = [
            PopupButton(
                style: .tertiary,
                title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                onTap: { [weak self] in
                    self?.dismissPopup()
                }
            )
        ]

        if showGlacierButton {
            buttons.append(
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Open App Store", comment: "Open App Store button title"),
                    onTap: { [weak self] in
                        self?.dismissPopup()
                        // Deep-link straight to Glacier's App Store product page (App Store ID
                        // 6776005049, bundle com.theglacierapp.Glacier). The itms-apps scheme opens
                        // the App Store app directly; fall back to the https URL if it can't.
                        let appStoreURL = URL(string: "itms-apps://apps.apple.com/app/id6776005049")
                        let webURL = URL(string: "https://apps.apple.com/app/id6776005049")
                        if let url = appStoreURL, UIApplication.shared.canOpenURL(url) {
                            UIApplication.shared.open(url)
                        } else if let url = webURL {
                            UIApplication.shared.open(url)
                        }
                    }
                )
            )
        }

        if showiOSButton {
            buttons.append(
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Open Settings", comment: "Open settings button title"),
                    onTap: { [weak self] in
                        self?.dismissPopup()
                        guard let url = URL(string: UIApplication.settingsRootURL),
                              UIApplication.shared.canOpenURL(url) else {
                            return
                        }
                        UIApplication.shared.open(url)
                    }
                )
            )
        }

        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString(
                "Update Glacier & iOS",
                comment: "Device security settings screen update glacier version title"
            ),
            description: description,
            descriptionAlignment: .leading,
            buttons: buttons,
            // Three buttons (Cancel + both fixes) won't fit horizontally, so stack when needed.
            buttonsAlignment: buttons.count > 2 ? .vertical : .horizontal
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

        // Re-verify DNS status whenever the persisted DoT configuration changes.
        // The onboarding auto-connect (`connectDNSIfSetUpDuringOnboarding`) applies the
        // config fire-and-forget, so without this the home screen would keep showing
        // "Connect" until the next app foreground re-ran the check.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onDNSConfigurationChanged),
            name: .dnsOverTlsConfigurationDidChange,
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
        // While waiting on the initial DNS verification, keep the scanning gradient up so the
        // card doesn't flash an at-risk verdict before DNS resolves. `finishInitialDNSGatedScan()`
        // ends the scan once the answer (or the safety timeout) is in.
        if isAwaitingInitialDNSVerification {
            return
        }

        if self.isScanningDevice {
            self.isScanningDevice = false
        }

        if !self.isFirstDeviceScanCompleted {
            self.isFirstDeviceScanCompleted = true
        }
    }
    
    private func scanDeviceForSecurityIssues(skipAnalyticsRefresh: Bool = false,
                                             context: String = #function) {
        if !skipAnalyticsRefresh {
            queryForDNSAnalytics(context: context)
        }

        var issues: [String] = []
        let jailStatus = IOSSecuritySuite.amIJailbrokenWithFailMessage()
        let reFailedChecks = SecurityCenter.significantReverseEngineeringChecks()
        // Supplement 1.9.11 with the rootless (/var/jb) and TrollStore markers
        // it predates. Additive — see GlacierJailbreakChecks.
        let glacierJail = GlacierJailbreakChecks.run()

        if jailStatus.jailbroken || glacierJail.jailbroken {
            issues.append(
                NSLocalizedString("Your system shows signs of being jailbroken.", comment: "Home screen jailbreak detection")
            )
        }
        
        if !reFailedChecks.isEmpty {
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
                    "Connect to Secure DNS to block malicious sites and trackers.",
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
            let iosUpToDate = secInfo.os_version_outdated == false
            strongSelf.updateDeviceSettingsStatus(for: .glacierAndiOSVersionUpdated, isEnabled: glacierUpToDate && iosUpToDate)
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
                self.connectionStatusText = NSLocalizedString("Disconnected from Secure DNS", comment: "Home screen disconnected from DNS text")
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
            if needsFirstTimeVPNSetup {
                recordLastConnectionType(.vpn)
                enableVPNWithWiFiOnDemandAndPresentSetup()
            } else {
                // Not first-time: confirm before enabling VPN.
                presentEnableVPNConfirmation(onEnable: { [weak self] in
                    self?.recordLastConnectionType(.vpn)
                    self?.toggleVPNConnection(true)
                })
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

    /// Fired when the persisted DoT configuration changes (enable/disable). Recompute the
    /// displayed status from the now-persisted flag and re-verify against the live resolver.
    /// This is what catches the onboarding auto-connect (`connectDNSIfSetUpDuringOnboarding`),
    /// which applies the config fire-and-forget without going through `applyDNSConfig`.
    @objc private func onDNSConfigurationChanged() {
        // Only retry the verification when the change was an enable — a freshly-activated
        // profile can lag before it's the live resolver. On disable, the persisted flag
        // already drives the UI and a single probe is enough.
        let didEnable = dnsController.loadSavedConfiguration().isEnabled
        checkSecuredConnectionStatus()
        securityCenter.doDNSCheck(retryUntilVerified: didEnable)
    }

    @objc func onVPNStatusChange() {
        refreshDeviceSecurityStatus(suppressScanAnimation: false, context: "onVPNStatusChange")
        // When the tunnel goes inactive (e.g. on-demand suppressed by a trusted-network
        // rule), fire a DNS check so we immediately detect whether DoT is still routing
        // and prompt the user to select the profile in iOS Settings if needed.
        if !securityCenter.isVpnTunnelConnected() {
            // The tunnel (and its DNS proxy) is down, so the system-wide DoT profile is the only
            // thing steering DNS. Refresh its pinned resolver IPs in case they went unroutable on
            // the network switch that suppressed the tunnel; a successful re-apply re-verifies via
            // the .dnsOverTlsConfigurationDidChange path. The doDNSCheck below is the fallback probe.
            dnsController.refreshDoTResolutionIfSuppressed(isTunnelConnected: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.securityCenter.doDNSCheck()
            }
        }
    }
    
    @objc private func onAppBecameActive() {
        Log.general.notice("Home foreground [\(self.instanceTag, privacy: .public)]: willEnterForeground received; refresh burst queued")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.consumeWidgetPendingToggleIfNeeded()
            self.connectToVPNIfRequired()
            self.connectToDNSIfRequired()
            // Claim the loading state before the first sample below can come back, so both samples
            // of the foreground refresh resolve under one shimmer.
            self.runForegroundAnalyticsRefresh()
            self.scanDeviceForSecurityIssues()
            self.scanDeviceForSecuritySettings()
            // If DoT is enabled but the tunnel is suppressed (on-demand on a trusted network), heal
            // the profile's pinned resolver IPs so DNS works — the common case when a user opens the
            // app after noticing DNS is down. No-op when the tunnel is actually connected.
            self.dnsController.refreshDoTResolutionIfSuppressed(
                isTunnelConnected: self.securityCenter.isVpnTunnelConnected()
            )
            self.securityCenter.doDNSCheck()
            // Covers the cases the `dnsStatusUpdated(true)` trigger can't reach: DNS switched off,
            // or a device carrying only the packet tunnel's old shared-profile default. Neither
            // runs a DoT verification, so neither ever reports a verified baseline.
            DNSProfileHealer.shared.healIfNeeded(securityCenter: self.securityCenter,
                                                 dnsController: self.dnsController)
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


    /// Arms the second half of the foreground refresh: the sample `scanDeviceForSecurityIssues()`
    /// is about to take, then one more `foregroundAnalyticsResampleDelay` later, both under the
    /// single shimmer that first sample raises.
    ///
    /// Two samples because the first lands ~1s after the app comes back, often before the backend
    /// has aggregated whatever the user just did — an identical query has been seen returning one
    /// count and then a higher one seconds later, so the response is cached server-side with a TTL.
    /// One sample means whatever that cache happened to hold; a second catches the rollover.
    ///
    /// No DNS/VPN gate. This used to require `isGlacierDNSEnabledIniOSSettings && !isVpnEnabled()`,
    /// on the reasoning that tunnel users get their refresh from `doDNSCheck`'s early return
    /// instead — but that call sits in the same burst and loses to the same throttle, so gating
    /// here excluded the users most likely to see a stale count. Both flags are also unreliable at
    /// this moment: `isGlacierDNSEnabledIniOSSettings` is only set once a DoT probe has reported
    /// back, and `isVpnEnabled()` is true whenever on-demand is configured, even while the tunnel
    /// is suppressed. The count is on screen regardless of either, so refreshing it is always
    /// correct; being foregrounded is the only precondition that matters.
    private func runForegroundAnalyticsRefresh() {
        guard !isRunningForegroundAnalyticsRefresh else { return }
        isRunningForegroundAnalyticsRefresh = true
        // Own the loading state outright rather than relying on the first sample to raise it, so
        // the pair behaves the same however the caller is ordered.
        isUpdatingBlockedTrackersCount = true

        DispatchQueue.main.asyncAfter(deadline: .now() + HomeVM.foregroundAnalyticsResampleDelay) { [weak self] in
            guard let self else { return }
            // Gone to the background mid-pair: nothing to sample, but the shimmer still has to be
            // released or it would still be running the next time the screen is shown.
            guard UIApplication.shared.applicationState == .active else {
                self.finishForegroundAnalyticsRefresh()
                return
            }
            // `bypassThrottle` — this is the deliberate follow-up the throttle isn't meant to stop.
            self.securityCenter.queryForDNSAnalytics(bypassThrottle: true) { [weak self] _ in
                DispatchQueue.main.async { self?.finishForegroundAnalyticsRefresh() }
            }
        }
    }

    /// Ends the paired refresh and hands the loading state back, so the shimmer resolves once —
    /// onto whichever value the second sample settled on.
    private func finishForegroundAnalyticsRefresh() {
        isRunningForegroundAnalyticsRefresh = false
        isUpdatingBlockedTrackersCount = false
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
        if shouldConnect {
            // Fresh connect attempt — allow the DNS-setup prompt to fire once for it.
            didPromptDNSSetupDuringVerification = false
        }
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
        dnsController.apply(configuration: configuration) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                let ns = error as NSError
                Log.vpn.error("Failed to apply DNS config (isEnabled=\(configuration.isEnabled, privacy: .public)): domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(error.localizedDescription, privacy: .public)")
            }
            // Recompute the displayed status from the now-persisted configuration rather than
            // relying solely on doDNSCheck's delegate callback, which can hang or skip on a
            // bad/blocked resolver. This guarantees the UI reflects the change immediately.
            //
            // The DoT verification probe is NOT armed here: a successful apply posts
            // `.dnsOverTlsConfigurationDidChange`, which onDNSConfigurationChanged observes and
            // uses to run `doDNSCheck(retryUntilVerified:)`. Arming it here as well used to start
            // a second, redundant retry chain racing on the same work item. The notification is
            // also the only trigger for the onboarding fire-and-forget path, so it's the single
            // source of truth for re-verifying after a config change.
            self.checkSecuredConnectionStatus()
        }
    }
    
    private func hasDNSConfiguration() -> Bool {
        let dnsConfiguration = dnsController.loadSavedConfiguration()
        guard let url = dnsConfiguration.urlString else {
            return false
        }
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    /// `context` names the caller that originally asked, forwarded from `scanDeviceForSecurityIssues`.
    /// Without it every path collapses to this function's own name in the logs, which is useless
    /// when the point is working out which caller won the throttle.
    private func queryForDNSAnalytics(context: String = #function) {
        isUpdatingBlockedTrackersCount = true
        securityCenter.queryForDNSAnalytics(context: context) { [weak self] didUpdateDNSAnalytics in
            Log.general.notice("Home analytics refresh [\(self?.instanceTag ?? "-", privacy: .public)] \(context, privacy: .public): didUpdate=\(didUpdateDNSAnalytics ? 1 : 0, privacy: .public)")
            let delay: Double = didUpdateDNSAnalytics ? 0.3 : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self?.markDeviceSercurityStatusRefreshAsCompleted()
                // The foreground refresh owns the loading state until its second sample lands.
                if self?.isRunningForegroundAnalyticsRefresh != true {
                    self?.isUpdatingBlockedTrackersCount = false
                }
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
                        self.isShowingDNSSetupPrompt = false
                        self.dismissPopup()
                    }
                ),
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Open Settings", comment: "Open settings button title"),
                    onTap: {
                        self.isShowingDNSSetupPrompt = false
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
        isShowingDNSSetupPrompt = true
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
            
            guard let strongSelf = self else { return }

            // No profile available (the account isn't provisioned yet, or the fetch failed).
            // `getDNSProfile` no longer substitutes the shared backup profile, because a device
            // pinned to it never re-fetches and reports zero blocked trackers forever. Surface
            // it rather than leaving the user looking at an unchanged screen.
            guard let profile = dnsProfile else {
                DispatchQueue.main.async {
                    strongSelf.presentAlertWith(
                        title: .errorText,
                        description: NSLocalizedString(
                            "We couldn't finish setting up Secure DNS right now. Try again in a minute — if it keeps happening, contact support.",
                            comment: "Home screen missing DNS profile error"
                        )
                    )
                }
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
            tunnelsManager.setOnDemandEnabled(false, on: tunnel, completionHandler: { [weak self] _ in
                tunnelsManager.startDeactivation(of: tunnel)
                // A tunnel suppressed by on-demand is already .inactive, so startDeactivation
                // is a no-op and the tunnelDeactivating delegate never fires. Recompute the
                // status explicitly so isConnectedToVPN reflects that on-demand is now off
                // instead of staying stuck on "connected".
                self?.checkSecuredConnectionStatus()
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

    // Shown when VPN is enabled from the Choose protection screen after the first-time VPN
    // mini-setup (Cellular/Wi-Fi setup) has already been completed. On cancel we simply don't
    // enable — there's no optimistic UI to revert here.
    private func presentEnableVPNConfirmation(onEnable: @escaping () -> Void) {
        let viewModel = EnableVPNVM(
            rootCoordinator: rootCoordinator,
            onEnable: onEnable,
            onCancel: {}
        )
        presentScreen(.enableVPN(viewModel))
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
            
            if enabled {
                // DoT is verified as the live resolver. If we'd already surfaced the
                // "select the profile in Settings" prompt during this connect attempt —
                // e.g. an early negative that the profile then corrected — dismiss it, since
                // the situation it warned about no longer holds.
                if strongSelf.isShowingDNSSetupPrompt {
                    strongSelf.isShowingDNSSetupPrompt = false
                    strongSelf.dismissPopup()
                }
                strongSelf.didPromptDNSSetupDuringVerification = false

                // DoT is confirmed live, which is the settled state the heal needs: if this
                // device is pinned to the shared backup profile, repoint it at the user's own
                // profile now. A no-op for everyone else, and rate-limited internally.
                DNSProfileHealer.shared.healIfNeeded(securityCenter: strongSelf.securityCenter,
                                                     dnsController: strongSelf.dnsController)
            } else if strongSelf.dnsController.loadSavedConfiguration().isEnabled {
                // DNS config is marked enabled but the check IP wasn't returned —
                // the user hasn't selected Glacier DNS in iOS Settings yet.

                // Show the prompt when:
                // 1. User explicitly tapped the DNS connection button, OR
                // 2. VPN is configured with on-demand but the tunnel is currently suppressed
                //    (trusted-network rule fired) — DNS should be routed through DoT but isn't
                //    because the profile hasn't been selected in iOS Settings.
                // Skip if we already prompted earlier in this same connect attempt (the early
                // probe-failed prompt), so it doesn't fire twice or re-appear after dismissal.
                let isVPNSuppressedByOnDemand = strongSelf.securityCenter.isVpnEnabled()
                                             && !strongSelf.securityCenter.isVpnTunnelConnected()
                if (strongSelf.didUserTappedDNSConnectionButton || isVPNSuppressedByOnDemand),
                   !strongSelf.didPromptDNSSetupDuringVerification {
                    strongSelf.didPromptDNSSetupDuringVerification = true
                    strongSelf.presentDNSSetupConfirmationPrompt(shouldDownloadAndAddDNSProfile: false)
                }
            }

            strongSelf.didUserTappedDNSConnectionButton = false
        }
    }

    /// A couple of verification probes have failed but retries are still running. Surface the
    /// "select the profile in Settings" prompt now rather than making the user wait out the full
    /// retry budget. Uses the same gating as the final-verdict prompt; if a later retry verifies
    /// DoT, dnsStatusUpdated(true) dismisses the prompt.
    func dnsVerificationProbeFailedEarly() {
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.dnsController.loadSavedConfiguration().isEnabled else { return }
            guard !strongSelf.didPromptDNSSetupDuringVerification else { return }
            let isVPNSuppressedByOnDemand = strongSelf.securityCenter.isVpnEnabled()
                                         && !strongSelf.securityCenter.isVpnTunnelConnected()
            guard strongSelf.didUserTappedDNSConnectionButton || isVPNSuppressedByOnDemand else { return }
            strongSelf.didPromptDNSSetupDuringVerification = true
            strongSelf.presentDNSSetupConfirmationPrompt(shouldDownloadAndAddDNSProfile: false)
        }
    }

    func dnsAnalyticsUpdated(_ analytics: Int) {
        DispatchQueue.main.async {
            Log.general.notice("Home analytics applied [\(self.instanceTag, privacy: .public)]: \(self.numberOfBlockedTrackers, privacy: .public) -> \(analytics, privacy: .public)")
            self.numberOfBlockedTrackers = analytics
            self.showBlockedTrackerAnalytics()

            // A zero count while DoT is verified live is the signature of the shared-profile
            // pinning bug: the device filters fine, but through a profile that isn't the user's,
            // so their own profile has no traffic to report. Record which of the two it is —
            // once per launch, without logging the profile id itself — so the next support log
            // answers this outright instead of a reinstall being the only way to find out.
            if analytics == 0, !self.didLogZeroTrackerDiagnostic, self.securityCenter.isDoTVerifiedActive {
                self.didLogZeroTrackerDiagnostic = true
                let isPinned = DNSProfileHealer.isPinnedToBackupProfile(
                    self.dnsController.loadSavedConfiguration().urlString
                )
                Log.vpn.notice("Zero blocked trackers with DoT verified live; device is resolving through \(isPinned ? "the shared backup profile" : "its own profile", privacy: .public).")
            }
            UserDefaults(suiteName: kGlacierGroup)?.set(analytics, forKey: kWidgetBlockedTrackersCountKey)
            WidgetCenter.shared.reloadAllTimelines()

            self.markDeviceSercurityStatusRefreshAsCompleted()
            // Same here: while the foreground refresh is mid-pair, the value can still change, so
            // the shimmer stays up and the user sees one load resolving to one number.
            if !self.isRunningForegroundAnalyticsRefresh {
                self.isUpdatingBlockedTrackersCount = false
            }
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
