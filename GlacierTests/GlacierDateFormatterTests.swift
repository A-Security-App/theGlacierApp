import XCTest
@testable import Glacier

final class GlacierDateFormatterTests: XCTestCase {

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func isoString(for date: Date) -> String {
        isoFormatter.string(from: date)
    }

    // MARK: - Invalid input

    func testEmptyStringReturnsEmpty() {
        XCTAssertEqual(GlacierDateFormatter.timestamp(for: "", style: .compact), "")
        XCTAssertEqual(GlacierDateFormatter.timestamp(for: "", style: .detailed), "")
    }

    func testUnparseableStringReturnsEmpty() {
        XCTAssertEqual(GlacierDateFormatter.timestamp(for: "not a date", style: .compact), "")
        XCTAssertEqual(GlacierDateFormatter.timestamp(for: "2026-03-15", style: .compact),
                       "",
                       "ISO date without time component should not match the .withInternetDateTime formatter")
    }

    // MARK: - Today

    func testTodayReturnsTimeOnlyForBothStyles() {
        let now = isoString(for: Date())
        let compact = GlacierDateFormatter.timestamp(for: now, style: .compact)
        let detailed = GlacierDateFormatter.timestamp(for: now, style: .detailed)

        // Today's output is just `h:mm a` for both styles — does not include "Yesterday" or " at ".
        XCTAssertFalse(compact.isEmpty)
        XCTAssertFalse(detailed.isEmpty)
        XCTAssertEqual(compact, detailed, "Today's timestamp should be identical for compact and detailed")
        XCTAssertFalse(compact.contains("/"), "Today should not render the MM/dd/yy fallback")
    }

    // MARK: - Yesterday

    func testYesterdayCompactReturnsLocalizedYesterday() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let output = GlacierDateFormatter.timestamp(for: isoString(for: yesterday), style: .compact)
        // We can't assert the localized word, but the compact yesterday string should
        // not contain " at " (that's the .detailed format).
        XCTAssertFalse(output.isEmpty)
        XCTAssertFalse(output.contains(" at "))
    }

    func testYesterdayDetailedContainsTime() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let output = GlacierDateFormatter.timestamp(for: isoString(for: yesterday), style: .detailed)
        XCTAssertTrue(output.contains(" at "), "Detailed yesterday timestamp should include ' at <time>'; got: \(output)")
    }

    // MARK: - Older dates

    func testOldDateCompactUsesShortDateFormat() {
        let old = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let output = GlacierDateFormatter.timestamp(for: isoString(for: old), style: .compact)
        // MM/dd/yy — exactly two slashes, all digits between.
        let parts = output.split(separator: "/")
        XCTAssertEqual(parts.count, 3, "Expected MM/dd/yy format, got: \(output)")
        XCTAssertTrue(parts.allSatisfy { $0.allSatisfy(\.isNumber) }, "All components should be numeric, got: \(output)")
    }

    func testOldDateDetailedIncludesTimeSeparator() {
        let old = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let output = GlacierDateFormatter.timestamp(for: isoString(for: old), style: .detailed)
        XCTAssertTrue(output.contains(" at "), "Detailed older-date timestamp should include ' at <time>'; got: \(output)")
        XCTAssertTrue(output.contains(","), "Detailed older-date timestamp should include the weekday/month comma; got: \(output)")
    }
}
