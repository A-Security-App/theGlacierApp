//
//  DNSProxy.swift
//  WireGuardNetworkExtension
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Network
import os
import Security

final class DNSProxy {

    struct Configuration: Equatable {
        let listenAddress: String
        let listenPort: UInt16
        let upstreamServerName: String
        let upstreamPort: UInt16
        let upstreamAddresses: [String]
    }

    private let configuration: Configuration
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.theglacierapp.PacketTunnel.dns-proxy")
    private var inboundConnections: [ObjectIdentifier: NWConnection] = [:]
    private let logger = Logger(subsystem: "com.theglacierapp.Glacier", category: "dns-proxy")
    private let resolver: DoTResolver
    private let failureHandler: ((String) -> Void)?

    // Self-respawn escape hatch.  When all four upstreams repeatedly fail to answer a
    // query for a reason other than the network path going away, the NECP flow table
    // is saturated kernel-wide and the only reliable recovery is to ask NE to respawn
    // the extension (cancelTunnelWithError) so the kernel clears our flows and the new
    // process gets a fresh start.
    // One `.notice` per failure episode replaces the per-attempt lines, which are now
    // `.debug`.  An episode opens on the first fully exhausted fan-out and closes on the
    // next answered query (or at teardown), so a storm of failing queries produces one
    // durable line instead of four per query.  Measured before this change: 132 persisted
    // dns-proxy lines in a single minute, for one two-minute airplane-mode window.
    private var episodeStart: Date?
    private var episodeQueryCount = 0
    private var episodeLastFailure = ""

    // Escape hatch for an upstream set that has become unusable on the current
    // interface.  Distinct from the exhaustion callback below: that one asks NE to
    // respawn the whole extension for a saturated kernel flow table; this one just
    // rebuilds the proxy so the upstream hostnames are re-resolved against whatever
    // interface actually exists now.
    //
    // Measured 2026-09-08: a wake-driven proxy restart re-resolved upstreams while the
    // device was still on Wi-Fi, and four seconds later Wi-Fi dropped to IPv6-only 5G
    // where those addresses had no route.  DNS was dead for 163 s and 794 queries, and
    // recovery never came, because every mechanism that could have re-resolved declined:
    // the settings-driven check saw the same address *strings* and skipped, the
    // path-driven restart was inside its 30 s window, and the wake-driven restart was
    // inside its 300 s window.  Those limiters gate on time since the last restart and
    // have no way to know the current configuration stopped working.
    //
    // A fan-out that has failed continuously for this long, over this many queries, is
    // that missing signal.
    private let sustainedFailureCallback: (() -> Void)?
    private var hasFiredSustainedFailure = false
    /// Both must be met.  Duration alone would fire on a quiet interface blip; query
    /// count alone would fire on a burst.  At the ~5 queries/second observed during the
    /// 09-08 outage the duration is the binding constraint, which is the intent.
    private static let sustainedFailureMinDuration: TimeInterval = 20
    private static let sustainedFailureMinQueries = 25

    private let exhaustionCallback: (() -> Void)?
    // Decision logic lives in UpstreamExhaustionTracker so it can be tested without a
    // network stack; see that type for why path-only fan-outs are excluded.
    private var exhaustionTracker = UpstreamExhaustionTracker()

    init?(configuration: Configuration,
          failureHandler: ((String) -> Void)? = nil,
          onUpstreamExhaustion: (() -> Void)? = nil,
          onSustainedFailure: (() -> Void)? = nil) {
        guard let listenPort = NWEndpoint.Port(rawValue: configuration.listenPort) else { return nil }

        self.configuration = configuration
        self.failureHandler = failureHandler
        self.exhaustionCallback = onUpstreamExhaustion
        self.sustainedFailureCallback = onSustainedFailure

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(configuration.listenAddress),
                                                     port: listenPort)

        do {
            listener = try NWListener(using: parameters)
        } catch {
            logger.error("Failed to create DNS listener: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        resolver = DoTResolver(configuration: configuration,
                               callbackQueue: queue,
                               logger: logger)
    }

    var currentConfiguration: Configuration { configuration }

    func warmUp() {
        resolver.warmUp()
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.logger.error("DNS listener failed: \(error.localizedDescription, privacy: .public)")
                self?.failureHandler?(error.localizedDescription)
            case .ready:
                if let configuration = self?.configuration {
                    let port = Int(configuration.listenPort)
                    self?.logger.info("DNS listener ready on \(configuration.listenAddress, privacy: .private):\(port)")
                } else {
                    self?.logger.info("DNS listener ready")
                }
            case .cancelled:
                self?.logger.debug("DNS listener cancelled")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.logger.debug("Accepted DNS query connection from \(String(describing: connection.endpoint), privacy: .public)")
            self?.handle(connection: connection)
        }

