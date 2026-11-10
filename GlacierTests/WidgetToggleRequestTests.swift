import XCTest
@testable import Glacier

/// A Shortcuts toggle made while Glacier was killed used to wait in the app-group defaults and
/// fire on some later return from the background. It now runs only if it is recent.
final class WidgetToggleRequestTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecentRequestIsFresh() {
        XCTAssertTrue(WidgetToggleRequest.isFresh(requestedAt: now.timeIntervalSince1970, now: now))
        XCTAssertTrue(WidgetToggleRequest.isFresh(requestedAt: now.timeIntervalSince1970 - 5, now: now))
    }

    func testRequestAtMaxAgeIsStillFresh() {
        let requestedAt = now.timeIntervalSince1970 - WidgetToggleRequest.maxAge
        XCTAssertTrue(WidgetToggleRequest.isFresh(requestedAt: requestedAt, now: now))
    }

    func testOldRequestIsStale() {
        for age: TimeInterval in [WidgetToggleRequest.maxAge + 1, 3_600, 86_400] {
            XCTAssertFalse(WidgetToggleRequest.isFresh(requestedAt: now.timeIntervalSince1970 - age, now: now), "\(age)")
        }
    }

    func testMissingTimestampIsStale() {
        // Requests written by an older build of the intent carry no timestamp.
        XCTAssertFalse(WidgetToggleRequest.isFresh(requestedAt: nil, now: now))
    }

    func testSmallFutureSkewIsToleratedButNotMore() {
        XCTAssertTrue(WidgetToggleRequest.isFresh(requestedAt: now.timeIntervalSince1970 + WidgetToggleRequest.futureTolerance, now: now))
        XCTAssertFalse(WidgetToggleRequest.isFresh(requestedAt: now.timeIntervalSince1970 + 60, now: now))
    }
}
