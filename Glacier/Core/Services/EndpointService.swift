//
//  EndpointService.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 `EndpointService` is a centralized source for values defined in:
 - `Secrets.plist`
 */
final class EndpointService {

    // MARK: - Types

    enum SecretsKey: String, CaseIterable {
        case consoleBaseEndpoint
        case twilioAPIEndpoint
        case wgProfileEndpoint
        case dnsProfileEndpoint
        case dnsEndpoint
        case dnsAPIEndpoint
        case dnsCheckEndpoint
        case dnsCheckIP
        case subscriptionEndpoint
    }

    // MARK: - Public properties

    static let shared = EndpointService()

    // MARK: - Private properties

    private let baseBundle: Bundle
    private let lock = NSLock()
    private var cachedPlists: [String: [String: Any]] = [:]

    // MARK: - Initializer

    init(baseBundle: Bundle = .main) {
        self.baseBundle = baseBundle
    }

    // MARK: - Public generic accessors

    func string(for key: SecretsKey) -> String? {
        value(for: key.rawValue, plistName: "Secrets")
    }

    // MARK: - Public convenience values

    var consoleBaseEndpoint: String? { string(for: .consoleBaseEndpoint) }
    var twilioAPIEndpoint: String? { string(for: .twilioAPIEndpoint) }
    var wgProfileEndpoint: String? { string(for: .wgProfileEndpoint) }
    var dnsProfileEndpoint: String? { string(for: .dnsProfileEndpoint) }
    var dnsEndpoint: String? { string(for: .dnsEndpoint) }
    var dnsAPIEndpoint: String? { string(for: .dnsAPIEndpoint) }
    var dnsCheckEndpoint: String? { string(for: .dnsCheckEndpoint) }
    var dnsCheckIP: String? { string(for: .dnsCheckIP) }
    var subscriptionEndpoint: String? { string(for: .subscriptionEndpoint) }

    var twilioAPIURL: URL? { endpointURL(path: twilioAPIEndpoint) }
    var wireGuardProfileURL: URL? { endpointURL(path: wgProfileEndpoint) }
    var dnsProfileURL: URL? { endpointURL(path: dnsProfileEndpoint) }
    var dnsAPIURL: URL? { endpointURL(path: dnsAPIEndpoint) }
    var subscriptionURL: URL? { endpointURL(path: subscriptionEndpoint) }

    func endpointURL(path: String?) -> URL? {
        guard
            let base = consoleBaseEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
            let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
            !base.isEmpty,
            !path.isEmpty
        else {
            return nil
        }

        if let absolutePathURL = URL(string: path), absolutePathURL.scheme != nil {
            return absolutePathURL
        }

        let normalizedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: normalizedBase + normalizedPath)
    }

    // MARK: - Private helpers

    private func value(for key: String, plistName: String) -> String? {
        guard
            let plist = plist(named: plistName),
            let rawValue = plist[key]
        else {
            return nil
        }

        if let stringValue = rawValue as? String {
            return stringValue
        }
        if let numberValue = rawValue as? NSNumber {
            return numberValue.stringValue
        }
        return nil
    }

    private func plist(named name: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedPlists[name] {
            return cached
        }

        for bundle in [baseBundle, Bundle(for: EndpointService.self)] {
            if let dictionary = readPlist(named: name, from: bundle) {
                cachedPlists[name] = dictionary
                return dictionary
            }
        }

        return nil
    }

    private func readPlist(named name: String, from bundle: Bundle) -> [String: Any]? {
        let candidateURLs: [URL?] = [
            bundle.url(forResource: name, withExtension: "plist", subdirectory: "Properties"),
            bundle.url(forResource: name, withExtension: "plist")
        ]

        for url in candidateURLs.compactMap({ $0 }) {
            if let dictionary = NSDictionary(contentsOf: url) as? [String: Any] {
                return dictionary
            }
        }

        return nil
    }
}
