import XCTest
import Network
@testable import Glacier

final class DnsOverTlsControllerTests: XCTestCase {
    func testResolveServerAddressReturnsIPv4Literal() throws {
        let address = "192.0.2.1"
        let resolved = try DnsOverTlsController.resolveServerAddress(for: address)
        XCTAssertEqual(resolved, [address])
    }

    func testResolveServerAddressReturnsIPv6Literal() throws {
        let address = "::1"
        let resolved = try DnsOverTlsController.resolveServerAddress(for: address)
        XCTAssertEqual(resolved, [address])
    }

    func testResolveServerAddressResolvesHostname() throws {
        let resolved = try DnsOverTlsController.resolveServerAddress(for: "localhost")
        XCTAssertFalse(resolved.isEmpty)
        XCTAssertTrue(resolved.allSatisfy { IPv4Address($0) != nil || IPv6Address($0) != nil },
                      "Expected only numeric IP addresses, got \(resolved)")
    }

    func testResolveServerAddressCollectsMultipleRecordsWhenAvailable() throws {
        let resolved = try DnsOverTlsController.resolveServerAddress(for: "localhost")
        let uniqueResolved = Array(Set(resolved))
        XCTAssertEqual(uniqueResolved.count, resolved.count, "Expected unique addresses in \(resolved)")
        if resolved.count < 2 {
            throw XCTSkip("Environment only provided \(resolved.count) address for localhost")
        }
        XCTAssertTrue(resolved.contains(where: { IPv4Address($0) != nil }))
        XCTAssertTrue(resolved.contains(where: { IPv6Address($0) != nil }))
    }

    func testResolveServerAddressThrowsForInvalidHostname() {
        let invalidHost = "invalid.example.invalidtld"
        XCTAssertThrowsError(try DnsOverTlsController.resolveServerAddress(for: invalidHost)) { error in
            guard case DnsOverTlsControllerError.hostResolutionFailed(let failingHost) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failingHost, invalidHost)
        }
    }

    func testPreferencesRetainURLWhenDisabling() {
        let suiteName = "DnsOverTlsControllerTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create test user defaults")
        }
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let preferences = DnsOverTlsPreferences(userDefaults: userDefaults)
        let enabledConfiguration = DnsOverTlsConfiguration(urlString: "tls://example.com", isEnabled: true)
        preferences.save(configuration: enabledConfiguration)

        var disabledConfiguration = enabledConfiguration
        disabledConfiguration.isEnabled = false
        preferences.save(configuration: disabledConfiguration)

        let loadedConfiguration = preferences.currentConfiguration()
        XCTAssertEqual(loadedConfiguration.urlString, enabledConfiguration.urlString)
        XCTAssertFalse(loadedConfiguration.isEnabled)
    }
}
