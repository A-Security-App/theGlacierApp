//
//  SecurityCenter.swift
//  Glacier
//
//  Created by andyfriedman on 3/3/22.
//  Copyright © 2022 Glacier. All rights reserved.
//

import Foundation
import Alamofire
import LocalAuthentication
import IOSSecuritySuite
import NetworkExtension
import UIKit
import CryptoKit

public protocol DNSStatusDelegate:AnyObject {
    func dnsStatusUpdated(_ enabled: Bool)
    func dnsAnalyticsUpdated(_ analytics: Int)
    /// Called once per retrying verification chain, as soon as enough probes have come
    /// back negative to be confident DoT isn't the live resolver — but while retries are
    /// still pending. Lets the UI surface the "select the profile in iOS Settings" prompt
    /// immediately instead of waiting for the full retry budget (~13s) to drain. The
    /// remaining retries keep running, so if the profile does become live, a later
    /// `dnsStatusUpdated(true)` fires and the UI can dismiss the prompt.
    func dnsVerificationProbeFailedEarly()
}

public extension DNSStatusDelegate {
    func dnsVerificationProbeFailedEarly() {}
}

open class SecurityCenter: NSObject {
    public static let didCheckCompromised = Notification.Name("didCheckCompromised")
    public static let securityCheckNotification = Notification.Name("securityCheckNotification")
    public static let proxyStateDidChange = Notification.Name("proxyStateDidChange")
    public static var isProxyDetected: Bool = false
    static let DNS_API_ENDPOINT = (EndpointService.shared.consoleBaseEndpoint ?? "") + (EndpointService.shared.dnsAPIEndpoint ?? "")
    static let DNS_PROFILE_ENDPOINT = (EndpointService.shared.consoleBaseEndpoint ?? "") + (EndpointService.shared.dnsProfileEndpoint ?? "")
    static let VERSIONS_ENDPOINT = (EndpointService.shared.consoleBaseEndpoint ?? "") + "versions"
    static let DNS_ENDPOINT = EndpointService.shared.dnsEndpoint ?? ""
    static let DNS_CHECK_ENDPOINT = EndpointService.shared.dnsCheckEndpoint ?? ""
    static let DNS_CHECK_IP = EndpointService.shared.dnsCheckIP ?? ""
    static let DNS_BACKUP = "62b3da"
    let internalQueue = DispatchQueue(label: "SecCenter Queue", qos: .userInitiated)
    let sessionManager = Alamofire.Session(
        configuration: URLSessionConfiguration.ephemeral,
        serverTrustManager: GlacierPinningConfiguration.makeServerTrustManager()
    )
    fileprivate var context = LAContext()
    var needsNotification = false
    var versionNeedsNotification = false
    var lastVersionsCheck = Date.distantPast
    //let secVersionsUrl = "https://tiny.one/5967h5e2"
    var compromisedStatus = false
    var dnsStatusDelegate:DNSStatusDelegate?
    var dnsTester:DNSTester?

    /// Persistent cache of the most recent `doDNSCheck` verdict.
    ///
    /// True when a probe of `{uuid}.DNS_CHECK_ENDPOINT` returned `DNS_CHECK_IP` — that
    /// response only comes back when the Glacier DoT profile is the system resolver in
    /// iOS Settings → General → VPN & Device Management → DNS. The early-return path
    /// of `doDNSCheck` (tunnel carrying traffic) is "can't tell" and intentionally
    /// does not touch this value, so the cache reflects the last actual verification.
    ///
    /// Used to gate UI that depends on DoT being the active resolver (e.g. the
    /// "DNS Protection Required" popup when adding a trusted Wi-Fi network) without
    /// relying on `NEDNSSettingsManager.isEnabled`, which does not always reflect the
    /// user's selection in iOS Settings.
    private static let dotVerifiedActiveKey = "glacier_dot_verified_active"
    public var isDoTVerifiedActive: Bool {
        get { UserDefaults.standard.bool(forKey: SecurityCenter.dotVerifiedActiveKey) }
        set { UserDefaults.standard.set(newValue, forKey: SecurityCenter.dotVerifiedActiveKey) }
    }

    private var dnsCheckWorkItem: DispatchWorkItem?

