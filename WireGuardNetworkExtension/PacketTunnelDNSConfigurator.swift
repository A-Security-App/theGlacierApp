//
//  PacketTunnelDNSConfigurator.swift
//  WireGuardNetworkExtension
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import CryptoKit
import Foundation
import Network
import NetworkExtension
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

private let log = Logger(subsystem: "com.theglacierapp.Glacier", category: "dns-configurator")

/// Mirrors the DNS-over-TLS configuration stored in the shared app group and
/// applies it to the packet tunnel's DNS settings.
final class PacketTunnelDNSConfigurator {

    struct ProxyConfiguration: Equatable {
        let serverName: String
        let port: UInt16
        let resolvedAddresses: [String]
    }

    private let preferences = PacketTunnelDnsPreferences()
    private var cachedConfiguration: PacketTunnelDnsConfiguration?
    private var cachedResolvedServers: [String]?
    private var cachedResolvedHost: String?

    func prepareDefaultConfigurationIfNeeded() {
        if !preferences.hasSavedConfiguration() {
            guard let endpoint = dnsEndpoint(), !endpoint.isEmpty else {
                cachedConfiguration = PacketTunnelDnsConfiguration(urlString: nil, isEnabled: false)
                return
            }

            let deviceID = Self.shortDeviceID(length: 12)
            let urlString = "tls://\(deviceID)-\(endpoint)"
            let configuration = PacketTunnelDnsConfiguration(urlString: urlString, isEnabled: false).sanitized()
            preferences.save(configuration: configuration)
            cachedConfiguration = configuration
        } else {
            cachedConfiguration = preferences.currentConfiguration()
        }
    }
    
    func getServerUrl() -> String? {
        return self.cachedConfiguration?.urlString
    }

    /// Clears the in-memory resolved-server cache so that the next call to `applyDnsSettings`
    /// will re-run `getaddrinfo()` for the current network interface (e.g. after a WiFi→cellular
    /// transition, to obtain NAT64-synthesized IPv6 addresses instead of cached WiFi IPv4 ones).
    func clearResolvedServerCache() {
        cachedResolvedServers = nil
        cachedResolvedHost = nil
    }

    @discardableResult
    func applyDnsSettings(to networkSettings: NETunnelNetworkSettings,
                          localProxyAddress: String? = nil) -> ProxyConfiguration? {
        guard let packetSettings = networkSettings as? NEPacketTunnelNetworkSettings else {
            return nil
        }

        let configuration = cachedConfiguration ?? preferences.currentConfiguration()
        cachedConfiguration = configuration

        guard
            //configuration.isEnabled,
            let urlString = configuration.urlString,
            let components = URLComponents(string: urlString),
            let host = components.host, !host.isEmpty
        else {
            return nil
        }

        let port: UInt16
        if let componentPort = components.port, (1...Int(UInt16.max)).contains(componentPort) {
            port = UInt16(componentPort)
        } else {
            port = 853
        }

        let resolvedServers: [String]

        if let cachedResolvedServers, cachedResolvedHost == host {
            resolvedServers = cachedResolvedServers
        } else {
            let freshServers: [String]
            do {
                freshServers = try Self.resolveServerAddress(for: host)
            } catch {
                log.error("Failed to resolve DNS-over-TLS server '\(host, privacy: .public)': \(error)")
                freshServers = []
            }
            if freshServers.isEmpty {
                // getaddrinfo returned nothing (e.g. IPv6-only cellular before Fix 1 takes full
                // effect, or a transient network outage). Use last-known-good IPs from UserDefaults
                // so we never fall back to the raw hostname (which would create a circular
                // dependency: NWConnection → VPN DNS → this proxy → NWConnection…).
                let persisted = preferences.savedResolvedServers()
                resolvedServers = persisted.isEmpty ? [host] : persisted
            } else {
                resolvedServers = Self.preferredServerList(from: freshServers, fallbackHost: host)
                // Persist fresh IPs so the next cold start on a different network type can use them.
                preferences.saveResolvedServers(resolvedServers)
            }
            cachedResolvedServers = resolvedServers
            cachedResolvedHost = host
        }

        if let localProxyAddress {
            let dnsSettings = NEDNSSettings(servers: [localProxyAddress])
            dnsSettings.matchDomains = [""]
            packetSettings.dnsSettings = dnsSettings
        } else {
            let tlsSettings = NEDNSOverTLSSettings(servers: resolvedServers)
            tlsSettings.serverName = host
            tlsSettings.matchDomains = [""]
            packetSettings.dnsSettings = tlsSettings
        }

        return ProxyConfiguration(serverName: host,
                                   port: port,
                                   resolvedAddresses: resolvedServers)
    }

    func dnsEndpoint() -> String? {
        guard let secrets = secretsDictionary() else { return nil }
        guard let endpoint = secrets["dnsEndpoint"] as? String, !endpoint.isEmpty else {
            return nil
        }
        return endpoint
    }

