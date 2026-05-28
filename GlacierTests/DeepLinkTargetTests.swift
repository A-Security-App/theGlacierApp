import XCTest
@testable import Glacier

final class DeepLinkTargetTests: XCTestCase {

    // MARK: - openSecurityApp

    func testOpenSecurityAppParsesUserAndCode() throws {
        let url = try XCTUnwrap(URL(string: "https://console.theglacierapp.com/open-securityapp?userid=alice&code=ABC123"))
        XCTAssertEqual(DeepLinkTarget.from(url: url), .openSecurityApp(userName: "alice", confirmationCode: "ABC123"))
    }

    func testOpenSecurityAppPercentDecodesQueryValues() throws {
        let url = try XCTUnwrap(URL(string: "https://console.theglacierapp.com/open-securityapp?userid=alice%40example.com&code=A%2BB%2FC%3D"))
        XCTAssertEqual(DeepLinkTarget.from(url: url), .openSecurityApp(userName: "alice@example.com", confirmationCode: "A+B/C="))
    }

    func testOpenSecurityAppReturnsNilWhenUserIdMissing() throws {
        let url = try XCTUnwrap(URL(string: "https://console.theglacierapp.com/open-securityapp?code=ABC123"))
        XCTAssertNil(DeepLinkTarget.from(url: url))
    }

    func testOpenSecurityAppReturnsNilWhenCodeMissing() throws {
        let url = try XCTUnwrap(URL(string: "https://console.theglacierapp.com/open-securityapp?userid=alice"))
        XCTAssertNil(DeepLinkTarget.from(url: url))
    }

    // MARK: - resetSecurityApp

    func testResetSecurityAppParsesCode() throws {
        let url = try XCTUnwrap(URL(string: "https://console.theglacierapp.com/reset-securityapp?code=XYZ789"))
        XCTAssertEqual(DeepLinkTarget.from(url: url), .resetSecurityApp(confirmationCode: "XYZ789"))
    }

    func testResetSecurityAppReturnsNilWhenCodeMissing() throws {
        let url = try XCTUnwrap(URL(string: "https://console.theglacierapp.com/reset-securityapp"))
        XCTAssertNil(DeepLinkTarget.from(url: url))
    }

    // MARK: - Widget deep links

    func testWidgetDisconnect() throws {
        let url = try XCTUnwrap(URL(string: "glacierapp://widget/disconnect"))
        XCTAssertEqual(DeepLinkTarget.from(url: url), .widgetDisconnect)
    }

    func testWidgetConnect() throws {
        let url = try XCTUnwrap(URL(string: "glacierapp://widget/connect"))
        XCTAssertEqual(DeepLinkTarget.from(url: url), .widgetConnect)
    }

    func testWidgetHostWithUnknownPathReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "glacierapp://widget/refresh"))
        XCTAssertNil(DeepLinkTarget.from(url: url))
    }

    // MARK: - Legacy vpnToggle

    func testLegacyVpnToggle() throws {
        let url = try XCTUnwrap(URL(string: "glacierapp://vpn/toggle"))
        XCTAssertEqual(DeepLinkTarget.from(url: url), .vpnToggle)
    }

    func testVpnHostWithWrongPathReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "glacierapp://vpn/start"))
        XCTAssertNil(DeepLinkTarget.from(url: url))
    }

    // MARK: - Host validation

    func testUnknownHostIsRejected() throws {
        // The path matches a known route but the host does not — must reject so a
        // malicious site cannot forge an open-securityapp link from another origin.
        let url = try XCTUnwrap(URL(string: "https://attacker.example.com/open-securityapp?userid=alice&code=ABC123"))
        XCTAssertNil(DeepLinkTarget.from(url: url))
    }

    func testHostSuffixSpoofIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "https://console.theglacierapp.com.attacker.example/open-securityapp?userid=alice&code=ABC123"))
        XCTAssertNil(DeepLinkTarget.from(url: url))
    }

    func testUnknownPathOnValidHostReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "https://console.theglacierapp.com/some-other-route?userid=alice&code=ABC123"))
        XCTAssertNil(DeepLinkTarget.from(url: url))
    }
}
