//
//  DnsOverTlsController.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Network
import NetworkExtension
import UIKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import CryptoKit

enum DnsOverTlsControllerError: LocalizedError {
    case invalidURL(String)
    case unsupportedScheme(String)
    case missingHost
    case unsupportedPort
    case hostResolutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return String(format: NSLocalizedString("'%@' is not a valid URL.", comment: "Invalid DNS URL"), value)
        case .unsupportedScheme(let scheme):
            return String(format: NSLocalizedString("DNS URLs must use the tls:// scheme (got '%@').", comment: "Unsupported scheme message"), scheme)
        case .missingHost:
            return NSLocalizedString("Enter a DNS server hostname.", comment: "Missing host message")
        case .unsupportedPort:
            return NSLocalizedString("Custom DNS ports aren't supported.", comment: "Unsupported port message")
        case .hostResolutionFailed(let host):
            return String(format: NSLocalizedString("Unable to resolve '%@'. Check the hostname and try again.",
                                                  comment: "DoT host resolution failure"), host)
        }
    }
}

/// Applies DNS-over-TLS preferences using `NEDNSSettingsManager` so the resolver
/// can be toggled independently from WireGuard tunnels.
final class DnsOverTlsController {
    static let shared = DnsOverTlsController()

    /// Network Extension reports a no-op save with this (private) domain/code pair. It's a
    /// "configuration is unchanged" signal, not a failure, so saving the same DoT settings twice
    /// is treated as success. NEConfigurationErrorDomain isn't a public symbol, hence the literals.
    private static let neConfigurationErrorDomain = "NEConfigurationErrorDomain"
    private static let neConfigurationUnchangedCode = 9
    /// "Configuration is stale" — the manager's loaded copy was superseded before our save landed.
    /// Reported as `NEDNSSettingsManagerError.configurationStale` (3) by the DNS-settings layer, and
    /// as code 5 by the configuration layer underneath it, depending on which one rejects the write.
    private static let neDNSSettingsErrorDomain = "NEDNSSettingsErrorDomain"
    private static let neDNSSettingsStaleCode = 3
    private static let neConfigurationStaleCode = 5

    private let preferences: DnsOverTlsPreferences
    private let dnsManager: NEDNSSettingsManager
    private let workQueue = DispatchQueue(label: "com.theglacierapp.dnsOverTls.controller")
    private let bogusDomain = "kljh345jkl.com"
    private var resolvedHosts: [String]
    private let resolveServerAddress: (String) throws -> [String]
    private var cachedResolvedServers: [String]?
    private var cachedResolvedHost: String?
    /// When the user last explicitly disabled DoT (via `apply(isEnabled: false)`), or nil if the
    /// most recent apply was an enable. Guarded by `workQueue`. Used by
    /// `refreshDoTResolutionIfSuppressed` to avoid re-enabling a profile the user is deliberately
    /// turning off right now — e.g. the one-tap "turn off VPN + DNS" path, whose incidental
    /// tunnel-inactive event would otherwise fire a heal before the disable has persisted.
    private var lastUserDisableAt: Date?
    /// How long after an explicit disable the resilience heal stays suppressed. Comfortably covers
    /// the lag between `startDeactivation` and the tunnel reporting inactive (a few seconds); a
    /// subsequent enable clears the suppression outright, so this never blocks a genuine later heal.
    private static let healSuppressionWindow: TimeInterval = 8

    init(preferences: DnsOverTlsPreferences = .shared,
         dnsManager: NEDNSSettingsManager = .shared(),
         resolveServerAddress: @escaping (String) throws -> [String] = { host in
             try DnsOverTlsController.resolveServerAddress(for: host)
         }) {
        self.preferences = preferences
        self.dnsManager = dnsManager
        self.resolvedHosts = []
        self.resolveServerAddress = resolveServerAddress
        self.cachedResolvedServers = nil
        self.cachedResolvedHost = nil
    }

