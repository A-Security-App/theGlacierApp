import XCTest
@testable import Glacier

/// Covers the one decision that can cancel a live tunnel: whether a run of exhausted
/// DoT fan-outs means the kernel flow table is saturated, or just that the network
/// moved. Getting that wrong killed the VPN on ordinary Wi-Fi-to-cellular switches,
/// so every case below is drawn from a real device capture rather than invented.
final class UpstreamExhaustionTrackerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_772_000_000)

    // MARK: - Path loss must never request a respawn

    /// The 2026-09-04 11:20:58 capture: Wi-Fi switched off with pages loading produced
    /// 11 fully exhausted fan-outs inside 70 ms, every upstream reporting only that the
    /// path had gone. Under the old rule the third of these cancelled the tunnel.
    func testBurstOfPathOnlyFailuresNeverFires() {
        var tracker = UpstreamExhaustionTracker()

        for i in 0..<11 {
            let fired = tracker.record(hadNonPathFailure: false,
                                       now: t0.addingTimeInterval(Double(i) * 0.007))
            XCTAssertFalse(fired, "path-only fan-out \(i) must not request a respawn")
        }

        XCTAssertFalse(tracker.hasRequestedRespawn)
        XCTAssertEqual(tracker.countInWindow, 0, "path-only fan-outs must not be recorded at all")
    }

    /// Path-only failures must not even partially fill the window — otherwise a handoff
    /// would leave the tracker primed and an unrelated failure minutes later would trip it.
    func testPathOnlyFailuresDoNotPrimeTheWindow() {
        var tracker = UpstreamExhaustionTracker()

        for i in 0..<10 {
            _ = tracker.record(hadNonPathFailure: false, now: t0.addingTimeInterval(Double(i) * 0.01))
        }

        XCTAssertFalse(tracker.record(hadNonPathFailure: true, now: t0.addingTimeInterval(1)))
        XCTAssertFalse(tracker.record(hadNonPathFailure: true, now: t0.addingTimeInterval(2)))
        XCTAssertEqual(tracker.countInWindow, 2, "only the two real failures should count")
    }

    // MARK: - Real failures must still request one

    /// A timeout is not path loss — the path was up and the upstream simply did not
    /// answer. That is the class of failure the escape hatch exists for.
    func testThreeNonPathFailuresInsideWindowFiresOnce() {
        var tracker = UpstreamExhaustionTracker()

        XCTAssertFalse(tracker.record(hadNonPathFailure: true, now: t0))
        XCTAssertFalse(tracker.record(hadNonPathFailure: true, now: t0.addingTimeInterval(30)))
        XCTAssertTrue(tracker.record(hadNonPathFailure: true, now: t0.addingTimeInterval(60)),
                      "third failure inside the window should request a respawn")
        XCTAssertTrue(tracker.hasRequestedRespawn)
    }

    /// One respawn request per instance. The extension is torn down after the first;
    /// firing again would only produce noise while it is on its way out.
    func testFiresAtMostOnce() {
        var tracker = UpstreamExhaustionTracker()

        _ = tracker.record(hadNonPathFailure: true, now: t0)
        _ = tracker.record(hadNonPathFailure: true, now: t0.addingTimeInterval(1))
        XCTAssertTrue(tracker.record(hadNonPathFailure: true, now: t0.addingTimeInterval(2)))

        for i in 3..<30 {
            XCTAssertFalse(tracker.record(hadNonPathFailure: true,
                                          now: t0.addingTimeInterval(Double(i))),
                           "follow-up failure \(i) must not fire a second time")
        }
    }

    /// A fan-out counts as long as *one* upstream failed for a non-path reason — a
    /// partially-jammed stack must not be written off as a handoff.
    func testMixedFanOutsCount() {
        var tracker = UpstreamExhaustionTracker()

        XCTAssertFalse(tracker.record(hadNonPathFailure: true, now: t0))
        XCTAssertFalse(tracker.record(hadNonPathFailure: false, now: t0.addingTimeInterval(1)))
        XCTAssertFalse(tracker.record(hadNonPathFailure: true, now: t0.addingTimeInterval(2)))
        XCTAssertTrue(tracker.record(hadNonPathFailure: true, now: t0.addingTimeInterval(3)))
    }

    // MARK: - The window has to actually expire

    /// The dead-pooled-connection failures observed overnight arrive roughly every five
    /// minutes. Spread that far apart they must never accumulate into a respawn — one
    /// unanswered lookup is not a reason to cancel a working tunnel.
    func testFailuresSpacedBeyondWindowNeverAccumulate() {
        var tracker = UpstreamExhaustionTracker()
        let fiveMinutes: TimeInterval = 300

        for i in 0..<20 {
            let fired = tracker.record(hadNonPathFailure: true,
                                       now: t0.addingTimeInterval(Double(i) * fiveMinutes))
            XCTAssertFalse(fired, "failure \(i), five minutes after the last, must not fire")
            XCTAssertEqual(tracker.countInWindow, 1, "older failures should have aged out")
        }
    }

    /// A failure exactly at the window boundary is outside it — the cutoff is inclusive
    /// of the window length, so `window` seconds ago no longer counts.
    func testFailureAtWindowBoundaryAgesOut() {
        var tracker = UpstreamExhaustionTracker(window: 120, threshold: 3)

        _ = tracker.record(hadNonPathFailure: true, now: t0)
        _ = tracker.record(hadNonPathFailure: true, now: t0.addingTimeInterval(60))
        // 121 s after the first: the first has aged out, so this is only the second
        // failure inside the window and must not fire.
        XCTAssertFalse(tracker.record(hadNonPathFailure: true, now: t0.addingTimeInterval(121)))
        XCTAssertEqual(tracker.countInWindow, 2)
    }

    // MARK: - Configuration

    func testHonoursCustomThreshold() {
        var tracker = UpstreamExhaustionTracker(window: 60, threshold: 2)

        XCTAssertFalse(tracker.record(hadNonPathFailure: true, now: t0))
        XCTAssertTrue(tracker.record(hadNonPathFailure: true, now: t0.addingTimeInterval(10)))
    }

    func testDefaultsMatchShippedConfiguration() {
        let tracker = UpstreamExhaustionTracker()
        XCTAssertEqual(tracker.window, 120)
        XCTAssertEqual(tracker.threshold, 3)
    }
}
