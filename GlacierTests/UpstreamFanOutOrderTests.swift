import XCTest
@testable import Glacier

/// Covers which upstream a DNS query is tried against first. The cost of getting this
/// wrong is not a crash but a stall: an upstream that accepts a connection and then
/// stops answering burns the full 8 s query timeout, and mDNSResponder gives up before
/// that elapses. Every scenario below is drawn from the 2026-09-10 capture, where one
/// stalled upstream at index 1 left 43% of DNS questions unanswered for seven minutes
/// while a working upstream sat at index 3.
final class UpstreamFanOutOrderTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_772_000_000)

    // MARK: - The order is unchanged until something times out

    /// The overwhelmingly common case. Nothing has failed, so the walk must start at
    /// index 0 exactly as it did before this type existed — the IPv4-first ordering
    /// that `PacketTunnelDNSConfigurator` deliberately produces is preserved.
    func testUntouchedPoolKeepsNaturalOrder() {
        let order = UpstreamFanOutOrder(upstreamCount: 4)
        XCTAssertEqual(order.order(now: t0), [0, 1, 2, 3])
    }

    func testEmptyPoolProducesEmptyOrder() {
        let order = UpstreamFanOutOrder(upstreamCount: 0)
        XCTAssertEqual(order.order(now: t0), [])
    }

    // MARK: - The 2026-09-10 outage

    /// The capture itself: pool was
    /// `199.119.65.94, 2a0e:…:6b78, 170.39.224.134, 2a0b:…:d17f`, and index 1 timed out
    /// at 14:53:18. Every later query must reach the other three before paying that 8 s
    /// again.
    func testTimedOutUpstreamMovesToTheBack() {
        var order = UpstreamFanOutOrder(upstreamCount: 4)

        XCTAssertTrue(order.penalize(1, now: t0), "first demotion is a new one and should be logged")
        XCTAssertEqual(order.order(now: t0), [0, 2, 3, 1])
    }

    /// The stalled upstream timed out seven times across seven minutes. Only the first
    /// of each penalty window is a state change; the rest must stay silent so this does
    /// not become the next log storm.
    func testRepeatedTimeoutInsideThePenaltyDoesNotReportAgain() {
        var order = UpstreamFanOutOrder(upstreamCount: 4)

        XCTAssertTrue(order.penalize(1, now: t0))
        XCTAssertFalse(order.penalize(1, now: t0.addingTimeInterval(10)))
        XCTAssertFalse(order.penalize(1, now: t0.addingTimeInterval(59)))
        XCTAssertEqual(order.order(now: t0.addingTimeInterval(59)), [0, 2, 3, 1])
    }

    /// A repeat timeout still refreshes the window even though it is not reported, so an
    /// upstream that keeps stalling keeps its demotion rather than rotating back to the
    /// front every 60 s.
    func testRepeatedTimeoutExtendsThePenalty() {
        var order = UpstreamFanOutOrder(upstreamCount: 4)

        order.penalize(1, now: t0)
        order.penalize(1, now: t0.addingTimeInterval(50))

        XCTAssertEqual(order.order(now: t0.addingTimeInterval(70)), [0, 2, 3, 1],
                       "penalty set at t+50 runs to t+110, so the upstream is still demoted at t+70")
    }

    func testPenaltyExpiresAndTheNaturalOrderReturns() {
        var order = UpstreamFanOutOrder(upstreamCount: 4)
        order.penalize(1, now: t0)

        XCTAssertEqual(order.order(now: t0.addingTimeInterval(61)), [0, 1, 2, 3])
        XCTAssertTrue(order.penalize(1, now: t0.addingTimeInterval(61)),
                      "a timeout after the window closed is a new demotion again")
    }

    /// Several upstreams stalling at once must degrade gracefully rather than
    /// scrambling: the healthy ones keep their relative order, and the demoted ones are
    /// ordered by how soon they recover, so the least-recently-failed is tried first.
    func testMultiplePenaltiesOrderBySoonestRecovery() {
        var order = UpstreamFanOutOrder(upstreamCount: 4)

        order.penalize(0, now: t0)                          // recovers at t+60
        order.penalize(2, now: t0.addingTimeInterval(20))    // recovers at t+80

        XCTAssertEqual(order.order(now: t0.addingTimeInterval(30)), [1, 3, 0, 2])
    }

    // MARK: - A penalty is a preference, never a filter

    /// The single most important property. The usual reason every upstream fails at once
    /// is the path going away — a PDP rebuild, Wi-Fi dropping — which says nothing about
    /// any individual server. If that ever demoted the whole pool, this type must hand
    /// back the natural order rather than an arbitrary one, and must still return all
    /// four so the fan-out reaches everybody.
    func testWholePoolPenalizedFallsBackToNaturalOrder() {
        var order = UpstreamFanOutOrder(upstreamCount: 4)
        for index in 0..<4 {
            order.penalize(index, now: t0.addingTimeInterval(Double(index)))
        }

        XCTAssertEqual(order.order(now: t0.addingTimeInterval(5)), [0, 1, 2, 3])
    }

    /// However the order is permuted, it must always be a permutation: no upstream is
    /// ever dropped from the fan-out.
    func testEveryUpstreamIsAlwaysReachable() {
        var order = UpstreamFanOutOrder(upstreamCount: 4)
        order.penalize(1, now: t0)
        order.penalize(3, now: t0)

        XCTAssertEqual(order.order(now: t0).sorted(), [0, 1, 2, 3])
        XCTAssertEqual(order.order(now: t0).count, 4)
    }

    // MARK: - Evidence beats the penalty

    /// An upstream that answers has just disproved the reason it was demoted. Waiting
    /// out the rest of a 60 s window would keep a working server at the back for no
    /// reason — and on a pool where the others are also struggling, that costs queries.
    func testSuccessClearsThePenaltyImmediately() {
        var order = UpstreamFanOutOrder(upstreamCount: 4)
        order.penalize(1, now: t0)
        XCTAssertEqual(order.order(now: t0), [0, 2, 3, 1])

        order.clearPenalty(1)

        XCTAssertEqual(order.order(now: t0), [0, 1, 2, 3])
        XCTAssertFalse(order.isPenalized(1, now: t0))
    }

    // MARK: - Bounds

    /// `DoTResolver` indexes by position in its own upstream array, and a proxy restart
    /// can rebuild that array with a different length. An out-of-range index must be
    /// inert rather than trapping inside the DNS path.
    func testOutOfRangeIndicesAreInert() {
        var order = UpstreamFanOutOrder(upstreamCount: 2)

        XCTAssertFalse(order.penalize(7, now: t0))
        XCTAssertFalse(order.penalize(-1, now: t0))
        order.clearPenalty(7)

        XCTAssertFalse(order.isPenalized(7, now: t0))
        XCTAssertEqual(order.order(now: t0), [0, 1])
    }
}
