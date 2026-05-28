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

    private let preferences: DnsOverTlsPreferences
    private let dnsManager: NEDNSSettingsManager
    private let workQueue = DispatchQueue(label: "com.glacier.dnsOverTls.controller")
    private let bogusDomain = "kljh345jkl.com"
    private var resolvedHosts: [String]
    private let resolveServerAddress: (String) throws -> [String]
    private var cachedResolvedServers: [String]?
    private var cachedResolvedHost: String?

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
            self.dnsManager.loadFromPreferences { loadError in
                if let loadError = loadError {
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

                let servers = resolvedHostsAr.isEmpty ? [host] : resolvedHostsAr
                self.resolvedHosts = resolvedHostsAr
                let tlsSettings = NEDNSOverTLSSettings(servers: servers)
                tlsSettings.serverName = serverName

                tlsSettings.matchDomains = [""]
                if !sanitized.isEnabled {
                    tlsSettings.matchDomains = [self.bogusDomain]
                }
                //tlsSettings.strictPrivacy = true
                self.dnsManager.localizedDescription = NSLocalizedString("Glacier", comment: "DNS preference label")
                self.dnsManager.dnsSettings = tlsSettings
                self.savePreferences(sanitized, completion: completion)
            }
        }
    }
    
    func getResolvedHosts() -> [String] {
        return self.resolvedHosts
    }
    
    func shortDeviceID(prefix: String = "glr", length: Int = 10) -> String {
        guard let uuid = UIDevice.current.identifierForVendor?.uuidString else {
            return "\(prefix)-unknown"
        }

        // Hash the UUID using SHA256
        let hash = SHA256.hash(data: Data(uuid.utf8))

        // Convert the first N bytes of the hash to a hex string
        let hexString = hash.compactMap { String(format: "%02x", $0) }.joined()
        let shortHash = String(hexString.prefix(length))

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
        if saved.urlString != nil {
            // URL already on file — just make sure isEnabled is true.
            let enabled = DnsOverTlsConfiguration(urlString: saved.urlString, isEnabled: true)
            apply(configuration: enabled, completion: completion)
        } else {
            // No URL yet (user skipped DNS onboarding) — fetch it, store it, then enable.
            urlProvider { [weak self] urlString in
                guard let self, let urlString, !urlString.isEmpty else {
                    // Can't fetch URL right now; skip silently so VPN connect still works.
                    completion(.failure(DnsOverTlsControllerError.missingHost))
                    return
                }
                self.storeNewConfiguration(urlString)
                let enabled = DnsOverTlsConfiguration(urlString: urlString, isEnabled: true)
                self.apply(configuration: enabled, completion: completion)
            }
        }
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
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP,
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

    private func savePreferences(_ configuration: DnsOverTlsConfiguration,
                                 completion: @escaping (Result<DnsOverTlsConfiguration, Error>) -> Void) {
        self.dnsManager.saveToPreferences { saveError in
            DispatchQueue.main.async {
                if let saveError = saveError {
                    completion(.failure(saveError))
                } else {
                    self.preferences.save(configuration: configuration)
                    completion(.success(configuration))
                }
            }
        }
    }
}
