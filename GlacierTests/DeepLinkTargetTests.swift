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

    // MARK: - loginSecurityApp

    func testLoginSecurityAppParsesCode() throws {
        let url = try XCTUnwrap(URL(string: "https://console.theglacierapp.com/login-securityapp?code=123456"))
        XCTAssertEqual(DeepLinkTarget.from(url: url), .loginSecurityApp(confirmationCode: "123456"))
    }

    func testLoginSecurityAppReturnsNilWhenCodeMissing() throws {
        let url = try XCTUnwrap(URL(string: "https://console.theglacierapp.com/login-securityapp"))
        XCTAssertNil(DeepLinkTarget.from(url: url))
    }

    // MARK: - Removed protection-changing routes

    /// Any app or web page can open a custom-scheme URL, so no deep link may switch
    /// protection on or off. 
    func testWidgetAndVpnToggleLinksAreNotRouted() throws {
        let links = [
            "glacierapp://widget/disconnect",
            "glacierapp://widget/connect",
            "glacierapp://widget/disconnect?t=abc",
            "GlacierApp://widget/disconnect",
            "com.theglacierapp.glacier://widget/disconnect",
            "com.theglacierapp.glacier://widget/connect",
            "glacierapp://vpn/toggle",
            "com.theglacierapp.glacier://vpn/toggle",
            "https://widget/disconnect",
        ]
        for raw in links {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertNil(DeepLinkTarget.from(url: url), raw)
            XCTAssertFalse(DeepLinkService.shared.handle(url: url), raw)
        }
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

    // MARK: - Console links require https

    func testConsoleRoutesRejectCustomSchemes() throws {
        let routes = [
            "/open-securityapp?userid=alice&code=ABC123",
            "/reset-securityapp?code=XYZ789",
            "/login-securityapp?code=123456",
        ]
        for route in routes {
            for scheme in ["glacierapp", "com.theglacierapp.glacier", "http"] {
                let url = try XCTUnwrap(URL(string: "\(scheme)://console.theglacierapp.com\(route)"))
                XCTAssertNil(DeepLinkTarget.from(url: url), url.absoluteString)
            }
        }
    }

    func testConsoleRoutesAcceptHTTPS() throws {
        let cases: [(String, DeepLinkTarget)] = [
            ("/open-securityapp?userid=alice&code=ABC123", .openSecurityApp(userName: "alice", confirmationCode: "ABC123")),
            ("/reset-securityapp?code=XYZ789", .resetSecurityApp(confirmationCode: "XYZ789")),
            ("/login-securityapp?code=123456", .loginSecurityApp(confirmationCode: "123456")),
        ]
        for (route, expected) in cases {
            let url = try XCTUnwrap(URL(string: "https://console.theglacierapp.com\(route)"))
            XCTAssertEqual(DeepLinkTarget.from(url: url), expected, route)
        }
    }

    func testUnknownPathOnValidHostReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "https://console.theglacierapp.com/some-other-route?userid=alice&code=ABC123"))
        XCTAssertNil(DeepLinkTarget.from(url: url))
    }
}