        listener.start(queue: queue)
        resolver.warmUp()
        logger.debug("DNS proxy listening on \(self.configuration.listenAddress, privacy: .public):\(self.configuration.listenPort)")
    }

    func stop() {
        listener.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            // Close any open episode here too — the proxy is restarted often enough
            // (device wake, path change) that an episode ending in a teardown rather
            // than a successful query is a normal case, not an edge one.
            self.closeFailureEpisode(recovered: false)
            for connection in self.inboundConnections.values {
                connection.cancel()
            }
            self.inboundConnections.removeAll()
            self.resolver.invalidate()
        }
    }

    private func handle(connection: NWConnection) {
        queue.async { [weak self] in
            guard let self else { return }
            let identifier = ObjectIdentifier(connection)
            self.inboundConnections[identifier] = connection

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    self.logger.error("DNS UDP connection failed: \(error.localizedDescription, privacy: .public)")
                    self.removeInboundConnection(with: identifier)
                case .cancelled:
                    self.removeInboundConnection(with: identifier)
                default:
                    break
                }
            }

            connection.start(queue: self.queue)
            self.receive(on: connection, identifier: identifier)
        }
    }

    /// Opens an episode on the first exhausted fan-out and counts the rest.
    private func noteFailureEpisode(lastFailure: String) {
        if episodeStart == nil {
            episodeStart = Date()
            episodeQueryCount = 0
            hasFiredSustainedFailure = false
        }
        episodeQueryCount += 1
        episodeLastFailure = lastFailure

        guard !hasFiredSustainedFailure,
              let start = episodeStart,
              episodeQueryCount >= Self.sustainedFailureMinQueries else {
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= Self.sustainedFailureMinDuration else { return }

        hasFiredSustainedFailure = true
        logger.fault("Every DoT upstream has failed for \(Int(elapsed))s across \(self.episodeQueryCount) queries — requesting a proxy restart to re-resolve upstreams against the current interface")
        sustainedFailureCallback?()
    }

    /// Emits the one durable line for an episode and resets it.  `recovered` separates
    /// "a query got through again" from "the proxy went away mid-episode", which are
    /// different enough to be worth telling apart in a field capture.
    private func closeFailureEpisode(recovered: Bool) {
        guard let start = episodeStart else { return }
        let seconds = Date().timeIntervalSince(start)
        let upstreams = configuration.upstreamAddresses.count
        let outcome = recovered ? "recovered" : "proxy stopped"
        logger.notice("All \(upstreams) DoT upstreams failed for \(seconds, format: .fixed(precision: 1))s — \(self.episodeQueryCount) queries unanswered, \(outcome, privacy: .public) (last: \(self.episodeLastFailure, privacy: .public))")
        episodeStart = nil
        episodeQueryCount = 0
        episodeLastFailure = ""
        hasFiredSustainedFailure = false
    }

    private func removeInboundConnection(with identifier: ObjectIdentifier) {
        inboundConnections.removeValue(forKey: identifier)
    }

    // Called from `receive` (DNS proxy queue) every time all four upstreams fail
    // to answer a single query.  Maintains a sliding window of failure timestamps
    // and, once the threshold is reached, invokes the exhaustion callback exactly
    // once per DNSProxy instance.  The callback owner (PacketTunnelProvider) is
    // expected to call cancelTunnelWithError so NE respawns the extension with a
    // fresh kernel NECP context.
    //
    // `hadNonPathFailure` is false when every upstream in the fan-out failed purely
    // because the network path went away.  Those are excluded: a respawn cannot bring
    // an interface back, and every query in flight at the moment Wi-Fi drops fails in
    // the same instant, so a single handoff would otherwise fill the whole window on
    // its own.  Measured on device — three fan-out failures 4 ms apart tripping the
    // threshold immediately, for an ordinary Wi-Fi-to-cellular switch.  ENOMEM and
    // every failure we cannot positively attribute to path loss still count, so the
    // saturated-flow-table recovery this exists for is unchanged.
    private func noteUpstreamExhaustion(hadNonPathFailure: Bool) {
        guard exhaustionTracker.record(hadNonPathFailure: hadNonPathFailure) else { return }

        logger.fault("Upstream DoT exhaustion threshold reached (\(self.exhaustionTracker.countInWindow) full-fanout failures within \(Int(self.exhaustionTracker.window))s) — requesting tunnel respawn to recover NECP flow table")
        // The decision is made and the extension is about to be torn down.  Everything
        // still queued will fail against the same condition over the next few hundred
        // milliseconds; logging it buys nothing and evicts the rest of the app's
        // history from the device.
        resolver.quiesceLogging()
        exhaustionCallback?()
    }

    private func receive(on connection: NWConnection, identifier: ObjectIdentifier) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                self.logger.error("DNS receive error: \(error.localizedDescription, privacy: .public)")
                connection.cancel()
                self.removeInboundConnection(with: identifier)
                return
            }

            guard let data else {
                self.logger.debug("DNS receive returned without data; cancelling inbound connection")
                connection.cancel()
                self.removeInboundConnection(with: identifier)
                return
            }

            self.logger.debug("Received DNS query of \(data.count) bytes")

            self.resolver.resolve(query: data) { [weak self, weak connection] outcome in
                guard let self else { return }
                guard let connection else {
                    return
                }

                let finish: () -> Void = {
                    connection.cancel()
                    self.removeInboundConnection(with: identifier)
                }

                let response: Data
                switch outcome {
                case .answered(let data):
                    self.closeFailureEpisode(recovered: true)
                    response = data
                case .exhausted(let hadNonPathFailure, let lastFailure):
                    self.noteFailureEpisode(lastFailure: lastFailure)
                    self.noteUpstreamExhaustion(hadNonPathFailure: hadNonPathFailure)
                    finish()
                    return
                }

                self.logger.debug("Sending DNS response of \(response.count) bytes")
                connection.send(content: response, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if let sendError {
                        self.logger.error("Failed to send DNS response: \(sendError.localizedDescription, privacy: .public)")
                    }
                    finish()
                })
            }
        }
    }
}

// MARK: - DoT Resolver

private final class DoTResolver {

    /// Result of a full fan-out across every upstream.
    enum Outcome {
        case answered(Data)
        /// Every upstream failed.  `hadNonPathFailure` is true when at least one of
        /// them failed for a reason other than the path disappearing — the only case
        /// where the fan-out is evidence of something a respawn could recover from.
        /// `lastFailure` is the final upstream's error, carried out so the episode
        /// summary can name a cause now that the per-attempt lines are `.debug`.
        case exhausted(hadNonPathFailure: Bool, lastFailure: String)
    }

    private let upstreams: [UpstreamConnection]
    private let callbackQueue: DispatchQueue
    private let logger: Logger

    /// Set once the proxy has decided to ask for a respawn.  Everything still queued
    /// will fail against the same dead path over the next few hundred milliseconds;
    /// logging each one adds nothing to a decision already taken and, at the volumes
    /// measured (275 lines in 230 ms), evicts the rest of the app's history from the
    /// device.  Only mutated on the callback queue.
    private var isQuiesced = false

    /// Preference order for the fan-out.  An upstream that accepts a connection and then
    /// stops answering costs the full 8 s query timeout, and without this it costs it
    /// again on every subsequent query because the walk always restarts at index 0.  See
    /// `UpstreamFanOutOrder` for the device evidence.  Only mutated on `callbackQueue`.
    private var fanOutOrder: UpstreamFanOutOrder

