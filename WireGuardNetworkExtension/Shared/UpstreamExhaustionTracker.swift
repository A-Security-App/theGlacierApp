//
//  UpstreamExhaustionTracker.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 Sliding-window detector for sustained DoT upstream exhaustion.

 Pulled out of `DNSProxy` so the decision can be exercised without a network stack —
 it is pure bookkeeping: exhausted fan-outs in, one irreversible "ask for a respawn"
 out. The proxy owns an instance and feeds it from `noteUpstreamExhaustion`.

 ## The rule, and why it is shaped this way

 A fan-out where *every* upstream failed because the network path went away is not
 recorded at all. Respawning the extension cannot bring an interface back, and every
 query in flight when Wi-Fi drops fails in the same instant — measured on device at
 **11 fan-out failures inside 70 ms** during one ordinary Wi-Fi-to-cellular switch,
 against a threshold of 3. Counting those made a routine handoff indistinguishable
 from the saturated NECP flow table this escape hatch actually exists for, and cost a
 spurious tunnel cancel on every transition that happened to have traffic in flight.

 Everything else still counts, deliberately: ENOMEM, timeouts, dead pooled
 connections, and anything that could not be *positively* identified as path loss.
 The bias is toward preserving the existing recovery.

 It fires at most once. `DNSProxy` is discarded when the extension respawns, so a new
 instance starts a new window.
 */
struct UpstreamExhaustionTracker {

    /// How long a recorded failure keeps counting.
    let window: TimeInterval

    /// Failures needed inside `window` before a respawn is requested.
    let threshold: Int

    private var timestamps: [Date] = []
    private var hasFired = false

    init(window: TimeInterval = 120, threshold: Int = 3) {
        self.window = window
        self.threshold = threshold
    }

    /// Recorded failures currently inside the window. Meaningful immediately after
    /// `record(hadNonPathFailure:now:)`; used for the diagnostic message.
    var countInWindow: Int { timestamps.count }

    /// True once a respawn has been requested.
    var hasRequestedRespawn: Bool { hasFired }

    /// Record one fully exhausted fan-out.
    ///
    /// - Parameters:
    ///   - hadNonPathFailure: `false` when every upstream in the fan-out failed purely
    ///     because the network path went away. Those are not recorded at all.
    ///   - now: injectable clock, for tests.
    /// - Returns: `true` exactly once — on the call that crosses the threshold.
    mutating func record(hadNonPathFailure: Bool, now: Date = Date()) -> Bool {
        guard hadNonPathFailure else { return false }

        timestamps.append(now)
        let cutoff = now.addingTimeInterval(-window)
        timestamps.removeAll { $0 < cutoff }

        guard !hasFired, timestamps.count >= threshold else { return false }
        hasFired = true
        return true
    }
}