    private func secretsDictionary() -> [String: Any]? {
        let bundle = Bundle(for: Self.self)
        
        guard let url = bundle.url(forResource: "Secrets", withExtension: "plist") else {
            assertionFailure("Secrets.plist not found in extension bundle.")
            return [:]
        }
        
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            log.error("Could not read Secrets.plist data: \(error)")
            assertionFailure("Could not read Secrets.plist data.")
            return [:]
        }

        let plist: [String: Any]?
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        } catch {
            log.error("Could not parse Secrets.plist: \(error)")
            assertionFailure("Could not parse Secrets.plist as dictionary.")
            return [:]
        }
        guard let plist else {
            assertionFailure("Could not parse Secrets.plist as dictionary.")
            return [:]
        }
        
        return plist
    }
    
    /*private func resourcesBundle() -> Bundle? {
        if let url = Bundle.main.url(forResource: "GlacierResources", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }

        if let resourceURL = Bundle(for: PacketTunnelDNSConfigurator.self).resourceURL?.appendingPathComponent("GlacierResources.bundle"),
           let bundle = Bundle(url: resourceURL) {
            return bundle
        }

        return nil
    }*/

    private static func shortDeviceID(prefix: String = "glr", length: Int = 10) -> String {
        #if canImport(UIKit)
        guard let uuid = UIDevice.current.identifierForVendor?.uuidString else {
            return "\(prefix)-unknown"
        }

        let hash = SHA256.hash(data: Data(uuid.utf8))
        let hexString = hash.compactMap { String(format: "%02x", $0) }.joined()
        let shortHash = String(hexString.prefix(length))

        return "\(prefix)-\(shortHash)"
        #else
        return "\(prefix)-unknown"
        #endif
    }

    private static func resolveServerAddress(for host: String) throws -> [String] {
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
            return []
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
                if conversion == 0,
                   let resolved = String(validatingUTF8: hostBuffer),
                   !resolved.isEmpty,
                   seen.insert(resolved).inserted {
                    resolvedAddresses.append(resolved)
                }
            }
            pointer = current.pointee.ai_next
        }
        return resolvedAddresses
    }

    private static func preferredServerList(from resolvedServers: [String], fallbackHost: String, limit: Int = 4) -> [String] {
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
}

private struct PacketTunnelDnsConfiguration {
    var urlString: String?
    var isEnabled: Bool

    func sanitized() -> PacketTunnelDnsConfiguration {
        let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasURL = !(trimmed?.isEmpty ?? true)
        return PacketTunnelDnsConfiguration(urlString: hasURL ? trimmed : nil,
                                            isEnabled: hasURL ? isEnabled : false)
    }
}

private final class PacketTunnelDnsPreferences {
    private enum Keys {
        static let url = "dnsOverTls.global.url"
        static let enabled = "dnsOverTls.global.enabled"
        static let resolvedServers = "dnsOverTls.global.resolvedServers"
        static let appGroupIdentifier = "group.com.theglacierapp.GlacierApp"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults? = UserDefaults(suiteName: Keys.appGroupIdentifier)) {
        self.userDefaults = userDefaults ?? .standard
    }

    func hasSavedConfiguration() -> Bool {
        return userDefaults.object(forKey: Keys.url) != nil
    }

    func currentConfiguration() -> PacketTunnelDnsConfiguration {
        let savedURL = userDefaults.string(forKey: Keys.url)
        let enabled: Bool
        if userDefaults.object(forKey: Keys.enabled) != nil {
            enabled = userDefaults.bool(forKey: Keys.enabled)
        } else {
            enabled = false
        }
        let configuration = PacketTunnelDnsConfiguration(urlString: savedURL, isEnabled: enabled)
        return configuration.sanitized()
    }

    func save(configuration: PacketTunnelDnsConfiguration) {
        let sanitized = configuration.sanitized()
        if let url = sanitized.urlString {
            userDefaults.set(url, forKey: Keys.url)
            userDefaults.set(sanitized.isEnabled, forKey: Keys.enabled)
        } else {
            userDefaults.removeObject(forKey: Keys.url)
            userDefaults.set(false, forKey: Keys.enabled)
        }
    }

    /// Returns the last set of successfully-resolved DoT server IP addresses, or an empty
    /// array if none have been persisted yet.
    func savedResolvedServers() -> [String] {
        return userDefaults.stringArray(forKey: Keys.resolvedServers) ?? []
    }

    /// Persists successfully-resolved DoT server IP addresses so that a cold start on a
    /// network where `getaddrinfo()` returns nothing (e.g. IPv6-only cellular before the
    /// NAT64 hints are applied) can fall back to last-known-good IPs rather than the raw
    /// hostname.
    func saveResolvedServers(_ servers: [String]) {
        if servers.isEmpty {
            userDefaults.removeObject(forKey: Keys.resolvedServers)
        } else {
            userDefaults.set(servers, forKey: Keys.resolvedServers)
        }
    }
}
