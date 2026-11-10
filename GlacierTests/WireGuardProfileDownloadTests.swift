import XCTest
@testable import Glacier

/// The profile endpoint answers `{"data": "<presigned config URL>"}`. The app fetches that URL on
/// the pinned session, so anything other than https must be refused before a request is made.
final class WireGuardProfileDownloadTests: XCTestCase {

    private func response(_ json: String) -> Data { Data(json.utf8) }

    func testAcceptsHTTPSPresignedURL() throws {
        let raw = "https://glacier-wg-profiles.s3.us-east-2.amazonaws.com/abc.conf?X-Amz-Signature=deadbeef&X-Amz-Expires=300"
        let result = WireGuardProfileDownload.configURL(fromProfileResponse: response(#"{"data": "\#(raw)"}"#))
        XCTAssertEqual(try result.get().absoluteString, raw)
    }

    func testAcceptsUppercaseScheme() throws {
        let result = WireGuardProfileDownload.configURL(fromProfileResponse: response(#"{"data": "HTTPS://example.com/a.conf"}"#))
        XCTAssertEqual(try result.get().host, "example.com")
    }

    func testRejectsNonHTTPSSchemes() {
        for raw in ["http://example.com/a.conf", "file:///etc/passwd", "glacierapp://widget/connect", "ftp://example.com/a.conf", "data:text/plain,hi"] {
            let result = WireGuardProfileDownload.configURL(fromProfileResponse: response(#"{"data": "\#(raw)"}"#))
            XCTAssertEqual(result.failure, .insecureScheme, raw)
        }
    }

    func testRejectsHTTPSWithoutHost() {
        let result = WireGuardProfileDownload.configURL(fromProfileResponse: response(#"{"data": "https:///a.conf"}"#))
        XCTAssertEqual(result.failure, .insecureScheme)
    }

    func testRejectsMissingOrNonStringData() {
        for json in [#"{}"#, #"{"data": 5}"#, #"{"data": null}"#, #"{"url": "https://example.com/a.conf"}"#] {
            XCTAssertEqual(WireGuardProfileDownload.configURL(fromProfileResponse: response(json)).failure, .missingDataURL, json)
        }
    }

    func testRejectsNonObjectBodies() {
        for body in ["", "not json", "[]", #""https://example.com/a.conf""#] {
            XCTAssertEqual(WireGuardProfileDownload.configURL(fromProfileResponse: response(body)).failure, .notJSONObject, body)
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