    init(configuration: DNSProxy.Configuration, callbackQueue: DispatchQueue, logger: Logger) {
        self.callbackQueue = callbackQueue
        self.logger = logger
        self.fanOutOrder = UpstreamFanOutOrder(upstreamCount: configuration.upstreamAddresses.count)

        guard let upstreamPort = NWEndpoint.Port(rawValue: configuration.upstreamPort) else {
            fatalError("Invalid upstream port \(configuration.upstreamPort)")
        }

        upstreams = configuration.upstreamAddresses.map { address in
            UpstreamConnection(address: address,
                               port: upstreamPort,
                               serverName: configuration.upstreamServerName,
                               callbackQueue: callbackQueue,
                               logger: logger)
        }
    }

    func resolve(query: Data, completion: @escaping (Outcome) -> Void) {
        // Resolve the order once, up front, so a penalty landing mid-fan-out cannot
        // reorder the walk underneath a query that is already in flight.
        attemptResolve(query: query,
                       order: fanOutOrder.order(),
                       position: 0,
                       sawNonPathFailure: false,
                       lastFailure: "no upstreams configured",
                       completion: completion)
    }

    /// Stop logging per-query failure detail. Irreversible for the life of the
    /// resolver: it is only called when the extension is already being torn down.
    func quiesceLogging() {
        isQuiesced = true
        upstreams.forEach { $0.quiesceLogging() }
    }

    func warmUp() {
        upstreams.forEach { $0.warmUp() }
    }

    func invalidate() {
        upstreams.forEach { $0.invalidate() }
    }

    private func attemptResolve(query: Data,
                                order: [Int],
                                position: Int,
                                sawNonPathFailure: Bool,
                                lastFailure: String,
                                completion: @escaping (Outcome) -> Void) {
        guard position < order.count else {
            if !isQuiesced {
                // `.debug`: one of these per failed query, four upstreams at a time, is
                // what evicted the rest of the app's history from the device.  The
                // episode summary in DNSProxy carries the same information per episode.
                logger.debug("Exhausted all upstream DoT addresses without a response")
            }
            completion(.exhausted(hadNonPathFailure: sawNonPathFailure, lastFailure: lastFailure))
            return
        }

        let upstreamIndex = order[position]
        let upstream = upstreams[upstreamIndex]
        upstream.send(query: query) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                // Evidence beats the penalty: an upstream that just answered is not
                // one we should keep at the back of the queue.
                self.fanOutOrder.clearPenalty(upstreamIndex)
                completion(.answered(response))
            case .failure(let error):
                if !self.isQuiesced {
                    self.logger.debug("DoT upstream \(upstream.address, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                if error.isTimeout, self.fanOutOrder.penalize(upstreamIndex), !self.isQuiesced {
                    // `.notice`, and only on the transition into a penalty rather than on
                    // every repeat: during the 09-10 outage that is roughly one line per
                    // minute, each marking a real change in which upstreams we prefer.
                    self.logger.notice("DoT upstream \(upstream.address, privacy: .public) timed out — deprioritizing for \(Int(self.fanOutOrder.penaltyDuration))s")
                }
                self.attemptResolve(query: query,
                                    order: order,
                                    position: position + 1,
                                    sawNonPathFailure: sawNonPathFailure || !error.isPathRelated,
                                    lastFailure: error.errorDescription ?? "unknown",
                                    completion: completion)
            }
        }
    }
}

// MARK: - Upstream Connection

private final class UpstreamConnection {

    let address: String

    private let port: NWEndpoint.Port
    private let serverName: String
    private let callbackQueue: DispatchQueue
    private let logger: Logger
    private let queue: DispatchQueue
    private let timeoutInterval: TimeInterval = 8

    private var connection: NWConnection?
    private var connectionGeneration = 0
    private var isReady = false
    private var readinessCallbacks: [(Bool) -> Void] = []
    private var pendingRequests: [Request] = []
    private var currentRequest: Request?
    private var timeoutWorkItem: DispatchWorkItem?
    private var timeoutGeneration = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var recycleWorkItem: DispatchWorkItem?
    private var isBackingOffFromENOMEM = false
    private var enomemAttempt = 0
    /// See `DoTResolver.quiesceLogging()`. Only mutated on `queue`.
    private var isQuiesced = false
    private var lastPathStatus: NWPath.Status?
    private var lastUsedTime: Date?
    private var connectionCreatedAt: Date?
    private let staleConnectionThreshold: TimeInterval = 5 * 60   // 5 minutes

    // MARK: - Pool de-correlation
    //
    // Every upstream is built in DoTResolver.init and warmed by the same warmUp() call,
    // so without jitter the whole pool is exactly the same age: the connections go idle
    // together, are closed by the upstream together, and recycle together.  Observed on
    // device as four "reached max lifetime" lines inside 376 microseconds, and — more
    // expensively — as all four upstreams reporting a closed connection in the same
    // millisecond, which is what turns one dead pooled connection into a fully failed
    // fan-out.  Four upstreams should buy redundancy against a time-correlated failure,
    // not just against one server being down.
    //
    // Both offsets are drawn once per instance.  A proxy restart builds fresh
    // UpstreamConnections and redraws them, so the pool cannot settle back into phase.

    /// Cellular NAT tables typically time out TCP sessions after ~10 minutes. Recycle
    /// before that so we never send a query into a session the far side has torn down.
    private static let baseConnectionLifetime: TimeInterval = 8 * 60   // 8 minutes
    /// Spread of recycle deadlines across the pool. Kept well under the ~10 minute NAT
    /// timeout the base value is defending against, so the jitter cannot defeat it.
    private static let connectionLifetimeJitter: TimeInterval = 90
    /// Spread of pre-warm start times. Small on purpose: a query arriving inside the
    /// stagger is served by ensureConnectionReady() creating the connection on demand,
    /// which is the same path taken when warmUp() has not run at all, so this cannot
    /// make a cold start worse than the pre-existing fallback.
    private static let maxWarmUpStagger: TimeInterval = 3
    /// Ceiling on speculative reconnect backoff. See `scheduleReconnect`.
    private static let maxReconnectDelay: TimeInterval = 60