    /// A freshly-activated DoT profile (e.g. enabled at the end of onboarding) can take a
    /// few seconds to become the live system resolver. A single probe that runs before
    /// then would report "disconnected" and that stale verdict would stick until the next
    /// app foreground. Retry the probe a few times before concluding DoT is not active.
    /// The budget also has to absorb a transient `.inactive` window during the
    /// onboarding→main transition, when the probe can't run at all — so allow enough
    /// attempts to outlast both the transition and the profile's activation latency.
    private static let dnsCheckMaxAttempts = 5
    private static let dnsCheckRetryDelay: TimeInterval = 2.0
    /// Settle delay before each probe, giving a just-saved/just-activated DoT configuration
    /// a moment to take effect. Combined with `dnsCheckRetryDelay` and `dnsCheckMaxAttempts`
    /// this sets the total retry wall-clock the onboarding auto-connect relies on.
    private static let dnsCheckInitialDelay: TimeInterval = 1.0
    /// Number of negative probes after which we tell the delegate to surface the
    /// "select the profile in Settings" prompt early, without waiting for the remaining
    /// retries. 2 gives a genuinely-lagging-but-valid profile a chance to come live
    /// (it usually does within the first retry) before the prompt appears.
    private static let dnsEarlyPromptFailureThreshold = 2
    /// Guards `dnsVerificationProbeFailedEarly()` to fire at most once per chain.
    private var didFireEarlyDNSPrompt = false
    private var reachabilityManager: NetworkReachabilityManager?
    private var lastDnsAnalyticsQueryDate: Date?
    private let dnsAnalyticsQueryLock = DispatchQueue(label: "com.theglacierapp.securitycenter.dnsAnalyticsQueryLock")
    private static let dnsAnalyticsThrottleInterval: TimeInterval = 5
    private var needVersions = false
    
    //IOSM#48
    let DEVICE_ID = "device"
    let DEVICE = "deviceid"
    let GLACIER_VERSION = "glacier_version"
    let GLACIER_VERSION_OUTDATED = "glacier_version_outdated"
    let OS_VERSION = "os_version"
    let OS_VERSION_OUTDATED = "os_version_outdated"
    let OS_PATCH = "os_patch"
    let COMPROMISED = "compromised"
    let COMPROMISED_DETAIL = "compromised_detail"
    let SCREEN_LOCK = "screen_lock"
    let BIOMETRIC_LOCK = "biometric_lock"
    let CORE_ENABLED = "core_enabled"
    
    //IOSM#58
    let COMPROMISED_JAILBROKEN = "jailbroken"
    let COMPROMISED_PROXIED = "proxied"
    let COMPROMISED_REVERSE_ENGINEERED = "reverse engineered"
    let COMPROMISED_RUN_IN_EMULATOR = "run in emulator"
    var ignoreCompromisedAlert = false
    var gotEnablements = false

    var secInfoUtil = SecurityInfoUtil()
    
    public override init() {
        self.reachabilityManager = NetworkReachabilityManager()
        super.init()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)