    func loadSavedConfiguration() -> DnsOverTlsConfiguration {
        preferences.currentConfiguration()
    }
    
    func storeNewConfiguration(_ dnsUrl: String) {
        let configuration = DnsOverTlsConfiguration(urlString: dnsUrl, isEnabled: false)
        self.preferences.save(configuration: configuration)
    }

    func apply(configuration: DnsOverTlsConfiguration,
               completion: @escaping (Result<DnsOverTlsConfiguration, Error>) -> Void) {
        let sanitized = configuration.sanitized()
        workQueue.async {
            // Record disable intent (and clear it on enable) so an incidental resilience heal can't
            // re-enable a profile the user just turned off. See `refreshDoTResolutionIfSuppressed`.
            self.lastUserDisableAt = sanitized.isEnabled ? nil : Date()
            self.dnsManager.loadFromPreferences { loadError in
                if let loadError = loadError {
                    let ns = loadError as NSError
                    Log.vpn.error("DoT apply(isEnabled=\(sanitized.isEnabled, privacy: .public)): loadFromPreferences failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
                    DispatchQueue.main.async {
                        completion(.failure(loadError))
                    }
                    return
                }

                self.dnsManager.localizedDescription = NSLocalizedString("Glacier", comment: "DNS preference label")

                guard let urlString = sanitized.urlString else {
                    DispatchQueue.main.async {
                        completion(.failure(DnsOverTlsControllerError.invalidURL("")))
                    }
                    return
                }

                guard let components = URLComponents(string: urlString) else {
                    DispatchQueue.main.async {
                        completion(.failure(DnsOverTlsControllerError.invalidURL(urlString)))
                    }
                    return
                }

                if let scheme = components.scheme?.lowercased(), !scheme.isEmpty, scheme != "tls" {
                    DispatchQueue.main.async {
                        completion(.failure(DnsOverTlsControllerError.unsupportedScheme(scheme)))
                    }
                    return
                }

                guard let host = components.host, !host.isEmpty else {
                    DispatchQueue.main.async {
                        completion(.failure(DnsOverTlsControllerError.missingHost))
                    }
                    return
                }

                if components.port != nil {
                    DispatchQueue.main.async {
                        completion(.failure(DnsOverTlsControllerError.unsupportedPort))
                    }
                    return
                }

                let serverName = host
                let resolvedHostsAr: [String]
                if sanitized.isEnabled {
                    do {
                        if let cachedResolvedServers = self.cachedResolvedServers,
                           self.cachedResolvedHost == host {
                            resolvedHostsAr = cachedResolvedServers
                        } else {
                            resolvedHostsAr = try self.resolveServerAddress(host)
                            self.cachedResolvedServers = resolvedHostsAr
                            self.cachedResolvedHost = host
                        }
                    } catch {
                        let resolutionError: Error
                        if let dotError = error as? DnsOverTlsControllerError {
                            resolutionError = dotError
                        } else {
                            resolutionError = DnsOverTlsControllerError.hostResolutionFailed(host)
                        }

                        DispatchQueue.main.async {
                            completion(.failure(resolutionError))
                        }
                        return
                    }
                } else {
                    // Disabling DoT must never depend on a system DNS lookup *when an active
                    // Glacier DoT profile already exists*: the system resolver may be pinned to the
                    // very profile we're turning off, so a lookup could hang/fail and strand the
                    // user. So prefer the server IPs already in the loaded configuration (valid IPs
                    // from when DoT was enabled; they persist across launches), then the in-memory
                    // cache. We must NOT fabricate a server from the hostname: NEDNSOverTLSSettings
                    // requires IP addresses, so a hostname makes saveToPreferences fail with
                    // NEConfigurationErrorDomain Code=2 ("Invalid DNS server").
                    if let existing = self.dnsManager.dnsSettings as? NEDNSOverTLSSettings,
                       !existing.servers.isEmpty {
                        resolvedHostsAr = existing.servers
                    } else if let cached = (self.cachedResolvedHost == host ? self.cachedResolvedServers : nil),
                              !cached.isEmpty {
                        resolvedHostsAr = cached
                    } else {
                        // No servers to reuse means no active DoT profile is pinning the resolver,
                        // so this is a first-time profile *creation* in the disabled state (e.g.
                        // onboarding's storeNewConfiguration + apply(isEnabled: false)), not the
                        // disconnect of an active profile. Resolving is safe here and is required
                        // to write a valid profile, which needs IP addresses rather than a hostname.
                        do {
                            resolvedHostsAr = try self.resolveServerAddress(host)
                            self.cachedResolvedServers = resolvedHostsAr
                            self.cachedResolvedHost = host
                        } catch {
                            let resolutionError = (error as? DnsOverTlsControllerError)
                                ?? DnsOverTlsControllerError.hostResolutionFailed(host)
                            DispatchQueue.main.async {
                                completion(.failure(resolutionError))
                            }
                            return
                        }
                    }
                }

                // Prefer IPv4, cap the list — mirrors the extension's preferredServerList so the
                // profile is pinned to globally-routable IPs rather than a network-local NAT64 IPv6
                // that dies after a network switch (the root cause of DNS breaking while suppressed).
                let servers = DnsOverTlsController.preferredServerList(from: resolvedHostsAr, fallbackHost: host)
                self.resolvedHosts = resolvedHostsAr
                // Persist IP-only servers as last-known-good so an off-tunnel refresh can bootstrap
                // without the system resolver (which is pinned to this very profile). Never persist a
                // bare hostname.
                let ipServers = servers.filter { IPv4Address($0) != nil || IPv6Address($0) != nil }
                if !ipServers.isEmpty {
                    self.preferences.saveResolvedServers(ipServers)
                }
                let tlsSettings = NEDNSOverTLSSettings(servers: servers)
                tlsSettings.serverName = serverName

                tlsSettings.matchDomains = [""]
                if !sanitized.isEnabled {
                    tlsSettings.matchDomains = [self.bogusDomain]
                }
                //tlsSettings.strictPrivacy = true
                self.stageManagerSettings(tlsSettings)
                self.savePreferences(sanitized, settings: tlsSettings, completion: completion)
            }
        }
    }
    
    func getResolvedHosts() -> [String] {
        return self.resolvedHosts
    }
    
    /// SHA-256 of `input`, rendered as a lowercase hex string (64 chars).
    private static func sha256Hex(_ input: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Establishes the stored digest that seeds the `glr-<hash>` DoT hostname label. Runs once
    /// per install at the first trustworthy launch and is a no-op afterwards (the digest is never
    /// overwritten).
    ///
    /// - Existing installs (`isExistingUser == true`, i.e. an in-place update of a user with prior
    ///   local state) preserves the exact hostname and keeps backend continuity.
    /// - Fresh installs / reinstalls (`isExistingUser == false`) are seeded from a random UUID, so
    ///   no Apple device identifier is ever derived into the hostname that leaves the device.
    ///
    /// The caller must pass `isExistingUser` computed from local state snapshotted before the auth
    /// session is fetched (see GlacierApplicationDelegate.tryFetchSession), and must only call this
    /// on a trustworthy launch (protected data available, cache not poisoned) so an existing user
    /// is never misclassified as new.
    func seedDeviceLabelHashIfNeeded(isExistingUser: Bool) {
        guard preferences.deviceLabelHash() == nil else { return }

        let source: String
        if isExistingUser, let idfv = UIDevice.current.identifierForVendor?.uuidString {
            source = idfv
        } else {
            // New install, or an existing install with no ID available (no stable prior label to
            // preserve) — either way a random, non-device-derived seed is correct.
            source = UUID().uuidString
        }
        preferences.saveDeviceLabelHash(Self.sha256Hex(source))
    }

    func shortDeviceID(prefix: String = "glr", length: Int = 10) -> String {
        // Authoritative path: derive the label from the stored (non-device-derived for new
        // installs) digest seeded at launch.
        if let digest = preferences.deviceLabelHash() {
            return "\(prefix)-\(String(digest.prefix(length)))"
        }

        // Fallback: reached only if a DoT label is needed before the launch-time seed has run
        // (e.g. an untrustworthy first launch). Reproduce the legacy ID value so an
        // existing install keeps its exact label; this is NOT persisted, so the authoritative
        // seed still writes the correct digest later. A new install cannot reach this in practice
        // because seeding runs at launch before any DoT configuration is built.
        guard let uuid = UIDevice.current.identifierForVendor?.uuidString else {
            return "\(prefix)-unknown"
        }
        let shortHash = String(Self.sha256Hex(uuid).prefix(length))
        return "\(prefix)-\(shortHash)"
    }
    
    /// Called when the user intentionally enables the VPN.
    /// Ensures the DoT profile has full matchDomains coverage (`[""]`) so DNS remains
    /// protected whenever the tunnel is suppressed by on-demand/trusted-network rules.
    ///
    /// - `urlProvider`: closure that fetches and returns the DoT URL string when none is
    ///   stored locally. Called only if the local configuration has no URL yet.
    /// - `completion`: receives the updated configuration on success, or an error.
    func ensureEnabledForVPN(
        urlProvider: @escaping (@escaping (String?) -> Void) -> Void,
        completion: @escaping (Result<DnsOverTlsConfiguration, Error>) -> Void
    ) {
        let saved = loadSavedConfiguration()

        // A stored URL that points at the shared backup profile counts as "no URL" here. Simply
        // enabling it would switch on a profile that isn't the user's — tracker count stuck at
        // zero, their own blocklists never applied — and turning the tunnel on then removes the
        // means to correct it: DoT verification is skipped while the tunnel carries traffic, so
        // `DNSProfileHealer`'s verified-baseline trigger can't fire for as long as the VPN stays
        // up. This is the one moment we know the user is actively asking for protection, so fetch
        // the account's own profile and replace it here instead.
        let isPinnedToSharedProfile = DNSProfileHealer.isPinnedToBackupProfile(saved.urlString)

        guard saved.urlString == nil || isPinnedToSharedProfile else {
            // URL already on file — just make sure isEnabled is true.
            let enabled = DnsOverTlsConfiguration(urlString: saved.urlString, isEnabled: true)
            apply(configuration: enabled, completion: completion)
            return
        }

        // No usable URL yet (the user skipped DNS onboarding, or what's stored is the shared
        // profile) — fetch the account's own profile, store it, then enable.
        urlProvider { [weak self] urlString in
            guard let self else {
                completion(.failure(DnsOverTlsControllerError.missingHost))
                return
            }
            guard let urlString, !urlString.isEmpty,
                  !DNSProfileHealer.isPinnedToBackupProfile(urlString) else {
                guard isPinnedToSharedProfile, let existingURLString = saved.urlString else {
                    // Nothing to fall back to; skip silently so VPN connect still works.
                    completion(.failure(DnsOverTlsControllerError.missingHost))
                    return
                }
                // No personal profile available right now. Enable what is already stored: the
                // shared profile does filter, and that beats leaving DNS unprotected whenever
                // on-demand suppresses the tunnel on a trusted network. The heal corrects the
                // profile once the account has one.
                Log.vpn.notice("ensureEnabledForVPN: no personal DNS profile available; enabling the existing shared-profile configuration for now.")
                let enabled = DnsOverTlsConfiguration(urlString: existingURLString, isEnabled: true)
                self.apply(configuration: enabled, completion: completion)
                return
            }
            if isPinnedToSharedProfile {
                Log.vpn.notice("ensureEnabledForVPN: replacing a shared-profile configuration with this account's own profile before enabling DoT.")
            }
            self.storeNewConfiguration(urlString)
            let enabled = DnsOverTlsConfiguration(urlString: urlString, isEnabled: true)
            self.apply(configuration: enabled, completion: completion)
        }
    }

    /// Clears the in-memory resolved-server cache so the next `apply` re-resolves from scratch.
    /// `apply` short-circuits on this cache when `cachedResolvedHost == host`, so clearing it is
    /// what forces a fresh resolution.
    func clearResolvedServerCache() {
        workQueue.async {
            self.cachedResolvedServers = nil
            self.cachedResolvedHost = nil
        }
    }

    /// Re-resolves and re-applies the system-wide DoT profile when it is enabled but the WireGuard
    /// tunnel is NOT active (suppressed by on-demand on a trusted network). In that state the tunnel's
    /// own DNS proxy is not running, so the system DoT profile is the only thing steering DNS; if its
    /// pinned server IPs became unroutable after a network change, all DNS fails until the profile is
    /// refreshed. Bootstraps fresh IPs WITHOUT using the system resolver (which is pinned to the very
    /// profile that may be broken), then re-applies via the existing `apply` plumbing. Never points the
    /// profile at empty/hostname servers.
    ///
    /// - `isTunnelConnected`: whether a WireGuard tunnel is actively connected. Pass the value from
    ///   `SecurityCenter.isVpnTunnelConnected()` — NOT `isVpnEnabled()`, which is true whenever
    ///   on-demand is configured even while suppressed. When the tunnel is connected the extension
    ///   owns DNS via its proxy, so this is a no-op.
    func refreshDoTResolutionIfSuppressed(
        isTunnelConnected: Bool,
        completion: ((Result<DnsOverTlsConfiguration, Error>) -> Void)? = nil
    ) {
        let saved = loadSavedConfiguration()
        guard saved.isEnabled, !isTunnelConnected,
              let urlString = saved.urlString,
              let host = URLComponents(string: urlString)?.host, !host.isEmpty else {
            completion?(.failure(DnsOverTlsControllerError.missingHost))
            return
        }

        let bootstrapIPs = bootstrapResolvedServers(for: host)
        guard !bootstrapIPs.isEmpty else {
            // No usable IPs available without the system resolver — leave the existing profile intact
            // rather than risk writing empty/invalid servers (a hostname fails save with
            // NEConfigurationErrorDomain code 2). A later trigger heals it once IPs are available.
            Log.vpn.notice("DoT refresh skipped: no bootstrap IPs available; leaving profile intact")
            completion?(.failure(DnsOverTlsControllerError.hostResolutionFailed(host)))
            return
        }

        // All of the following runs on the serial workQueue so the suppression check and the
        // cache seed observe (and precede) any in-flight explicit disable. workQueue is serial, so
        // apply()'s own workQueue block runs after this one.
        workQueue.async {
            // Don't fight a deliberate disable. When the user turns DoT off (e.g. the one-tap
            // "turn off VPN + DNS"), the disconnect's tunnel-inactive event lands here, but the
            // disable may not have persisted yet — re-enabling would leave DNS stuck on. A recent
            // disable means "leave it off"; a later enable clears the window so genuine heals run.
            if let disabledAt = self.lastUserDisableAt,
               Date().timeIntervalSince(disabledAt) < DnsOverTlsController.healSuppressionWindow {
                Log.vpn.notice("DoT refresh skipped: user disabled DoT within the suppression window")
                DispatchQueue.main.async {
                    completion?(.failure(DnsOverTlsControllerError.missingHost))
                }
                return
            }
            // Seed the cache so apply() writes exactly these bootstrapped IPs instead of re-resolving
            // through the (possibly broken) system resolver.
            self.cachedResolvedServers = bootstrapIPs
            self.cachedResolvedHost = host
            Log.vpn.notice("DoT refresh: re-applying enabled profile with \(bootstrapIPs.count, privacy: .public) bootstrap IP(s) while tunnel suppressed")
            self.apply(configuration: DnsOverTlsConfiguration(urlString: urlString, isEnabled: true)) { result in
                completion?(result)
            }
        }
    }

    /// Returns fresh DoT server IPs WITHOUT using the system name resolver (which the DoT profile
    /// hijacks). Order: (1) last-known-good IPs persisted by the extension/app, IPv4-preferred and
    /// NAT64-aware; (2) IP-only servers already installed in the current profile. Returns [] if
    /// neither yields usable IP addresses — the caller then leaves the profile untouched.
    private func bootstrapResolvedServers(for host: String) -> [String] {
        let persisted = preferences.savedResolvedServers().filter {
            IPv4Address($0) != nil || IPv6Address($0) != nil
        }
        if !persisted.isEmpty {
            return DnsOverTlsController.preferredServerList(from: persisted, fallbackHost: host)
        }
        if let existing = (dnsManager.dnsSettings as? NEDNSOverTLSSettings)?.servers {
            let ipOnly = existing.filter { IPv4Address($0) != nil || IPv6Address($0) != nil }
            if !ipOnly.isEmpty {
                return DnsOverTlsController.preferredServerList(from: ipOnly, fallbackHost: host)
            }
        }
        return []
    }

    /// Prefers IPv4, then IPv6, capped at `limit`. Mirrors the extension's
    /// `PacketTunnelDNSConfigurator.preferredServerList` so app- and extension-pinned IPs match.
    /// Falls back to the hostname only when no addresses are available (callers guard against
    /// persisting/installing a bare hostname).
    static func preferredServerList(from resolvedServers: [String], fallbackHost: String, limit: Int = 4) -> [String] {
        guard !resolvedServers.isEmpty else {
            return [fallbackHost]
        }
        let ipv4Addresses = resolvedServers.filter { IPv4Address($0) != nil }
        let ipv6Addresses = resolvedServers.filter { IPv6Address($0) != nil }
        var prioritized = ipv4Addresses + ipv6Addresses
        if prioritized.isEmpty {
            prioritized = resolvedServers
        }
        if prioritized.count > limit {
            prioritized = Array(prioritized.prefix(limit))
        }
        return prioritized
    }

    func removeDoTProfile() {
        self.dnsManager.loadFromPreferences { error in
            if let error = error {
                Log.vpn.error("Failed to load preferences: \(error)")
                return
            }

            // If a DNS profile exists, remove it
            self.dnsManager.removeFromPreferences { error in
                if let error = error {
                    Log.vpn.error("Failed to remove DNS profile: \(error)")
                } else {
                    Log.vpn.notice("DNS profile removed successfully")
                    let configuration = DnsOverTlsConfiguration(urlString: nil, isEnabled: false)
                    self.preferences.save(configuration: configuration)
                }
            }
        }
    }

    static func resolveServerAddress(for host: String) throws -> [String] {
        if IPv4Address(host) != nil || IPv6Address(host) != nil {
            return [host]
        }

        var hints = addrinfo(
            ai_flags: 0,              // No AI_ADDRCONFIG — allows results on IPv6-only cellular networks
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM, // TCP — correct for DoT; required to trigger NAT64/DNS64 synthesis
            ai_protocol: IPPROTO_TCP, // TCP — required for iOS to synthesize IPv6 addresses via NAT64
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var res: UnsafeMutablePointer<addrinfo>?
        let errorCode = getaddrinfo(host, nil, &hints, &res)
        guard errorCode == 0, let results = res else {
            throw DnsOverTlsControllerError.hostResolutionFailed(host)
        }
        defer { freeaddrinfo(results) }

        var pointer: UnsafeMutablePointer<addrinfo>? = results
        var resolvedAddresses: [String] = []
        var seen = Set<String>()
        while let current = pointer {
            if let addr = current.pointee.ai_addr {
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let conversion = getnameinfo(addr,
                                             socklen_t(current.pointee.ai_addrlen),
                                             &hostBuffer,
                                             socklen_t(hostBuffer.count),
                                             nil,
                                             0,
                                             NI_NUMERICHOST)
                if conversion == 0, let resolved = String(validatingUTF8: hostBuffer), !resolved.isEmpty {
                    if seen.insert(resolved).inserted {
                        resolvedAddresses.append(resolved)
                    }
                }
            }
            pointer = current.pointee.ai_next
        }
        return resolvedAddresses
    }

    /// Puts the intended DoT settings onto the shared `NEDNSSettingsManager`. Separate from `apply`
    /// because a stale-configuration retry has to re-stage them: `loadFromPreferences` replaces
    /// whatever is in memory with what is on disk, discarding the settings we were trying to save.
    private func stageManagerSettings(_ settings: NEDNSSettings) {
        dnsManager.localizedDescription = NSLocalizedString("Glacier", comment: "DNS preference label")
        dnsManager.dnsSettings = settings
    }

    private static func isStaleConfigurationError(_ error: NSError) -> Bool {
        (error.domain == neDNSSettingsErrorDomain && error.code == neDNSSettingsStaleCode)
            || (error.domain == neConfigurationErrorDomain && error.code == neConfigurationStaleCode)
    }

    private func savePreferences(_ configuration: DnsOverTlsConfiguration,
                                 settings: NEDNSSettings,
                                 retryOnStale: Bool = true,
                                 completion: @escaping (Result<DnsOverTlsConfiguration, Error>) -> Void) {
        self.dnsManager.saveToPreferences { saveError in
            DispatchQueue.main.async {
                if let saveError = saveError {
                    let ns = saveError as NSError
                    // "Configuration is unchanged" (NEConfigurationErrorDomain code 9) is not a
                    // real failure: the DoT settings we're saving already match what's in the
                    // Network Extension store, so the profile is already in the desired state.
                    // Treat it as success — persist our enabled flag and post
                    // .dnsOverTlsConfigurationDidChange so the verification probe runs and, if the
                    // profile isn't selected in iOS Settings yet, the "select in Settings" prompt
                    // appears. Reporting it as an error would strand the connect with no probe and
                    // no UI feedback.
                    if ns.domain == Self.neConfigurationErrorDomain,
                       ns.code == Self.neConfigurationUnchangedCode {
                        Log.vpn.notice("DoT apply(isEnabled=\(configuration.isEnabled, privacy: .public)): saveToPreferences reported configuration unchanged; treating as success")
                        self.preferences.save(configuration: configuration)
                        completion(.success(configuration))
                        return
                    }
                    // "Configuration is stale": another save landed between our `loadFromPreferences`
                    // and this one, so iOS refuses the write. Nothing is wrong with what we are
                    // saving — reload, re-stage it, and save once more. Seen at launch, where more
                    // than one path can apply DoT in the same moment; without this the loser is
                    // dropped and nothing retries until the next trigger, which for the healer means
                    // a heal deferred to the next launch and, worse, a revert that never lands.
                    if retryOnStale, Self.isStaleConfigurationError(ns) {
                        Log.vpn.notice("DoT apply(isEnabled=\(configuration.isEnabled, privacy: .public)): configuration was stale; reloading and saving once more")
                        self.dnsManager.loadFromPreferences { loadError in
                            if let loadError = loadError {
                                let loadNS = loadError as NSError
                                Log.vpn.error("DoT apply(isEnabled=\(configuration.isEnabled, privacy: .public)): reload after stale configuration failed domain=\(loadNS.domain, privacy: .public) code=\(loadNS.code, privacy: .public)")
                                DispatchQueue.main.async { completion(.failure(loadError)) }
                                return
                            }
                            self.stageManagerSettings(settings)
                            self.savePreferences(configuration,
                                                 settings: settings,
                                                 retryOnStale: false,
                                                 completion: completion)
                        }
                        return
                    }
                    Log.vpn.error("DoT apply(isEnabled=\(configuration.isEnabled, privacy: .public)): saveToPreferences failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public)")
                    completion(.failure(saveError))
                } else {
                    self.preferences.save(configuration: configuration)
                    completion(.success(configuration))
                }
            }
        }
    }
}