    private let maxConnectionLifetime: TimeInterval
    private let warmUpDelay: TimeInterval

    // MARK: - Class-level ENOMEM cooldown
    //
    // Per-instance isBackingOffFromENOMEM is zeroed whenever the proxy restarts (each
    // restart creates fresh UpstreamConnection instances).  Without a cross-instance
    // signal, warmUp() on those fresh instances fires four speculative connections
    // directly into a still-saturated NECP flow table, adding four more zombie entries
    // per restart — accumulating hundreds over a 15-minute cellular session.
    //
    // This static cooldown is set whenever ANY upstream observes ENOMEM.  Both
    // warmUp() and ensureConnectionReady() (on-demand creation) check it before
    // creating new connections; while active, ensureConnectionReady() queues
    // readiness callbacks and schedules a reconnect timed to the cooldown's
    // expiry, so DNS queries are served as soon as the kernel reclaims flows.
    private static let globalENOMEMStateQueue = DispatchQueue(label: "com.theglacierapp.PacketTunnel.enomem-state")
    private static var _globalENOMEMCooldownUntil: Date = .distantPast
    // 300 s is sized for kernel NECP-flow reclaim under sustained pressure, which
    // empirically takes minutes — not seconds — once the table is saturated.  A
    // shorter cooldown (the original 30 s) expires between wake events on a
    // stationary phone (~60-90 s IKEv2 keep-alive cadence), so every other wake
    // creates four more zombie flows and the table never drains.  5 min outlasts
    // the wake cadence and gives the kernel a real drain window.
    private static let globalENOMEMCooldownDuration: TimeInterval = 300.0

    private static func noteGlobalENOMEM() {
        let until = Date().addingTimeInterval(globalENOMEMCooldownDuration)
        globalENOMEMStateQueue.async {
            if until > _globalENOMEMCooldownUntil {
                _globalENOMEMCooldownUntil = until
            }
        }
    }

    private static func isGlobalENOMEMCooldownActive() -> Bool {
        return globalENOMEMStateQueue.sync { Date() < _globalENOMEMCooldownUntil }
    }

    private static func globalENOMEMRemainingDelay() -> TimeInterval {
        return globalENOMEMStateQueue.sync { max(0, _globalENOMEMCooldownUntil.timeIntervalSinceNow) }
    }

    init(address: String,
         port: NWEndpoint.Port,
         serverName: String,
         callbackQueue: DispatchQueue,
         logger: Logger) {
        self.address = address
        self.port = port
        self.serverName = serverName
        self.callbackQueue = callbackQueue
        self.logger = logger
        maxConnectionLifetime = Self.baseConnectionLifetime
            + .random(in: 0...Self.connectionLifetimeJitter)
        warmUpDelay = .random(in: 0...Self.maxWarmUpStagger)
        queue = DispatchQueue(label: "com.theglacierapp.PacketTunnel.dot-upstream.\(address)")
    }

    /// Stop logging per-attempt connection detail — the extension is being torn down.
    func quiesceLogging() {
        queue.async { [weak self] in
            self?.isQuiesced = true
        }
    }

    func warmUp() {
        // Staggered per upstream; see "Pool de-correlation" above.  warmUp() is
        // speculative, and the connection == nil guard means a query that arrives
        // during the delay and creates the connection itself simply makes this a no-op.
        queue.asyncAfter(deadline: .now() + warmUpDelay) { [weak self] in
            guard let self, self.connection == nil else { return }
            // If any upstream recently hit ENOMEM the NECP flow table is (or was just)
            // full.  Creating a speculative connection now would immediately fail again
            // and add yet another zombie entry to the table — exactly the cascade we
            // saw accumulate 490 entries over 15 minutes of cellular use.
            // Real DNS queries that arrive during the cooldown are also gated by
            // ensureConnectionReady() and held until the cooldown expires.
            if UpstreamConnection.isGlobalENOMEMCooldownActive() {
                self.logger.debug("Skipping warmUp for \(self.address, privacy: .public) — global ENOMEM cooldown active")
                return
            }
            self.logger.debug("Pre-warming DoT connection to \(self.address, privacy: .public)")
            self.createConnection()
        }
    }

    func send(query: Data, completion: @escaping (Result<Data, ResolverError>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let request = Request(query: query, completion: completion)
            self.pendingRequests.append(request)
            self.processQueue()
        }
    }