        self.reachabilityManager?.startListening(onQueue: .main, onUpdatePerforming: { [weak self] status in
            guard let self = self else { return }
            if !self.isReachable(status: status) {
                self.cancelPendingDNSCheck()
            }
        })
    }

    deinit {
        NotificationCenter.default.removeObserver(self,
                                                  name: UIApplication.didEnterBackgroundNotification,
                                                  object: nil)
        self.reachabilityManager?.stopListening()
    }

    public func doSettingsSecurityChecks() {
        self.needsNotification = false
        DispatchQueue.global().async {
            self.needsSettingsNotification()
        }
    }
    
    public func isCompromised() -> Bool {
        var compromised = false

        let jailStatus = IOSSecuritySuite.amIJailbrokenWithFailMessage()
        let reStatus = IOSSecuritySuite.amIReverseEngineeredWithFailedChecks()
        let proxied = IOSSecuritySuite.amIProxied()
        // Supplement 1.9.11's jailbreak checks with the rootless (/var/jb) and
        // TrollStore fingerprints it predates. Purely additive — OR'd below.
        let glacierJail = GlacierJailbreakChecks.run()
        if jailStatus.jailbroken || glacierJail.jailbroken {
            compromised = true
            var reasons: [String] = []
            if jailStatus.jailbroken { reasons.append(jailStatus.failMessage) }
            if glacierJail.jailbroken { reasons.append(glacierJail.indicators.joined(separator: ", ")) }
            let reason = " with reason: \(reasons.joined(separator: "; "))"
            self.secInfoUtil.securityInfo.compromised_detail = COMPROMISED_JAILBROKEN + reason //IOSM#58
        } else if proxied {
            compromised = true
            self.secInfoUtil.securityInfo.compromised_detail = COMPROMISED_PROXIED
        //} else if IOSSecuritySuite.amIDebugged() {
        //    compromised = true
        } else if reStatus.reverseEngineered {
            compromised = true
            let reason = ": The following checks failed: \(reStatus.failedChecks)"
            self.secInfoUtil.securityInfo.compromised_detail = COMPROMISED_REVERSE_ENGINEERED + reason
        } else if IOSSecuritySuite.amIRunInEmulator() {
            compromised = true
            self.secInfoUtil.securityInfo.compromised_detail = COMPROMISED_RUN_IN_EMULATOR
        }

        //JUST TESTING
        //compromised = true
        //let reason = " with reason: TESTING"
        //self.secInfoUtil.securityInfo.compromised_detail = COMPROMISED_JAILBROKEN + reason

        self.compromisedStatus = compromised

        // Update the shared proxy-detected flag and notify if it changed
        let wasProxyDetected = SecurityCenter.isProxyDetected
        SecurityCenter.isProxyDetected = proxied
        if wasProxyDetected != proxied {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: SecurityCenter.proxyStateDidChange,
                    object: nil,
                    userInfo: ["proxyDetected": proxied]
                )
            }
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: SecurityCenter.didCheckCompromised, object: self, userInfo: ["compromised":compromised])
        }

        return compromised
    }
    
    public func getCurrentCompromisedStatus() -> Bool {
        return self.compromisedStatus
    }
    
    //IOSM#58 (next 2)
    public func shouldIgnoreCompromisedAlert() -> Bool {
        return self.ignoreCompromisedAlert
    }
    
    public func setIgnoreCompromisedAlert(_ ignore: Bool) {
        self.ignoreCompromisedAlert = ignore
    }
    
    public func getNeedsSettingsNotification() -> Bool {
        return self.needsNotification
    }
    
    private func needsSettingsNotification() {
        let compromised = isCompromised()
        if (compromised != self.secInfoUtil.securityInfo.compromised) {
            self.secInfoUtil.secinfoNeedsUpdate = true
        }
        self.secInfoUtil.securityInfo.compromised = compromised
        if compromised {  
            self.needsNotification = true
        }
        
        let devicePassEnabled = devicePasscodeEnabled()
        if (devicePassEnabled != self.secInfoUtil.securityInfo.screen_lock) {
            self.secInfoUtil.secinfoNeedsUpdate = true
        }
        self.secInfoUtil.securityInfo.screen_lock = devicePassEnabled
        if !devicePassEnabled {
            self.needsNotification = true
        }
        
        let biometricEnabled = deviceBiometricsEnabled()
        if (biometricEnabled != self.secInfoUtil.securityInfo.biometric_lock) {
            self.secInfoUtil.secinfoNeedsUpdate = true
        }
        self.secInfoUtil.securityInfo.biometric_lock = biometricEnabled
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: SecurityCenter.securityCheckNotification, object: self, userInfo: ["needsNotification":self.needsNotification])
        }

        if Calendar.current.isDateInToday(self.lastVersionsCheck) {
            if self.versionNeedsNotification {
                self.needsNotification = true
            }
        } else {
            self.getLatestVersions()
        }
    }
    
    public func getSecurityInfo() -> SecurityInfoUtil {
        return self.secInfoUtil
    }

    public func osUpdateAvailable() -> Bool {
        return false
    }
    
    public func queryForDNSAnalytics(completionHandler: ((Bool) -> Void)? = nil) {
        guard !SecurityCenter.isProxyDetected else {
            completionHandler?(false);
            return
        }
        
        let shouldThrottle = dnsAnalyticsQueryLock.sync { () -> Bool in
            let now = Date()
            if let lastQueryDate = lastDnsAnalyticsQueryDate,
               now.timeIntervalSince(lastQueryDate) < Self.dnsAnalyticsThrottleInterval {
                return true
            }

            lastDnsAnalyticsQueryDate = now
            return false
        }

        if shouldThrottle {
            completionHandler?(false)
            return
        }
        
        Task { [weak self] in
            guard let self, let headers = await GlacierAPIHeaders.authHeaders() else {
                completionHandler?(false)
                return
            }

            self.sessionManager.request(self.getDNSAnalytics(), method: .get, encoding: URLEncoding.default, headers: headers)
                .validate()
                .responseData(queue: self.internalQueue) { response in
                    switch response.result {
                    case .success(let value):
                        var didCallDelegateToUpdate: Bool = false
                        if let results = String(data: value, encoding: .utf8),
                           let data = results.data(using: .utf8) {
                            let parsed: Any?
                            do {
                                parsed = try JSONSerialization.jsonObject(with: data, options: .allowFragments)
                            } catch {
                                Log.general.error("Failed to parse DNS analytics JSON: \(error)")
                                parsed = nil
                            }
                            if let json = parsed as? Dictionary<String,Any>,
                               let jdata = json["data"] as? Dictionary<String,Any>,
                               let status = jdata["status"] as? Dictionary<String,Any> {

                                // blockedQueries = Number of blocked queries for today - Midnight to current timestamp
                                // totalQueries = Total number of bocked queries since the VPN was activated.

                                if let blocked = status["blockedQueries"] as? Int {
                                    didCallDelegateToUpdate = true
                                    self.dnsStatusDelegate?.dnsAnalyticsUpdated(blocked)
                                }
                            }
                        }
                        
                        if !didCallDelegateToUpdate {
                            completionHandler?(false)
                        }
                        return
                    case .failure(let error):
                        Log.general.error("Error getting DNS analytics: \(error)")
                        completionHandler?(false)
                        return
                    }
            }
        }
    }
    
    private func fetchApplicationActive(_ completion: @escaping (Bool) -> Void) {
        if Thread.isMainThread {
            completion(UIApplication.shared.applicationState == .active)
        } else {
            DispatchQueue.main.async {
                completion(UIApplication.shared.applicationState == .active)
            }
        }
    }
    
    public func isVpnEnabled() -> Bool {
        return WireGuardManager.shared().tunnelsManager?.isTunnelEnabled() ?? false
    }

    /// Returns true only when a WireGuard tunnel is actively connected (active/activating/
    /// reasserting). Unlike `isVpnEnabled()`, returns false when on-demand is configured
    /// but the tunnel is currently suppressed by a trusted-network rule.
    public func isVpnTunnelConnected() -> Bool {
        return WireGuardManager.shared().tunnelsManager?.isTunnelConnected() ?? false
    }
    
    public func getDNSProfile(completion: @escaping (_ dnsProfile: String?) -> ()) {
        guard !SecurityCenter.isProxyDetected else { completion(nil); return }
        Task { [weak self] in
            guard let self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
            
            self.sessionManager.request(SecurityCenter.DNS_PROFILE_ENDPOINT, method: .get, encoding: URLEncoding.default, headers: headers)
                .validate()
                .responseData(queue: self.internalQueue) { response in
                    switch response.result {
                    case .success(let data):
                        var dnsprofile:String? = nil
                        let parsed: Any?
                        do {
                            parsed = try JSONSerialization.jsonObject(with: data, options: .allowFragments)
                        } catch {
                            Log.general.error("Failed to parse DNS profile JSON: \(error)")
                            parsed = nil
                        }
                        if let json = parsed as? Dictionary<String,Any>,
                           let jdata = json["data"] as? Dictionary<String,Any> {
                            let dnsid = jdata["profile_id"] as? String ?? "62b3da"
                            dnsprofile = "tls://" + dnsid + SecurityCenter.DNS_ENDPOINT
                        }
                        completion(dnsprofile)
                        return
                    case .failure(let error):
                        Log.general.error("Error getting DNS Profile: \(error)")
                        let urlString = "\(SecurityCenter.DNS_BACKUP)\(SecurityCenter.DNS_ENDPOINT)"
                        completion(urlString)
                        return
                    }
                }
        }
    }
    
    /// - Parameter retryUntilVerified: When true, a negative probe is retried a few times
    ///   before reporting disconnected. Pass this only right after DoT was freshly enabled
    ///   (onboarding auto-connect / manual connect), where the profile can take a few seconds
    ///   to become the live system resolver. The default (single probe) is correct for the
    ///   routine checks on foreground / appear / VPN status change.
    public func doDNSCheck(retryUntilVerified: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let attempts = retryUntilVerified ? SecurityCenter.dnsCheckMaxAttempts : 1
        performDNSCheck(attemptsRemaining: attempts, completion: completion)
    }

    private func performDNSCheck(attemptsRemaining: Int, isInitialAttempt: Bool = true, completion: ((Bool) -> Void)? = nil) {
        if isInitialAttempt {
            didFireEarlyDNSPrompt = false
        }
        if self.dnsTester == nil {
            self.dnsTester = DNSTester()
        }

        // Skip the network DNS test only when the tunnel is actually carrying traffic.
        // If on-demand is configured but the tunnel has been suppressed by a trusted-network
        // rule, the tunnel is inactive and we must verify DoT is still routing DNS.
        guard isVpnTunnelConnected() == false else {
            self.queryForDNSAnalytics()
            completion?(false)
            return
        }

        let host = "\(UUID().uuidString.prefix(8)).\(SecurityCenter.DNS_CHECK_ENDPOINT)"
        cancelPendingDNSCheck()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else {
                    completion?(false)
                    return
                }

                self.fetchApplicationActive { [weak self] stillActive in
                    guard let self = self else { return }
                    guard stillActive, self.isCurrentlyReachable else {
                        self.cancelPendingDNSCheck()
                        // We couldn't probe right now — the app is briefly inactive (e.g. the
                        // onboarding→main transition) or offline. This is transient and gives us
                        // NO information about DoT, so don't report a verdict. In retry mode, try
                        // again shortly instead of abandoning the chain; otherwise the foreground
                        // handler will re-check when the app becomes active again.
                        if attemptsRemaining > 1 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + SecurityCenter.dnsCheckRetryDelay) { [weak self] in
                                self?.performDNSCheck(attemptsRemaining: attemptsRemaining - 1, isInitialAttempt: false, completion: completion)
                            }
                        } else {
                            completion?(false)
                        }
                        return
                    }

                    guard let currentWorkItem = self.dnsCheckWorkItem, !currentWorkItem.isCancelled else {
                        completion?(false)
                        return
                    }

                    // Existing DNS resolution logic…
                    self.dnsTester?.resolveHostName(host) { [weak self] result in
                        guard let self = self else {
                            completion?(false)
                            return
                        }
                        guard let activeWorkItem = self.dnsCheckWorkItem, activeWorkItem === currentWorkItem, !activeWorkItem.isCancelled else {
                            completion?(false)
                            return
                        }
                        self.dnsCheckWorkItem = nil

                        if case .success(let ips) = result, ips.contains(SecurityCenter.DNS_CHECK_IP) {
                            Log.general.debug("Using DoT resolver")
                            self.isDoTVerifiedActive = true
                            self.dnsStatusDelegate?.dnsStatusUpdated(true)
                            completion?(true)
                            return
                        }

                        if case .failure(let error) = result {
                            Log.general.debug("DNS verification lookup failed: \(error.localizedDescription)")
                        }

                        // Negative result. The DoT profile may not be the live resolver yet
                        // (e.g. just activated at the end of onboarding), so retry a few times
                        // before reporting disconnected — otherwise one early probe loses the
                        // race and the stale verdict sticks until the next app foreground.
                        if attemptsRemaining > 1 {
                            // Surface the "select the profile in Settings" prompt as soon as a
                            // couple of probes have failed, instead of making the user wait out
                            // the full retry budget. The retries below keep running, so a profile
                            // that does come live will still flip the status (and dismiss the
                            // prompt) via dnsStatusUpdated(true).
                            let failuresSoFar = SecurityCenter.dnsCheckMaxAttempts - attemptsRemaining + 1
                            if !self.didFireEarlyDNSPrompt,
                               failuresSoFar >= SecurityCenter.dnsEarlyPromptFailureThreshold {
                                self.didFireEarlyDNSPrompt = true
                                self.dnsStatusDelegate?.dnsVerificationProbeFailedEarly()
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + SecurityCenter.dnsCheckRetryDelay) { [weak self] in
                                self?.performDNSCheck(attemptsRemaining: attemptsRemaining - 1, isInitialAttempt: false, completion: completion)
                            }
                            return
                        }

                        self.isDoTVerifiedActive = false
                        self.dnsStatusDelegate?.dnsStatusUpdated(false)
                        completion?(false)
                    }
                }
            }

            self.dnsCheckWorkItem = workItem
            // Settle delay before every probe. The total retry wall-clock (≈5 × this + retry
            // delays) is deliberately generous: the onboarding auto-connect path relies on it
            // to outlast both the DoT profile's activation latency and the transient .inactive
            // window during the onboarding→main transition. The manual-connect case no longer
            // waits this out for feedback — `dnsVerificationProbeFailedEarly` surfaces the
            // "select the profile in Settings" prompt after a couple of failures while these
            // retries keep running in the background.
            DispatchQueue.main.asyncAfter(deadline: .now() + SecurityCenter.dnsCheckInitialDelay, execute: workItem)
    }

    private var isCurrentlyReachable: Bool {
        guard let manager = reachabilityManager else { return true }
        return manager.isReachable
    }

    private var isApplicationActive: Bool {
        return UIApplication.shared.applicationState == .active
    }

    private func isReachable(status: NetworkReachabilityManager.NetworkReachabilityStatus) -> Bool {
        switch status {
        case .reachable(_):
            return true
        case .notReachable, .unknown:
            return false
        }
    }

    @objc private func applicationDidEnterBackground() {
        cancelPendingDNSCheck()
    }

    private func cancelPendingDNSCheck() {
        dnsCheckWorkItem?.cancel()
        dnsCheckWorkItem = nil
    }
    
    func getDNSAnalytics() -> String {
        let baseURL = SecurityCenter.DNS_API_ENDPOINT + "analytics"

        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let timeInterval = now.timeIntervalSince(startOfDay)
        let minutesSinceStartOfDay = Int(timeInterval / 60.0)

        return "\(baseURL)?from=-\(minutesSinceStartOfDay)m"
    }
    
    func getDNSCheck() -> String {
        return SecurityCenter.DNS_API_ENDPOINT + "check"
    }
    
    public func getLatestVersionsIfNeeded() {
        if needVersions {
            self.getLatestVersions()
        }
    }

    public func hasVersionsForToday() -> Bool {
        return Calendar.current.isDateInToday(self.lastVersionsCheck)
    }
    
    public func getLatestVersions(completion: ((Bool) -> Void)? = nil) {
        guard !SecurityCenter.isProxyDetected else { completion?(false); return }
        self.versionNeedsNotification = false

        Task { [weak self] in
            guard let self,
                  let headers = await GlacierAPIHeaders.authHeaders() else {
                completion?(false)
                return
            }
                
            sessionManager.request(SecurityCenter.VERSIONS_ENDPOINT, method: .get, encoding: URLEncoding.default, headers: headers)
                .validate()
                .responseData(queue: self.internalQueue) { response in
                    switch response.result {
                    case .success(let value):
                        let parsed: Any?
                        do {
                            parsed = try JSONSerialization.jsonObject(with: value, options: .allowFragments)
                        } catch {
                            Log.general.error("Failed to parse latest versions JSON: \(error)")
                            parsed = nil
                        }
                        if let json = parsed as? Dictionary<String,Any>,
                           let jversions = json["versions"] as? Dictionary<String,Any> {
                            let latestVersions = LatestVersions()
                            latestVersions.glacier = jversions["glacier"] as? String
                            latestVersions.ios = jversions["ios"] as? String
                            self.handleVersions(versions: latestVersions)
                        }
                        completion?(true)
                        return
                    case .failure(let error):
                        Log.general.error("Error getting Latest Versions: \(error)")
                        completion?(false)
                        return
                    }
            }
            
            self.needVersions = false
            self.lastVersionsCheck = Date()
        }
    }
    
    func handleVersions(versions: LatestVersions) {
        let curVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        
        //check our Glacier version vs latest
        if (curVersion != self.secInfoUtil.securityInfo.glacier_version) {
            self.secInfoUtil.secinfoNeedsUpdate = true
        }
        self.secInfoUtil.securityInfo.glacier_version = curVersion
        if let myVersion = curVersion, let latestVersion = versions.glacier, myVersion.compare(latestVersion, options: .numeric) == .orderedAscending {
            self.versionNeedsNotification = true
            
            if self.secInfoUtil.securityInfo.glacier_version_outdated == false {
                self.secInfoUtil.secinfoNeedsUpdate = true
            }
            self.secInfoUtil.securityInfo.glacier_version_outdated = true
        } else {
            if self.secInfoUtil.securityInfo.glacier_version_outdated == true {
                self.secInfoUtil.secinfoNeedsUpdate = true
            }
            self.secInfoUtil.securityInfo.glacier_version_outdated = false
        }
        
        //check our iOS version vs latest
        let osversion = UIDevice.current.systemVersion
        if osversion != self.secInfoUtil.securityInfo.os_version {
            self.secInfoUtil.secinfoNeedsUpdate = true
        }
        self.secInfoUtil.securityInfo.os_version = osversion
        
        if let latestios = versions.ios, self.iOS_VERSION_LESS_THAN(version: latestios) {
            self.versionNeedsNotification = true
            
            if self.secInfoUtil.securityInfo.os_version_outdated == false {
                self.secInfoUtil.secinfoNeedsUpdate = true
            }
            self.secInfoUtil.securityInfo.os_version_outdated = true
        } else {
            if self.secInfoUtil.securityInfo.os_version_outdated == true {
                self.secInfoUtil.secinfoNeedsUpdate = true
            }
            self.secInfoUtil.securityInfo.os_version_outdated = false
        }
        
        if self.versionNeedsNotification {
            self.needsNotification = true
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: SecurityCenter.securityCheckNotification, object: self, userInfo: ["needsNotification":self.needsNotification])
            }
        }
    }
    
    /*func handleResults(securityResults: String) {
        let curVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    
        do {
            let securityEl = try XMLElement.init(xmlString: securityResults)
            let glacierversion = securityEl.element(forName: "glacier")?.stringValue
            let latestiosversion = securityEl.element(forName: "ios")?.stringValue
            
            //check our Glacier version vs latest
            if (curVersion != self.secInfoUtil.securityInfo.glacier_version) {
                self.secInfoUtil.secinfoNeedsUpdate = true
            }
            self.secInfoUtil.securityInfo.glacier_version = curVersion
            if let myVersion = curVersion, let latestVersion = glacierversion, myVersion.compare(latestVersion, options: .numeric) == .orderedAscending {
                self.versionNeedsNotification = true
                
                if self.secInfoUtil.securityInfo.glacier_version_outdated == false {
                    self.secInfoUtil.secinfoNeedsUpdate = true
                }
                self.secInfoUtil.securityInfo.glacier_version_outdated = true
            } else {
                if self.secInfoUtil.securityInfo.glacier_version_outdated == true {
                    self.secInfoUtil.secinfoNeedsUpdate = true
                }
                self.secInfoUtil.securityInfo.glacier_version_outdated = false
            }
            
            //check our iOS version vs latest
            let osversion = UIDevice.current.systemVersion
            if osversion != self.secInfoUtil.securityInfo.os_version {
                self.secInfoUtil.secinfoNeedsUpdate = true
            }
            self.secInfoUtil.securityInfo.os_version = osversion
            
            if let latestios = latestiosversion, self.iOS_VERSION_LESS_THAN(version: latestios) {
                self.versionNeedsNotification = true
                
                if self.secInfoUtil.securityInfo.os_version_outdated == false {
                    self.secInfoUtil.secinfoNeedsUpdate = true
                }
                self.secInfoUtil.securityInfo.os_version_outdated = true
            } else {
                if self.secInfoUtil.securityInfo.os_version_outdated == true {
                    self.secInfoUtil.secinfoNeedsUpdate = true
                }
                self.secInfoUtil.securityInfo.os_version_outdated = false
            }
            
            if self.versionNeedsNotification {
                self.needsNotification = true
            }
                
        } catch {
            Log.general.error("Failure parsing latest iOS/Glacier versions")
        }
    }*/
    
    public func setVersionIssue(_ versionIssue: Bool) {
        self.versionNeedsNotification = versionIssue
    }
    
    func iOS_VERSION_LESS_THAN(version: String) -> Bool {
        return UIDevice.current.systemVersion.compare(version, options: .numeric) == ComparisonResult.orderedAscending
    }
    
    public func devicePasscodeEnabled() -> Bool {
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
        
    public func deviceBiometricsEnabled() -> Bool {
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }
}

