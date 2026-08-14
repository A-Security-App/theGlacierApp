import XCTest
@testable import Glacier

final class EmergencyCallPolicyTests: XCTestCase {

    func testRecognizes911AcrossDialerFormatting() {
        let emergencyNumbers = [
            "911",
            "(911",
            "(911)",
            "9-1-1",
            "9 1 1",
            "+911"
        ]

        for number in emergencyNumbers {
            XCTAssertTrue(
                CallManager.isEmergencyNumber(number),
                "Expected \(number) to be blocked"
            )
        }
    }

    func testDoesNotBlockIncompleteOrOrdinaryNumbers() {
        let allowedNumbers = [
            "",
            "9",
            "91",
            "9112",
            "1911",
            "+1911",
            "(919) 110-0000"
        ]

        for number in allowedNumbers {
            XCTAssertFalse(
                CallManager.isEmergencyNumber(number),
                "Expected \(number) to remain callable"
            )
        }
    }

    func testEmergencyServicesWarningUsesRequiredCopy() {
        XCTAssertEqual(
            CallManager.emergencyServicesUnavailableMessage,
            "Emergency Services are not available through Glacier."
        )
    }

    func testEmergencyNumberCannotBecomeATwilioDialString() {
        XCTAssertNil(CallManager.formatDialString("911"))
        XCTAssertNil(CallManager.formatDialString("(911)"))
        XCTAssertNil(CallManager.formatDialString("+911"))
    }

    func testOrdinaryNumberDialStringIsUnchanged() {
        XCTAssertEqual(
            CallManager.formatDialString("(313) 555-0123"),
            "+13135550123"
        )
    }
}
