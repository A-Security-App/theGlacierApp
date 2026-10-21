import XCTest
@testable import Glacier

final class CallerNumberTests: XCTestCase {

    func testRealNumbersAreCopiedUnchanged() {
        XCTAssertEqual(CallerNumber.usableNumber("+15551234567"), "+15551234567")
        // International numbers keep their country code and plus sign.
        XCTAssertEqual(CallerNumber.usableNumber("+4723212000"), "+4723212000")
        XCTAssertEqual(CallerNumber.usableNumber("+442071838750"), "+442071838750")
        // Formatting is kept as given, not rewritten.
        XCTAssertEqual(CallerNumber.usableNumber("+1 (555) 123-4567"), "+1 (555) 123-4567")
        // Surrounding whitespace is trimmed.
        XCTAssertEqual(CallerNumber.usableNumber("  +15551234567\n"), "+15551234567")
    }

    func testMissingNumbersAreUnavailable() {
        XCTAssertNil(CallerNumber.usableNumber(nil))
        XCTAssertNil(CallerNumber.usableNumber(""))
        XCTAssertNil(CallerNumber.usableNumber("   "))
        XCTAssertNil(CallerNumber.usableNumber("+"))
    }

    func testHiddenCallerWordsAreUnavailable() {
        for placeholder in ["anonymous", "Anonymous", "Restricted", "unknown", "private", "Unavailable", "blocked"] {
            XCTAssertNil(CallerNumber.usableNumber(placeholder), placeholder)
        }
    }

    func testTwilioKeypadPlaceholdersAreUnavailable() {
        // Twilio spells the reason on a keypad in place of a withheld number.
        for placeholder in ["+266696687", "266696687", "+8656696", "+7378742833", "+2562533", "+86282452253"] {
            XCTAssertNil(CallerNumber.usableNumber(placeholder), placeholder)
        }
    }

    func testSipAndClientAddressesAreUnavailable() {
        XCTAssertNil(CallerNumber.usableNumber("sip:+15551234567@glacier.sip.twilio.com"))
        XCTAssertNil(CallerNumber.usableNumber("client:alice"))
    }
}