    func invalidate() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isBackingOffFromENOMEM = false
            self.enomemAttempt = 0
            self.cancelTimeout()
            self.resetConnection()
            if let currentRequest = self.currentRequest {
                self.finish(request: currentRequest, with: .failure(.cancelled))
                self.currentRequest = nil
            }
            for request in self.pendingRequests {
                self.finish(request: request, with: .failure(.cancelled))
            }
            self.pendingRequests.removeAll()
        }
    }

    private func processQueue() {
        guard currentRequest == nil, !pendingRequests.isEmpty else { return }

        // If the connection appears ready but has been idle long enough for NAT/firewall
        // state table entries to have expired, reset it preemptively so the zombie is
        // discarded before a real query depends on it.  ensureConnectionReady() below
        // will create a fresh connection transparently.
        if isReady, let lastUsed = lastUsedTime,
           Date().timeIntervalSince(lastUsed) > staleConnectionThreshold {
            logger.info("DoT connection to \(self.address, privacy: .public) idle for >\(Int(self.staleConnectionThreshold))s — resetting preemptively to avoid zombie")
            resetConnection()
        }

        if isReady, let createdAt = connectionCreatedAt,
           Date().timeIntervalSince(createdAt) > maxConnectionLifetime {
            logger.info("DoT connection to \(self.address, privacy: .public) age >\(Int(self.maxConnectionLifetime))s — recycling proactively to prevent cellular NAT timeout")
            resetConnection()
        }

        currentRequest = pendingRequests.removeFirst()

        ensureConnectionReady { [weak self] ready in
            guard let self, ready else {
                // Connection failed before becoming ready. The state handler that called
                // flushReadinessCallbacks has already captured and failed currentRequest.
                // scheduleReconnect() handles backoff; processQueue() is also driven from
                // the failure handlers to immediately retry any pending queries.
                return
            }

            // Start the per-request timeout only after the connection is ready so that
            // it covers the data-transfer phase (send + receive) rather than the
            // connection-establishment phase.  On cellular cold-start, WireGuard's initial
            // peer handshake can take several seconds; the NWConnection sits in .preparing
            // until WireGuard finishes.  Starting the timeout before ensureConnectionReady
            // returned caused it to fire during .preparing, making every DNS query time out
            // before WireGuard had a chance to establish — breaking cellular entirely.
            // A "zombie" connection (appears .ready but data never flows) is still caught:
            // the timeout fires 8 s after the first send attempt and resets the connection.
            self.startTimeout()
            self.sendCurrentRequest()
        }
    }

    private func ensureConnectionReady(_ completion: @escaping (Bool) -> Void) {
        if isReady, connection != nil {
            completion(true)
            return
        }

        readinessCallbacks.append(completion)

        if connection == nil {
            if isBackingOffFromENOMEM {
                // The NECP flow table was recently full. Creating a connection now would
                // immediately fail with ENOMEM again, keeping the table loaded and
                // preventing recovery. The scheduled reconnectWorkItem will call
                // createConnection() once the backoff elapses; pending queries will be
                // served through the readinessCallbacks queued above.
            } else if UpstreamConnection.isGlobalENOMEMCooldownActive() {
                // A sibling upstream (possibly on a different UpstreamConnection instance
                // created by a proxy restart) hit ENOMEM recently. Creating a connection
                // right now would almost certainly fail again. Adopt per-instance backoff
                // state tied to the remaining global cooldown so that the reconnect timer
                // fires when the cooldown expires rather than immediately.
                isBackingOffFromENOMEM = true
                scheduleReconnect(after: UpstreamConnection.globalENOMEMRemainingDelay() + 0.5)
            } else {
                createConnection()
            }
        }
    }

    private func createConnection() {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, serverName)

        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true

        let connection = NWConnection(host: NWEndpoint.Host(address),
                                      port: port,
                                      using: parameters)

        // Capture the current generation so that state/path updates from this specific
        // connection are ignored if resetConnection() has already moved on to a newer one.
        let generation = connectionGeneration
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                guard self.connectionGeneration == generation else { return }
                self.handleStateUpdate(state)
            }
        }

        connectionCreatedAt = Date()
        scheduleRecycle()
        self.connection = connection
        connection.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.queue.async {
                guard self.connectionGeneration == generation else { return }
                self.handlePathUpdate(path)
            }
        }
        connection.start(queue: queue)
    }

    private func handleStateUpdate(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.debug("TLS connection ready for upstream \(self.address, privacy: .public):\(self.port.rawValue)")
            isReady = true
            lastUsedTime = Date()
            reconnectAttempt = 0
            isBackingOffFromENOMEM = false
            enomemAttempt = 0
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            flushReadinessCallbacks(with: true)
            // Drive any requests that queued up while the connection was being established.
            processQueue()
        case .waiting(let error):
            if !isQuiesced {
                // `.debug`: per upstream, per attempt. See the episode summary in DNSProxy.
                logger.debug("DoT connection waiting for upstream \(self.address, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            isReady = false
            // Cancel the per-request timeout — it was started in processQueue() when the
            // request was dequeued, and fires relative to that moment.  Without cancelling
            // here the stale timer fires ~8 s later, calls handleFailure (finds no request),
            // and calls resetConnection() — silently killing a healthy reconnected connection.
            cancelTimeout()
            let failedRequest = currentRequest
            currentRequest = nil
            resetConnection()
            flushReadinessCallbacks(with: false)
            if let request = failedRequest {
                // ENOMEM here is the saturated-flow-table condition the respawn escape
                // hatch exists for, so it must stay classified as a real failure.  A
                // plain network-down is the opposite: it is what an interface handoff
                // looks like to whatever was in flight.
                let failure: ResolverError = isPathLoss(error) && !isENOMEM(error)
                    ? .pathUnavailable("Connection temporarily unavailable")
                    : .connectionFailed("Connection temporarily unavailable")
                finish(request: request, with: .failure(failure))
            }
            if isENOMEM(error) {
                // The kernel NECP flow table is full.  Two problems to avoid:
                // 1. Creating a connection RIGHT NOW would also fail with ENOMEM, worsening
                //    the situation by adding another half-allocated flow to the table.
                // 2. Every incoming DNS query calls ensureConnectionReady() which, without
                //    a guard, calls createConnection() directly — bypassing the timer and
                //    spinning ENOMEM hundreds of times per minute.
                // Solution: set isBackingOffFromENOMEM so ensureConnectionReady() queues
                // readiness callbacks but does NOT call createConnection().  Use exponential
                // backoff so that successive failures allow progressively more drain time.
                isBackingOffFromENOMEM = true
                let enomemDelay = min(30.0 * pow(2.0, Double(enomemAttempt)), 300.0)
                enomemAttempt += 1
                logger.fault("DoT connection to \(self.address, privacy: .public) hit ENOMEM (attempt \(self.enomemAttempt)) — backing off \(Int(enomemDelay))s to let NECP reclaim flows")
                // Record ENOMEM globally so that a proxy restart within the next 30 s does
                // not immediately fire warmUp() into the still-saturated flow table.
                UpstreamConnection.noteGlobalENOMEM()
                scheduleReconnect(after: enomemDelay)
                // Do NOT call processQueue() here — that would create another connection.
            } else {
                isBackingOffFromENOMEM = false
                enomemAttempt = 0
                scheduleReconnect()
                // Immediately serve any pending DNS queries on a new connection rather than
                // waiting for the exponential backoff. On cellular, WireGuard's initial
                // handshake causes the first connection to fail; without this call, pending
                // queries sit in pendingRequests for 1–8s (backoff) before retrying, which
                // is long enough for DNS clients to give up. This is safe: currentRequest is
                // already nil, connectionGeneration was incremented by resetConnection() so
                // stale callbacks are ignored, and scheduleReconnect() guards against a
                // duplicate connection if processQueue() already creates one.
                processQueue()
            }
        case .failed(let error):
            logger.error("DoT connection failed for upstream \(self.address, privacy: .public): \(error.localizedDescription, privacy: .public)")
            isReady = false
            cancelTimeout()  // see .waiting case for rationale
            let failedRequest = currentRequest
            currentRequest = nil
            resetConnection()
            flushReadinessCallbacks(with: false)
            if let request = failedRequest {
                finish(request: request, with: .failure(.connectionFailed("Connection became unavailable")))
            }
            if isENOMEM(error) {
                isBackingOffFromENOMEM = true
                let enomemDelay = min(30.0 * pow(2.0, Double(enomemAttempt)), 300.0)
                enomemAttempt += 1
                logger.fault("DoT connection to \(self.address, privacy: .public) hit ENOMEM (attempt \(self.enomemAttempt)) — backing off \(Int(enomemDelay))s to let NECP reclaim flows")
                // Record ENOMEM globally so that a proxy restart within the next 30 s does
                // not immediately fire warmUp() into the still-saturated flow table.
                UpstreamConnection.noteGlobalENOMEM()
                scheduleReconnect(after: enomemDelay)
                // Do NOT call processQueue() — same rationale as .waiting case above.
            } else {
                isBackingOffFromENOMEM = false
                enomemAttempt = 0
                scheduleReconnect()
                processQueue()  // same rationale as .waiting case above
            }
        case .cancelled:
            isReady = false
            cancelTimeout()  // see .waiting case for rationale
            let failedRequest = currentRequest
            currentRequest = nil
            resetConnection()
            flushReadinessCallbacks(with: false)
            if let request = failedRequest {
                finish(request: request, with: .failure(.connectionFailed("Connection cancelled")))
            }
            // Cancellation is intentional (from resetConnection / invalidate); no reconnect.
        default:
            break
        }
    }

    private func handlePathUpdate(_ path: NWPath) {
        let status = path.status
        guard status != lastPathStatus else { return }
        lastPathStatus = status

        switch status {
        case .satisfied:
            logger.debug("Path satisfied for DoT upstream \(self.address, privacy: .public)")
            if connection == nil {
                // Reconnect immediately — a newly satisfied path is worth trying at once.
                // But deliberately do NOT reset reconnectAttempt here: a satisfied path is
                // not evidence this upstream is reachable, only that *some* route exists.
                // On an IPv6-only cellular network an IPv4 upstream literal has no route
                // at all, while the path still flaps satisfied/unsatisfied with link
                // quality — and resetting here meant the backoff could never escalate, so
                // we retried a permanently unroutable address every few seconds for as
                // long as the device was off Wi-Fi (measured: ~10,000 failed path
                // evaluations per hour, and zero on Wi-Fi).  Only `.ready` clears it now.
                scheduleReconnect(after: 0)
            }
        case .requiresConnection, .unsatisfied:
            if !isQuiesced {
                // `.debug`: per upstream, per path change. See the episode summary in DNSProxy.
                logger.debug("Path unavailable for DoT upstream \(self.address, privacy: .public) (status: \(String(describing: status)))")
            }
            isReady = false
            // A path/interface change means a different NECP context — clear the ENOMEM
            // backoff so we don't carry stale state from the previous interface into
            // reconnection on the new one.
            isBackingOffFromENOMEM = false
            enomemAttempt = 0
            cancelTimeout()  // see handleStateUpdate(.waiting) for rationale
            let failedRequest = currentRequest
            currentRequest = nil
            resetConnection()
            flushReadinessCallbacks(with: false)
            if let request = failedRequest {
                finish(request: request, with: .failure(.pathUnavailable("Network path unavailable")))
            }
            scheduleReconnect()
            processQueue()  // same rationale as handleStateUpdate(.waiting/.failed) above
        @unknown default:
            break
        }
    }

    private func resetConnection() {
        recycleWorkItem?.cancel()
        recycleWorkItem = nil
        connection?.cancel()
        connection = nil
        isReady = false
        connectionCreatedAt = nil
        connectionGeneration &+= 1  // invalidate state/path updates from the cancelled connection
    }

    /// Schedules a time-triggered recycle to fire at maxConnectionLifetime seconds after the
    /// connection was created.  This is the primary defence against cellular NAT timeouts: carrier
    /// NAT tables silently expire TCP sessions after ~10 minutes, so we proactively tear down and
    /// re-establish the DoT connection at 8 minutes regardless of query activity.  The
    /// processQueue() age check is a belt-and-suspenders fallback, but it is edge-triggered (only
    /// runs when a query arrives) and therefore does not fire when the phone is idle.
    private func scheduleRecycle() {
        recycleWorkItem?.cancel()
        // Gate on connectionGeneration: if the connection is reset for any other reason before
        // the timer fires, the incremented generation makes this work item a no-op.
        let generation = connectionGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            self.performScheduledRecycle()
        }
        recycleWorkItem = workItem
        queue.asyncAfter(deadline: .now() + maxConnectionLifetime, execute: workItem)
    }

    private func performScheduledRecycle() {
        guard isReady else { return }  // already reset/reconnecting — nothing to do

        if currentRequest != nil {
            // A request is in-flight; interrupting now would fail it. Defer briefly and retry.
            logger.debug("DoT connection to \(self.address, privacy: .public) due for proactive recycle but request in-flight — deferring 5s")
            let generation = connectionGeneration
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                self.performScheduledRecycle()
            }
            recycleWorkItem = workItem
            queue.asyncAfter(deadline: .now() + 5, execute: workItem)
            return
        }

        // `.notice` rather than `.info`, permanently.  Two reasons, both learned the
        // hard way.
        //
        // First, `.info` is never written to disk — verified against the 2026-09-11
        // archive, which holds zero `messageType == info` records from any process on the
        // device — so this line was unobservable in every field capture by every
        // collection method available, and the pool jitter shipped in `a4dcca7` went
        // sixteen days unverified as a result.  Promoting it produced the confirmation
        // immediately: 26 recycles overnight on 2026-09-12, 22 distinct jittered
        // lifetimes spanning 481-569 s, tightest pair 34 s apart against the 376 µs
        // lockstep the jitter was written for.
        //
        // Second, and why it stays: proactive recycling is the primary defence against
        // carrier NAT silently expiring our TCP sessions at ~10 minutes, and it fails
        // *silently* — a defence that stops firing looks exactly like one that has
        // nothing to do.  This line is the only signal that it is still running.
        //
        // Measured cost is ~4.3 lines/hour, well under the ~680/day ceiling implied by
        // four upstreams cycling every ~8.5 min, because proxy restarts pre-empt roughly
        // 80% of connections before they age out.  The same change demoted the
        // wake-suppression line, and overnight volume still fell 60% net.
        logger.notice("DoT connection to \(self.address, privacy: .public) reached max lifetime (\(Int(self.maxConnectionLifetime))s) — recycling proactively to prevent cellular NAT timeout")
        resetConnection()
        // Immediately start a fresh connection so it's warm for the next query.
        scheduleReconnect(after: 0)
    }

    private func flushReadinessCallbacks(with result: Bool) {
        let callbacks = readinessCallbacks
        readinessCallbacks.removeAll()
        for callback in callbacks {
            callback(result)
        }
    }

    private func sendCurrentRequest() {
        guard let connection, let request = currentRequest else { return }

        // Capture generation so that if resetConnection() is called while this request
        // is in-flight (e.g. by a timeout that fires before the send callback), stale
        // send/receive callbacks for the old connection do not disrupt the new connection.
        let generation = connectionGeneration

        var length = UInt16(request.query.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        var payload = Data(header)
        payload.append(request.query)

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.connectionGeneration == generation else { return }
                if let error {
                    self.logger.error("Failed to send DoT query to \(self.address, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.handleFailure(.connectionFailed("Send error"))
                    return
                }

                self.receiveLength(generation: generation)
            }
        })
    }

    private func receiveLength(generation: Int) {
        guard let connection else { return }

        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard self.connectionGeneration == generation else { return }
                if let error {
                    // A reset here is the other face of a stale pooled connection: the
                    // upstream tore it down and the kernel answers our read with ECONNRESET
                    // rather than a clean FIN.  Same cause, same fix.
                    if self.isConnectionReset(error), self.retryOnDeadConnection() {
                        self.logger.notice("DoT upstream \(self.address, privacy: .public) reset a pooled connection — replaying query on a fresh one")
                        return
                    }
                    self.logger.error("Error receiving DoT response length from \(self.address, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.handleFailure(.connectionFailed("Receive error"))
                    return
                }

                guard let data, data.count == 2 else {
                    if data == nil || data!.isEmpty {
                        // Clean FIN with no answer — the upstream had already closed this
                        // connection while it sat idle.  Replay once on a fresh one.
                        if self.retryOnDeadConnection() {
                            self.logger.notice("DoT upstream \(self.address, privacy: .public) closed a pooled connection — replaying query on a fresh one")
                            return
                        }
                        self.logger.error("DoT upstream \(self.address, privacy: .public) closed connection before sending response (isComplete: \(isComplete)) — tunnel may be down")
                    } else {
                        self.logger.error("DoT upstream \(self.address, privacy: .public) sent truncated length prefix: \(data!.count) byte(s) (isComplete: \(isComplete))")
                    }
                    self.handleFailure(.invalidResponse("Missing length prefix"))
                    return
                }

                let messageLength = Int(data.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
                self.receivePayload(expectedLength: messageLength, accumulated: Data(), generation: generation)
            }
        }
    }

    private func receivePayload(expectedLength: Int, accumulated: Data, generation: Int) {
        guard let connection else { return }

        let remaining = max(expectedLength - accumulated.count, 0)
        if remaining == 0 {
            completeCurrent(with: accumulated)
            return
        }

        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                guard self.connectionGeneration == generation else { return }
                if let error {
                    self.logger.error("Error receiving DoT payload from \(self.address, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.handleFailure(.connectionFailed("Receive error"))
                    return
                }

                guard let data, !data.isEmpty else {
                    self.logger.error("Received empty DoT payload chunk from \(self.address, privacy: .public)")
                    self.handleFailure(.invalidResponse("Empty payload"))
                    return
                }

                var newAccumulated = accumulated
                newAccumulated.append(data)
                if newAccumulated.count >= expectedLength {
                    self.completeCurrent(with: Data(newAccumulated.prefix(expectedLength)))
                } else {
                    self.receivePayload(expectedLength: expectedLength, accumulated: newAccumulated, generation: generation)
                }
            }
        }
    }

    private func completeCurrent(with data: Data) {
        cancelTimeout()
        guard let request = currentRequest else { return }
        lastUsedTime = Date()
        finish(request: request, with: .success(data))
        currentRequest = nil
        processQueue()
    }

    /// A connection we believed was usable turned out to be dead — the upstream had
    /// already closed it while it sat idle in the pool, and we only find out when the
    /// query we just sent comes back as a clean FIN or a reset.  The query itself is
    /// fine; only the socket was stale.  Re-establish and replay it once.
    ///
    /// This matters because it is not a rare edge: all four upstreams go idle together,
    /// so they go stale together, and `DoTResolver.attemptResolve` walking to the next
    /// upstream finds it dead for exactly the same reason.  Measured on device at
    /// roughly one unanswered lookup per 7.5 minutes on healthy Wi-Fi, and reproduced
    /// as a page that would not load 4m44s after a proxy restart.
    ///
    /// Deliberately narrow.  Only a dead-pooled-connection signature qualifies —
    /// timeouts, path loss and ENOMEM all fall straight through to `handleFailure`,
    /// because retrying those would add latency without changing the outcome.  The
    /// per-request flag caps this at one extra attempt.
    ///
    /// The two call sites log the recovery at `.notice` rather than `.debug`, against
    /// the general direction of travel for this category.  It is deliberate: the line
    /// fires once per stale episode (~1 per 7.5 min at the observed rate), not per
    /// attempt, and it answers a question worth answering from a user's device — are
    /// the upstreams closing pooled connections in the field, and are we recovering?
    /// It is the one line in this path with real diagnostic value per byte.
    ///
    /// Returns true when the query has been re-queued, false when the caller should
    /// fail it normally.
    private func retryOnDeadConnection() -> Bool {
        guard var request = currentRequest, !request.hasRetriedOnDeadConnection else { return false }
        request.hasRetriedOnDeadConnection = true

        cancelTimeout()
        // Clear currentRequest before resetConnection so the state/path handlers cannot
        // also observe and fail it, and flush stale readiness callbacks for the same
        // reason handleFailure does — without this they fire when the replacement
        // connection becomes ready and cause a double-send.
        currentRequest = nil
        resetConnection()
        flushReadinessCallbacks(with: false)

        // Front of the queue: this query was already dequeued once, so re-queueing it
        // behind later arrivals would reorder it behind queries it preceded.
        pendingRequests.insert(request, at: 0)
        processQueue()
        return true
    }

    private func handleFailure(_ error: ResolverError) {
        cancelTimeout()
        // Capture and clear currentRequest BEFORE resetConnection so the state/path
        // update handlers (which check generation) cannot also observe and fail it.
        let failedRequest = currentRequest
        currentRequest = nil
        resetConnection()
        // Flush any readiness callbacks that were added by ensureConnectionReady but
        // never fired (e.g. connection was in .preparing when the timeout hit).
        // Without this flush, the stale callbacks accumulate in readinessCallbacks and
        // fire spuriously when the *next* connection becomes .ready, causing a double-send.
        flushReadinessCallbacks(with: false)
        guard let request = failedRequest else { return }
        finish(request: request, with: .failure(error))
        processQueue()
    }

    private func finish(request: Request, with result: Result<Data, ResolverError>) {
        callbackQueue.async {
            request.completion(result)
        }
    }

    private func startTimeout() {
        cancelTimeout()
        guard currentRequest != nil else { return }

        // Capture generation so that a stale work item that was already queued when
        // cancel() was called (DispatchWorkItem.cancel() only sets a flag but does not
        // prevent execution of already-enqueued items) cannot fire spuriously.
        let generation = timeoutGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.timeoutGeneration == generation else { return }
            self.logger.error("DoT query to \(self.address, privacy: .public) timed out")
            self.handleFailure(.timeout)
        }

        timeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + timeoutInterval, execute: workItem)
    }

    private func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        timeoutGeneration &+= 1  // invalidate any in-flight work item by incrementing generation
    }

    private func isENOMEM(_ error: Error) -> Bool {
        guard case .posix(let code) = error as? NWError else { return false }
        return code == .ENOMEM
    }

    /// The upstream tore down a connection we were holding.  Distinct from path loss:
    /// the network is fine, the socket is not.
    private func isConnectionReset(_ error: Error) -> Bool {
        guard case .posix(let code) = error as? NWError else { return false }
        return code == .ECONNRESET || code == .ENOTCONN || code == .EPIPE
    }

    /// The path went away rather than anything being wrong with the upstream or the
    /// kernel.  ENETDOWN (50) is what every observed Wi-Fi-off transition produces.
    /// Deliberately narrow: an error we cannot positively identify as path loss keeps
    /// counting toward exhaustion, so this can only ever suppress a respawn we are
    /// sure was pointless.
    private func isPathLoss(_ error: Error) -> Bool {
        guard case .posix(let code) = error as? NWError else { return false }
        return code == .ENETDOWN || code == .ENETUNREACH || code == .EHOSTUNREACH
    }

    private func scheduleReconnect(after delay: TimeInterval? = nil) {
        reconnectWorkItem?.cancel()
        let reconnectDelay: TimeInterval
        if let delay {
            reconnectDelay = max(0, delay)
        } else {
            reconnectAttempt += 1
            // Cap raised from 8 s: an upstream with no route on the current interface
            // should settle into a slow poll, not a fast one.  Safe because this backoff
            // governs *speculative* re-warming only — ensureConnectionReady() creates a
            // connection immediately when a real query arrives and there is none, so a
            // long delay here never slows resolution.  A working upstream resets to 0 the
            // moment it reaches `.ready`, so it never accumulates any of this.
            reconnectDelay = min(pow(2.0, Double(max(reconnectAttempt - 1, 0))), Self.maxReconnectDelay)
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard self.connection == nil else { return }
            self.createConnection()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + reconnectDelay, execute: workItem)
    }

    private struct Request {
        let query: Data
        let completion: (Result<Data, ResolverError>) -> Void
        /// Set once this query has already been replayed on a fresh connection after a
        /// dead pooled connection.  Bounds the retry at exactly one attempt so an
        /// upstream that closes every connection cannot loop.
        var hasRetriedOnDeadConnection = false
    }
}

