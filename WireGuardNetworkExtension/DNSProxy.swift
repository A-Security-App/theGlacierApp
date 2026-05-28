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
    private let queue = DispatchQueue(label: "com.glacier.PacketTunnel.dns-proxy")
    private var inboundConnections: [ObjectIdentifier: NWConnection] = [:]
    private let logger = Logger(subsystem: "com.glacier.Glacier", category: "dns-proxy")
    private let resolver: DoTResolver
    private let failureHandler: ((String) -> Void)?

    // Self-respawn escape hatch.  When all four upstreams fail to answer a query
    // exhaustionWindowThreshold times within exhaustionWindowDuration, the NECP
    // flow table is saturated kernel-wide and the only reliable recovery is to
    // ask NE to respawn the extension (cancelTunnelWithError) so the kernel
    // clears our flows and the new process gets a fresh start.
    private let exhaustionCallback: (() -> Void)?
    private var exhaustionTimestamps: [Date] = []
    private var hasFiredExhaustionCallback = false
    private static let exhaustionWindowDuration: TimeInterval = 120.0
    private static let exhaustionWindowThreshold = 3

    init?(configuration: Configuration,
          failureHandler: ((String) -> Void)? = nil,
          onUpstreamExhaustion: (() -> Void)? = nil) {
        guard let listenPort = NWEndpoint.Port(rawValue: configuration.listenPort) else { return nil }

        self.configuration = configuration
        self.failureHandler = failureHandler
        self.exhaustionCallback = onUpstreamExhaustion

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

    private func removeInboundConnection(with identifier: ObjectIdentifier) {
        inboundConnections.removeValue(forKey: identifier)
    }

    // Called from `receive` (DNS proxy queue) every time all four upstreams fail
    // to answer a single query.  Maintains a sliding window of failure timestamps
    // and, once the threshold is reached, invokes the exhaustion callback exactly
    // once per DNSProxy instance.  The callback owner (PacketTunnelProvider) is
    // expected to call cancelTunnelWithError so NE respawns the extension with a
    // fresh kernel NECP context.
    private func noteUpstreamExhaustion() {
        let now = Date()
        exhaustionTimestamps.append(now)
        let cutoff = now.addingTimeInterval(-Self.exhaustionWindowDuration)
        exhaustionTimestamps.removeAll { $0 < cutoff }

        guard !hasFiredExhaustionCallback,
              exhaustionTimestamps.count >= Self.exhaustionWindowThreshold else {
            return
        }

        hasFiredExhaustionCallback = true
        logger.fault("Upstream DoT exhaustion threshold reached (\(self.exhaustionTimestamps.count) full-fanout failures within \(Int(Self.exhaustionWindowDuration))s) — requesting tunnel respawn to recover NECP flow table")
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

            self.resolver.resolve(query: data) { [weak self, weak connection] response in
                guard let self else { return }
                guard let connection else {
                    return
                }

                let finish: () -> Void = {
                    connection.cancel()
                    self.removeInboundConnection(with: identifier)
                }

                guard let response else {
                    self.logger.error("Failed to obtain DNS response from all DoT upstreams")
                    self.noteUpstreamExhaustion()
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

    private let upstreams: [UpstreamConnection]
    private let callbackQueue: DispatchQueue
    private let logger: Logger

    init(configuration: DNSProxy.Configuration, callbackQueue: DispatchQueue, logger: Logger) {
        self.callbackQueue = callbackQueue
        self.logger = logger

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

    func resolve(query: Data, completion: @escaping (Data?) -> Void) {
        attemptResolve(query: query, upstreamIndex: 0, completion: completion)
    }

    func warmUp() {
        upstreams.forEach { $0.warmUp() }
    }

    func invalidate() {
        upstreams.forEach { $0.invalidate() }
    }

    private func attemptResolve(query: Data, upstreamIndex: Int, completion: @escaping (Data?) -> Void) {
        guard upstreamIndex < upstreams.count else {
            logger.error("Exhausted all upstream DoT addresses without a response")
            completion(nil)
            return
        }

        let upstream = upstreams[upstreamIndex]
        upstream.send(query: query) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                completion(response)
            case .failure(let error):
                self.logger.error("DoT upstream \(upstream.address, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self.logger.debug("Attempting next DoT upstream after failure at index \(upstreamIndex)")
                self.attemptResolve(query: query, upstreamIndex: upstreamIndex + 1, completion: completion)
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
    private var lastPathStatus: NWPath.Status?
    private var lastUsedTime: Date?
    private var connectionCreatedAt: Date?
    private let staleConnectionThreshold: TimeInterval = 5 * 60   // 5 minutes
    // Cellular NAT tables typically time out TCP sessions after ~10 minutes. Recycle
    // connections before that happens so we never send a query into a zombie TCP session
    // that the server has already torn down on its side.
    private let maxConnectionLifetime: TimeInterval = 8 * 60      // 8 minutes

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
    private static let globalENOMEMStateQueue = DispatchQueue(label: "com.glacier.PacketTunnel.enomem-state")
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
        queue = DispatchQueue(label: "com.glacier.PacketTunnel.dot-upstream.\(address)")
    }

    func warmUp() {
        queue.async { [weak self] in
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
            logger.info("DoT connection to \(self.address, privacy: .private) idle for >\(Int(self.staleConnectionThreshold))s — resetting preemptively to avoid zombie")
            resetConnection()
        }

        if isReady, let createdAt = connectionCreatedAt,
           Date().timeIntervalSince(createdAt) > maxConnectionLifetime {
            logger.info("DoT connection to \(self.address, privacy: .private) age >\(Int(self.maxConnectionLifetime))s — recycling proactively to prevent cellular NAT timeout")
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
            logger.notice("DoT connection waiting for upstream \(self.address, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
                finish(request: request, with: .failure(.connectionFailed("Connection temporarily unavailable")))
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
                reconnectAttempt = 0
                scheduleReconnect(after: 0)
            }
        case .requiresConnection, .unsatisfied:
            logger.notice("Path unavailable for DoT upstream \(self.address, privacy: .public) (status: \(String(describing: status)))")
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
                finish(request: request, with: .failure(.connectionFailed("Network path unavailable")))
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

        logger.info("DoT connection to \(self.address, privacy: .private) reached max lifetime (\(Int(self.maxConnectionLifetime))s) — recycling proactively to prevent cellular NAT timeout")
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
                    self.logger.error("Error receiving DoT response length from \(self.address, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.handleFailure(.connectionFailed("Receive error"))
                    return
                }

                guard let data, data.count == 2 else {
                    if data == nil || data!.isEmpty {
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

    private func scheduleReconnect(after delay: TimeInterval? = nil) {
        reconnectWorkItem?.cancel()
        let reconnectDelay: TimeInterval
        if let delay {
            reconnectDelay = max(0, delay)
        } else {
            reconnectAttempt += 1
            reconnectDelay = min(pow(2.0, Double(max(reconnectAttempt - 1, 0))), 8)
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
    }
}

// MARK: - Resolver Error

private enum ResolverError: LocalizedError {
    case connectionFailed(String)
    case timeout
    case invalidResponse(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let description):
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