public class SecurityInfoUtil:NSObject {
    var secinfoNeedsUpdate = false
    var securityInfo: SecurityInfo
    
    override public init() {
        self.securityInfo = SecurityInfo()
        self.securityInfo.deviceid = UIDevice.current.identifierForVendor?.uuidString
        
        //fill the basics
        self.securityInfo.device = UIDevice.modelName
        self.securityInfo.os_version = UIDevice.current.systemVersion
        self.securityInfo.glacier_version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        self.securityInfo.compromised_detail = "none"
        self.securityInfo.os_patch = "none"
        self.secinfoNeedsUpdate = true
        super.init()
    }
    
    public func setNeedsUpdate() {
        self.secinfoNeedsUpdate = true
    }
    
    public func setLastUpdated() {
        let lastupdated = Date().formatted(date: .complete, time: .standard).replacingOccurrences(of: " at", with: ",")
        let cleanDate = lastupdated.replacingOccurrences(of: "\u{202F}", with: " ")
        self.securityInfo.last_updated = cleanDate
    }
    
    public func getJson() -> String {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(self.securityInfo)
            if let jsonString = String(data: data, encoding: .utf8) {
                return jsonString
            }
        } catch {
            Log.general.error("Failed to encode securityInfo to JSON: \(error)")
        }
        
