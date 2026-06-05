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
}
