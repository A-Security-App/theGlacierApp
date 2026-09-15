import XCTest
@testable import Glacier

final class InternationalDialStringTests: XCTestCase {

    func testInternationalNumberKeepsItsCountryCode() {
        // A ten-digit international number (Norway: +47 23 21 20 00) must not be
        // mistaken for a US number and dialed as +14723212000.
        XCTAssertEqual(
            CallManager.formatDialString("+47 23 21 20 00"),
            "+4723212000"
        )
        XCTAssertEqual(
            CallManager.formatDialString("+442071838750"),
            "+442071838750"
        )
        XCTAssertEqual(
            CallManager.formatDialString("+81 3-3201-3331"),
            "+81332013331"
        )
    }

    func testExitPrefixIsTreatedAsInternational() {
        XCTAssertEqual(
            CallManager.formatDialString("0047 23 21 20 00"),
            "+4723212000"
        )
        XCTAssertNil(CallManager.formatDialString("00"))
    }

    func testTenDigitDomesticNumberStillGetsUSCountryCode() {
        XCTAssertEqual(CallManager.formatDialString("3135550123"), "+13135550123")
        XCTAssertEqual(CallManager.formatDialString("(313) 555-0123"), "+13135550123")
        XCTAssertEqual(CallManager.formatDialString("+1 (313) 555-0123"), "+13135550123")
    }

    func testEmptyAndNonDialableInputIsRejected() {
        XCTAssertNil(CallManager.formatDialString(""))
        XCTAssertNil(CallManager.formatDialString("   "))
        XCTAssertNil(CallManager.formatDialString("+"))
    }
}