        /*let dict = ["deviceid": sDeviceId, "device": sDevice, "glacier_version": sGlacierVersion,
                   "glacier_version_outdated": String(sGlacierOutdated), "os_version": sOsVersion, "os_version_outdated": String(sOsOutdated), "os_patch": sOsPatch, "compromised": String(sCompromised), "compromised_detail": sCompromisedDetail, "screen_lock": String(sScreenLock), "biometric_lock": String(sBiometricLock), "core_enabled": String(sCoreEnabled)];
        
        let encoder = JSONEncoder()
        if let jsonData = try? encoder.encode(dict) {
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
        }*/
        return ""
    }
    
    public func equals(secinfo: Dictionary<String, Any>) -> Bool {
        let outdatedGlacier = secinfo["glacier_version_outdated"] as? Bool ?? false
        let outdatedOs = secinfo["os_version_outdated"] as? Bool ?? false
        let compromised = secinfo["compromised"] as? Bool ?? false
        let screenLock = secinfo["screen_lock"] as? Bool ?? false
        let biometricLock = secinfo["biometric_lock"] as? Bool ?? false
        let coreEnabled = secinfo["core_enabled"] as? Bool ?? false
        
        if secinfo["deviceid"] as? String == securityInfo.deviceid, secinfo["device"] as? String == securityInfo.device, secinfo["glacier_version"] as? String == securityInfo.glacier_version, outdatedGlacier == securityInfo.glacier_version_outdated, secinfo["os_version"] as? String == securityInfo.os_version, outdatedOs == securityInfo.os_version_outdated, secinfo["os_patch"] as? String == securityInfo.os_patch, compromised == securityInfo.compromised, secinfo["compromised_detail"] as? String == securityInfo.compromised_detail, screenLock == securityInfo.screen_lock, biometricLock == securityInfo.biometric_lock, coreEnabled == securityInfo.core_enabled {
            return true
        }
        return false
    }
}

//IOSM#48
public class SecurityInfo:NSObject, Codable {
    var deviceid: String?
    var device: String?
    var glacier_version: String?
    var glacier_version_outdated = false
    var os_version: String?
    var os_version_outdated = false
    var os_patch: String?
    var compromised = false
    var compromised_detail: String?
    var screen_lock = false
    var biometric_lock = false
    var core_enabled = false
    var last_updated: String?
}
