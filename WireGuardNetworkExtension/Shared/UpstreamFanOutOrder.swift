import Foundation

/// Fan-out ordering for the DoT upstream pool.
///
/// `DoTResolver` walks its upstreams in a fixed array order, starting at index 0 for
/// every query. That is fine when a failing upstream fails *fast*: an IPv4 address with
/// no route on an IPv6-only cellular interface is rejected in about a millisecond, and
/// paying that twice before reaching a working address costs nothing measurable.
///
/// It is not fine when an upstream accepts the TCP connection, completes the TLS
/// handshake, and then stops answering. That failure costs the full 8 s query timeout —
/// and it is paid again by every subsequent query, because nothing remembers it just
/// happened.
///
/// Observed on device 2026-09-10, 14:53–15:00: one IPv6 upstream sitting at index 1
/// timed out seven times across seven minutes while a working upstream sat at index 3.
/// 57% of distinct DNS questions went unanswered, because mDNSResponder's own patience
/// is shorter than our 8 s — so it gave up and re-asked, piling more queries onto the
/// same stalled upstream. The tunnel underneath was carrying traffic normally the whole
/// time; only name resolution was broken.
///
/// This moves an upstream that times out to the back of the order for a cooldown. It
/// never *removes* an upstream: when every upstream is penalized the natural order is
/// restored, so a pool-wide outage still tries all of them, and a penalty is a
/// preference rather than a filter. That matters because the common cause of every
/// upstream failing at once is the path itself going away, which says nothing about any
/// individual server.
struct UpstreamFanOutOrder {

    /// How long a timed-out upstream stays at the back of the order.
    ///
    /// Long enough to cover a stretch of queries rather than a single one — at the
    /// observed rate a 60 s penalty spans hundreds — and short enough that an upstream
    /// which recovers is back in its normal position well inside a single proxy
    /// lifetime, so this can never strand the pool in a degraded order.
    static let defaultPenaltyDuration: TimeInterval = 60

    let penaltyDuration: TimeInterval

    /// Parallel to the upstream array. `.distantPast` means "not penalized".
    private var penaltyExpiry: [Date]

    init(upstreamCount: Int, penaltyDuration: TimeInterval = UpstreamFanOutOrder.defaultPenaltyDuration) {
        self.penaltyDuration = penaltyDuration
        self.penaltyExpiry = Array(repeating: .distantPast, count: max(0, upstreamCount))
    }

    var upstreamCount: Int { penaltyExpiry.count }

    func isPenalized(_ index: Int, now: Date = Date()) -> Bool {
        guard penaltyExpiry.indices.contains(index) else { return false }
        return penaltyExpiry[index] > now
    }

    /// Demote an upstream that just timed out.
    ///
    /// Returns `true` only when this starts a *new* demotion — an upstream that was not
    /// already serving one. Refreshing an active penalty returns `false`, so a caller
    /// can log the transition without logging every repeat.
    @discardableResult
    mutating func penalize(_ index: Int, now: Date = Date()) -> Bool {
        guard penaltyExpiry.indices.contains(index) else { return false }
        let wasPenalized = penaltyExpiry[index] > now
        penaltyExpiry[index] = now.addingTimeInterval(penaltyDuration)
        return !wasPenalized
    }

    /// An upstream answered. Restore it immediately rather than waiting out a penalty
    /// that the evidence has just contradicted.
    mutating func clearPenalty(_ index: Int) {
        guard penaltyExpiry.indices.contains(index) else { return }
        penaltyExpiry[index] = .distantPast
    }

    /// The order to try upstreams in for one query.
    ///
    /// Unpenalized upstreams first in their natural order — so which upstream is tried
    /// first is unchanged whenever nothing has timed out — then penalized ones,
    /// soonest-to-recover first.
    func order(now: Date = Date()) -> [Int] {
        let indices = Array(penaltyExpiry.indices)
        let penalized = indices.filter { penaltyExpiry[$0] > now }

        // Nothing demoted, or everything demoted: in both cases the natural order is
        // the right answer, and in the second it is the only honest one — we have no
        // evidence that any upstream is better than any other.
        guard !penalized.isEmpty, penalized.count < indices.count else { return indices }

        let healthy = indices.filter { penaltyExpiry[$0] <= now }
        return healthy + penalized.sorted { penaltyExpiry[$0] < penaltyExpiry[$1] }
    }
}