// MARK: - Resolver Error

private enum ResolverError: LocalizedError {
    case connectionFailed(String)
    /// The network path itself went away — an interface dropping, or a POSIX
    /// network-down/unreachable error while a handoff is in progress.  Kept distinct
    /// from `connectionFailed` because a fan-out that failed *only* for this reason
    /// says nothing about upstream or kernel health, and so must not feed the
    /// respawn escape hatch.  See `DNSProxy.noteUpstreamExhaustion(hadNonPathFailure:)`.
    case pathUnavailable(String)
    case timeout
    case invalidResponse(String)
    case cancelled

    /// The expensive failure: the upstream took the connection, completed TLS, and then
    /// never answered, so we paid the whole query timeout to learn nothing.  Every other
    /// failure mode reports back in milliseconds.  Drives `UpstreamFanOutOrder`.
    var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }

    /// True only for failures we can attribute to the path disappearing underneath us.
    /// Anything ambiguous deliberately reports false, so it still counts toward
    /// exhaustion and the existing recovery behaviour is preserved.
    var isPathRelated: Bool {
        if case .pathUnavailable = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let description):
            return description
        case .pathUnavailable(let description):
            return description
        case .timeout:
            return "Request timed out"
        case .invalidResponse(let description):
            return description
        case .cancelled:
            return "Request cancelled"
        }
    }
}
