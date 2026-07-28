//
//  DnsOverTlsPreferences.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

struct DnsOverTlsConfiguration: Equatable {
    var urlString: String?
    var isEnabled: Bool

    func sanitized() -> DnsOverTlsConfiguration {
        let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasURL = !(trimmed?.isEmpty ?? true)
        return DnsOverTlsConfiguration(urlString: hasURL ? trimmed : nil,
                                       isEnabled: hasURL ? isEnabled : false)
    }
}

extension Notification.Name {
    static let dnsOverTlsConfigurationDidChange = Notification.Name("DnsOverTlsConfigurationDidChange")
}

/// Stores the global DNS-over-TLS configuration so it can be toggled separately
/// from WireGuard tunnels.
final class DnsOverTlsPreferences {
    static let shared = DnsOverTlsPreferences()

    private enum Keys {
        static let url = "dnsOverTls.global.url"
        static let enabled = "dnsOverTls.global.enabled"
        // Shared with the packet-tunnel extension (PacketTunnelDnsPreferences), which writes
        // IPv4-preferred, NAT64-aware last-known-good DoT server IPs here while the tunnel runs.
        static let resolvedServers = "dnsOverTls.global.resolvedServers"
        // Full SHA-256 hex digest (64 chars) that seeds the `glr-<hash>` DoT hostname label.
        // Written once by the app (see DnsOverTlsController.seedDeviceLabelHashIfNeeded) and read
        // by both the app and the packet-tunnel extension. Storing the digest — not the raw device
        // identifier — means no Apple device identifier is persisted or re-read after seeding.
        static let deviceLabelHash = "dnsOverTls.deviceLabelHash"
        static let appGroupIdentifier = "group.com.theglacierapp.GlacierApp"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults? = UserDefaults(suiteName: Keys.appGroupIdentifier)) {
        self.userDefaults = userDefaults ?? .standard
    }

    func currentConfiguration() -> DnsOverTlsConfiguration {
        let savedURL = userDefaults.string(forKey: Keys.url)
        let enabled = userDefaults.bool(forKey: Keys.enabled)
        let configuration = DnsOverTlsConfiguration(urlString: savedURL, isEnabled: enabled)
        return configuration.sanitized()
    }

    func save(configuration: DnsOverTlsConfiguration) {
        let sanitized = configuration.sanitized()
        if let url = sanitized.urlString {
            userDefaults.set(url, forKey: Keys.url)
            userDefaults.set(sanitized.isEnabled, forKey: Keys.enabled)
        } else {
            userDefaults.removeObject(forKey: Keys.url)
            userDefaults.set(false, forKey: Keys.enabled)
        }
        NotificationCenter.default.post(name: .dnsOverTlsConfigurationDidChange, object: self)
    }

    /// Last set of successfully-resolved DoT server IP addresses, or an empty array if none have
    /// been persisted yet. Written by the packet-tunnel extension (IPv4-preferred, NAT64-aware)
    /// while the tunnel runs, and by the app when it re-resolves. These are used as a bootstrap
    /// source when the tunnel is suppressed and the system resolver is pinned to a dead DoT profile,
    /// so they must not be resolved through `getaddrinfo`/`CFHost` at that point.
    func savedResolvedServers() -> [String] {
        return userDefaults.stringArray(forKey: Keys.resolvedServers) ?? []
    }

    /// Persists successfully-resolved DoT server IP addresses as the last-known-good set.
    func saveResolvedServers(_ servers: [String]) {
        if servers.isEmpty {
            userDefaults.removeObject(forKey: Keys.resolvedServers)
        } else {
            userDefaults.set(servers, forKey: Keys.resolvedServers)
        }
    }

    /// Full SHA-256 hex digest that seeds the DoT hostname label, or nil if it hasn't been
    /// seeded yet. See DnsOverTlsController.seedDeviceLabelHashIfNeeded.
    func deviceLabelHash() -> String? {
        return userDefaults.string(forKey: Keys.deviceLabelHash)
    }

    /// Persists the SHA-256 hex digest used to derive the DoT hostname label. Written once at
    /// first trustworthy launch; never overwritten thereafter.
    func saveDeviceLabelHash(_ digest: String) {
        userDefaults.set(digest, forKey: Keys.deviceLabelHash)
    }
}
