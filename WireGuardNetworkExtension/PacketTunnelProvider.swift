//
//  PacketTunnelProvider.swift
//  WireGuardNetworkExtension
//
//  Created by andyfriedman on 8/26/24.
//  Copyright © 2024 Glacier. All rights reserved.
//

import Network
import NetworkExtension
import WireGuardKit
import os

class PacketTunnelProvider: NEPacketTunnelProvider {

    private enum Constants {
        static let localDnsPort: UInt16 = 53
        static let pathSatisfiedDebounceInterval: TimeInterval = 2
        static let unsatisfiedTeardownDelay: TimeInterval = 3
        // Minimum gap between proxy restarts triggered by path-satisfied events.
        // On cellular, the device IP can churn every 3-5 s (tower handoffs / IP
        // reassignment), generating a path-satisfied event each time.  Without a
        // minimum interval, every event fires stopDnsProxy() + four new DoT
        // connections, saturating the NECP flow table with zombie entries.
        // 30 s is long enough for the kernel to reclaim cancelled flows while still
        // ensuring NAT64 addresses are refreshed promptly after a real handoff.
        // Per-connection NWPath monitors in UpstreamConnection handle reconnection
        // within the quiet window, so DNS never stalls between proxy restarts.
        static let minPathDrivenRestartInterval: TimeInterval = 30.0
        // Minimum gap between proxy restarts triggered by device wake.
        // Wake events are produced by IKEv2 keep-alives every ~60-90 s on
        // stationary WiFi — they do not correspond to network changes and must
        // not force a proxy restart on every fire, because each restart creates
        // four new DoT connections that the kernel NECP flow table can't reclaim
        // before the next wake arrives.  NWPathMonitor independently delivers a
        // path-satisfied event whenever anything material changed during sleep,
        // and that path-driven restart uses minPathDrivenRestartInterval (30 s).
        // Wake-driven restart is a safety net only, so it can run on a much
        // longer cadence.
        static let minWakeDrivenRestartInterval: TimeInterval = 300.0
        // Floor between restarts driven by sustained total DNS failure.  Deliberately
        // far shorter than the wake and path limiters, because unlike those this one
        // only fires on evidence that the current configuration is *not working* — the
        // limiters above exist to damp churn while things are fine.  Still a floor, so
        // a device with genuinely no network cannot restart the proxy in a tight loop.
        static let minFailureDrivenRestartInterval: TimeInterval = 60.0

        // MARK: - Tunnel health sampling (diagnostic only)
        //
        // How often to read WireGuard's own view of the tunnel. A local UAPI read, no
        // packets and no radio, so this can be frequent.
        static let healthSampleInterval: TimeInterval = 60.0
        // How often to persist a sample even when everything looks normal. Establishes
        // the baseline the eventual recovery thresholds have to be set against, without
        // spending the log budget the per-episode DNS change just reclaimed.
        static let healthHeartbeatInterval: TimeInterval = 1800.0
        // WireGuard rekeys roughly every 120 s while there is traffic. Past this a
        // handshake is old enough to be worth noting — but only alongside the rx/tx
        // picture, since an idle tunnel legitimately has an ancient handshake.
        //
        // Raised from 180 s after 13.5 h of overnight sampling on 2026-09-06/07: a
        // perfectly healthy idle tunnel was measured at 184 s, and 18 of 19 samples sat
        // at or below 121 s. 180 s was inside the healthy distribution with no margin.
        // 300 s is 2.5x the rekey interval and clear of everything observed.
        static let staleHandshakeThreshold: TimeInterval = 300.0
        // An idle tunnel still emits keepalives.  The false positive that prompted all
        // of the tuning below reported `tx +64B` — a single packet — which satisfied a
        // naive `txDelta > 0`.  Require enough traffic to mean somebody is actually
        // trying to use the tunnel.
        static let minSuspectTxBytes: UInt64 = 4096
        // Deltas are only interpretable when the timer ran roughly on schedule.  iOS
        // suspends a DispatchSourceTimer through deep sleep: overnight, intervals ranged
        // 60–1791 s against a 60 s schedule, with a median around 640 s.  A half-hour
        // "delta" says nothing about the last minute, and nobody is using the network
        // then anyway.  Such samples are still logged, just not judged.
        static let maxSuspectSampleInterval: TimeInterval = 180.0
        // Consecutive qualifying samples before reporting.  The observed false positive
        // cleared on the very next sample.
        static let suspectSampleThreshold = 2
    }

    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { logLevel, message in
        }
    }()

    static let log = Logger(subsystem: "com.theglacierapp.Glacier", category: "packet-tunnel")

    private let dnsConfigurator = PacketTunnelDNSConfigurator()
    private var dnsProxyConfiguration: PacketTunnelDNSConfigurator.ProxyConfiguration?
    private var dnsProxyListenEndpoint: (address: String, port: UInt16)?
    private var dnsProxy: DNSProxy?
    private var pathMonitor: NWPathMonitor?
    private var lastObservedPathDescription: String?
    private var lastObservedPathStatus: Network.NWPath.Status?
    private let pathMonitorQueue = DispatchQueue(label: "com.theglacierapp.PacketTunnel.path-monitor")
    private var pendingSatisfiedUpdate: DispatchWorkItem?
    private var pendingUnsatisfiedTeardown: DispatchWorkItem?

    // Tunnel health sampling. All touched only on pathMonitorQueue.
    private var healthSampleTimer: DispatchSourceTimer?
    private var lastHealthSample: (rx: UInt64, tx: UInt64, at: Date)?
    private var lastHealthHeartbeat: Date?
    private var consecutiveSuspectSamples = 0
    private var isTunnelSuspect = false
    private var lastAppliedNetworkSettings: NETunnelNetworkSettings?
    private var isReapplyingNetworkSettings = false
    /// Timestamp of the most recent proxy restart driven by a path-satisfied event or a
    /// device wake callback.  Used by scheduleSatisfiedActions and wake() to enforce
    /// minPathDrivenRestartInterval.
    /// Reset to .distantPast by scheduleUnsatisfiedTeardown (not stopDnsProxy) so
    /// the proxy can restart immediately when the network returns after a genuine
    /// outage without bypassing the rate limit during normal path-churn / wake restarts.
    private var lastPathDrivenRestartDate: Date = .distantPast
    private var lastFailureDrivenRestartDate: Date = .distantPast
    private var lastLoggedUpstreamSet: [String]?
    /// Wakes the rate limit turned away since the last restart we actually performed.
    /// Reported on that next restart rather than one persisted line per suppressed wake:
    /// at ~54/hour asleep and ~150/hour in use, that line was 69-72% of everything this
    /// extension wrote to disk, and each one recorded a decision *not* to act.  Mutated
    /// only on `pathMonitorQueue`.
    private var suppressedWakeCount = 0

    override init() {
        self.log = Self.log
        log.log(level: .debug, "First light")
        super.init()
    }
        
    let log: Logger

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let errorNotifier = ErrorNotifier(activationAttemptId: options?["activationAttemptId"] as? String)
        let optionsDescription = options.map { String(describing: $0) } ?? "nil"
        log.notice("Starting tunnel with options: \(optionsDescription, privacy: .public)")

        startNetworkPathMonitor()

        dnsConfigurator.prepareDefaultConfigurationIfNeeded()
        dnsProxyConfiguration = nil
        dnsProxyListenEndpoint = nil
        stopDnsProxy()

        guard
            let tunnelProviderProtocol = self.protocolConfiguration as? NETunnelProviderProtocol,
            let tunnelConfiguration = tunnelProviderProtocol.asTunnelConfiguration()
        else {
            errorNotifier.notify(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            return
        }

        adapter.start(tunnelConfiguration: tunnelConfiguration) { adapterError in
            guard adapterError == nil else {
                switch adapterError {
                case .cannotLocateTunnelFileDescriptor:
                    // ErrorNotifier only writes its file for app-initiated starts (it needs an
                    // activationAttemptId, which on-demand starts don't carry), so without this
                    // line an on-demand start failure leaves no record anywhere.
                    self.log.log(level: .error, "Starting tunnel failed: could not determine file descriptor")
                    errorNotifier.notify(PacketTunnelProviderError.couldNotDetermineFileDescriptor)
                    completionHandler(PacketTunnelProviderError.couldNotDetermineFileDescriptor)

                case .dnsResolution(let dnsErrors):
                    let hostnamesWithDnsResolutionFailure = dnsErrors.map { $0.address }
                        .joined(separator: ", ")
                    self.log.log(level: .error, "Starting tunnel failed: DNS resolution failed for \(hostnamesWithDnsResolutionFailure, privacy: .public)")
                    errorNotifier.notify(PacketTunnelProviderError.dnsResolutionFailure)
                    completionHandler(PacketTunnelProviderError.dnsResolutionFailure)

                case .setNetworkSettings(let error):
                    self.log.log(level: .error, "Starting tunnel failed with setTunnelNetworkSettings returning \(error.localizedDescription)")
                    errorNotifier.notify(PacketTunnelProviderError.couldNotSetNetworkSettings)
                    completionHandler(PacketTunnelProviderError.couldNotSetNetworkSettings)

                case .startWireGuardBackend(let errorCode):
                    self.log.log(level: .error, "Starting tunnel failed with wgTurnOn returning \(errorCode)")
                    errorNotifier.notify(PacketTunnelProviderError.couldNotStartBackend)
                    completionHandler(PacketTunnelProviderError.couldNotStartBackend)

                case .invalidState:
                    // Must never happen
                    fatalError()
                case .none:
                    self.log.log(level: .info, "No error")
                }
                return
            }

            self.log.log(level: .info, "Tunnel interface is \(self.adapter.interfaceName ?? "unknown")")

            // Protection is back. Cancel a "protection is off" banner armed by a
            // previous stop before it can be delivered — the common case is on-demand
            // re-arming the tunnel seconds after a transient drop, which the user
            // should never hear about. Only on success: a failed start leaves the
            // armed banner in place, because protection really is still off.
            VPNProtectionAlert.resolve(reason: "tunnel started", logger: self.log)

            self.startTunnelHealthSampling()

            completionHandler(nil)
        }
    }
    
    override func setTunnelNetworkSettings(_ networkSettings: NETunnelNetworkSettings?, completionHandler: ((Error?) -> Void)?) {
        
        guard let networkSettings else {
            log.notice("Clearing tunnel network settings")
            dnsProxyConfiguration = nil
            dnsProxyListenEndpoint = nil
            stopDnsProxy()
            lastAppliedNetworkSettings = nil
            super.setTunnelNetworkSettings(nil, completionHandler: completionHandler)
            return
        }

        applyDnsConfiguration(to: networkSettings)

        lastAppliedNetworkSettings = networkSettings.copy() as? NETunnelNetworkSettings

        let ipv4Description = String(describing: (networkSettings as? NEPacketTunnelNetworkSettings)?.ipv4Settings?.addresses ?? [])
        let dnsServersDescription = String(describing: networkSettings.dnsSettings?.servers ?? [])
        log.debug("Applying tunnel network settings: IPv4 addresses=\(ipv4Description, privacy: .public), DNS servers=\(dnsServersDescription, privacy: .public)")

        super.setTunnelNetworkSettings(networkSettings) { [weak self] error in
            guard let self else {
                completionHandler?(error)
                return
            }

            if error == nil {
                self.log.notice("Tunnel network settings applied — scheduling settings-driven DNS proxy restart check")
                // Dispatch to pathMonitorQueue so this call is serialized with any
                // simultaneous path-monitor-driven restarts (which also run on that queue).
                self.pathMonitorQueue.async { [weak self] in
                    self?.restartDnsProxyIfNeeded()
                }
            } else {
                let message = error?.localizedDescription ?? "unknown"
                self.log.error("Failed to apply tunnel network settings: \(message, privacy: .public)")
                self.pathMonitorQueue.async { [weak self] in
                    self?.stopDnsProxy()
                }
            }

            completionHandler?(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // Add code here to start the process of stopping the tunnel.
        log.notice("Stopping tunnel, reason=\(reason.rawValue)")

        reportProtectionLoss(reason: reason)

        stopTunnelHealthSampling()

        stopDnsProxy()

        stopNetworkPathMonitor()

        adapter.stop { error in
            ErrorNotifier.removeLastErrorFile()

            if let error = error {
                self.log.log(level: .error, "Failed to stop WireGuard adapter: \(error.localizedDescription)")
            }
            completionHandler()
        }
    }
    
    /// Tells the user their VPN protection stopped when they didn't ask for it (issue #204).
    ///
    /// This runs in the extension because it is the only process guaranteed to be
    /// alive when the tunnel goes down — the containing app is normally suspended or
    /// terminated, which is precisely why the reported `.appUpdate` teardown produced
    /// no alert. It is also the only place the *reason* is available, which is what
    /// keeps a deliberate disconnect from being reported as a failure.
    ///
    /// The banner is armed rather than posted: `startTunnel` cancels it if the tunnel
    /// comes back inside the confirmation window, so on-demand re-arming after a
    /// transient drop stays silent. See `VPNProtectionAlert` for the full rationale.
    private func reportProtectionLoss(reason: NEProviderStopReason) {
        switch VPNProtectionAlert.disposition(for: reason) {
        case .deliberate:
            VPNProtectionAlert.resolve(reason: "deliberate stop (\(reason.rawValue))", logger: log)

        case .transient:
            // Expected or ambiguous. Stay silent here and leave the call to the app,
            // which can weigh the on-demand policy against the live network before
            // deciding — something this process can't do reliably during teardown.
            log.notice("[VPNAlert] stop reason \(reason.rawValue) treated as transient — no alert armed")

        case .failure(let kind):
            VPNProtectionAlert.arm(kind, delay: VPNProtectionAlert.confirmationDelay, logger: log)
        }
    }

    // MARK: - Tunnel health sampling
    //
    // Diagnostic only.  Nothing acts on these numbers yet, deliberately: the thresholds
    // for acting have to be set from observation, and there is currently nothing to
    // observe because nothing has ever recorded them.
    //
    // The 2026-09-06 outage is why this exists.  A Wi-Fi to cellular handoff left the
    // tunnel carrying no user traffic for two and a half hours, and every signal
    // available read healthy: NEVPNStatus stayed `connected`, the DNS proxy logged no
    // errors, and DNS resolved perfectly throughout — because the proxy reaches its
    // upstreams over the physical interface, bypassing the tunnel entirely.  The one
    // process able to see the truth, this one, never looked.  Afterwards the archive
    // could not answer "was the tunnel actually wedged?" because the number that would
    // have said so was never written down.
    //
    // Three values together are what separate a wedged tunnel from an idle one.
    // WireGuard only rekeys when there is traffic, so a stale handshake alone means
    // nothing.  The signature is tx climbing while rx stays flat *and* the handshake
    // ageing past the rekey window.  Deltas, not absolutes — that distinction is
    // exactly what an active reachability probe cannot make.

    private func startTunnelHealthSampling() {
        pathMonitorQueue.async { [weak self] in
            guard let self, self.healthSampleTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.pathMonitorQueue)
            timer.schedule(deadline: .now() + Constants.healthSampleInterval,
                           repeating: Constants.healthSampleInterval)
            timer.setEventHandler { [weak self] in
                self?.sampleTunnelHealth()
            }
            self.healthSampleTimer = timer
            timer.resume()
        }
    }

    private func stopTunnelHealthSampling() {
        pathMonitorQueue.async { [weak self] in
            guard let self else { return }
            self.healthSampleTimer?.cancel()
            self.healthSampleTimer = nil
            self.lastHealthSample = nil
            self.lastHealthHeartbeat = nil
            self.consecutiveSuspectSamples = 0
            self.isTunnelSuspect = false
        }
    }

    private func sampleTunnelHealth() {
        adapter.getRuntimeConfiguration { [weak self] settings in
            guard let self, let settings else { return }
            self.pathMonitorQueue.async {
                self.recordTunnelHealth(Self.parseRuntimeCounters(settings))
            }
        }
    }

    /// Pulls the three counters out of WireGuard's UAPI dump without going through the
    /// full TunnelConfiguration parser — that lives in the app target and throws, and
    /// neither is worth pulling in for three integers.  rx/tx are summed across peers;
    /// the handshake is the most recent across peers.
    private static func parseRuntimeCounters(_ uapi: String) -> (rx: UInt64, tx: UInt64, lastHandshake: Date?) {
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var newestHandshakeSec: UInt64 = 0

        for line in uapi.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = UInt64(parts[1]) else { continue }
            switch parts[0] {
            case "rx_bytes": rx &+= value
            case "tx_bytes": tx &+= value
            case "last_handshake_time_sec": newestHandshakeSec = max(newestHandshakeSec, value)
            default: break
            }
        }

        // A peer that has never completed a handshake reports 0, which is not a date.
        let handshake = newestHandshakeSec == 0
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(newestHandshakeSec))
        return (rx, tx, handshake)
    }

    private func recordTunnelHealth(_ sample: (rx: UInt64, tx: UInt64, lastHandshake: Date?)) {
        let now = Date()
        defer { lastHealthSample = (sample.rx, sample.tx, now) }

        guard let previous = lastHealthSample else { return }  // need two points for a delta

        // Counters are monotonic in practice, but a backend restart would reset them;
        // subtracting saturatingly keeps a reset from reading as enormous throughput.
        let rxDelta = sample.rx >= previous.rx ? sample.rx - previous.rx : 0
        let txDelta = sample.tx >= previous.tx ? sample.tx - previous.tx : 0
        let handshakeAge = sample.lastHandshake.map { now.timeIntervalSince($0) }

        let interval = now.timeIntervalSince(previous.at)
        let age = handshakeAge.map { String(Int($0)) } ?? "never"

        // Sending real traffic, nothing coming back, and rekey not completing either —
        // judged only on a sample the timer actually delivered on schedule.
        let judgeable = interval <= Constants.maxSuspectSampleInterval
        let qualifies = judgeable
            && txDelta >= Constants.minSuspectTxBytes
            && rxDelta == 0
            && (handshakeAge ?? .greatestFiniteMagnitude) > Constants.staleHandshakeThreshold

        if qualifies {
            consecutiveSuspectSamples += 1
        } else if judgeable {
            // Only a sample we were willing to judge may clear the streak. A
            // sleep-stretched one carries no information either way.
            consecutiveSuspectSamples = 0
        }
        let suspect = consecutiveSuspectSamples >= Constants.suspectSampleThreshold

        if suspect != isTunnelSuspect {
            isTunnelSuspect = suspect
            if suspect {
                log.notice("[TunnelHealth] SUSPECT — tx +\(txDelta)B, rx +0B over \(Int(interval))s, \(self.consecutiveSuspectSamples) consecutive samples, last handshake \(age, privacy: .public)s ago (no action taken)")
            } else {
                log.notice("[TunnelHealth] recovered — tx +\(txDelta)B, rx +\(rxDelta)B over \(Int(interval))s, last handshake \(age, privacy: .public)s ago")
            }
            lastHealthHeartbeat = now
            return
        }

        // Every line carries the interval: without it the deltas cannot be read, which
        // was the flaw in the first version of the SUSPECT line.
        let sinceHeartbeat = lastHealthHeartbeat.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if sinceHeartbeat >= Constants.healthHeartbeatInterval {
            lastHealthHeartbeat = now
            log.notice("[TunnelHealth] tx +\(txDelta)B, rx +\(rxDelta)B over \(Int(interval))s, last handshake \(age, privacy: .public)s ago")
        } else {
            log.debug("[TunnelHealth] tx +\(txDelta)B, rx +\(rxDelta)B over \(Int(interval))s, last handshake \(age, privacy: .public)s ago")
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Add code here to handle the message.
        guard let completionHandler = completionHandler else { return }

        if messageData.count == 1 && messageData[0] == 0 {
            adapter.getRuntimeConfiguration { settings in
                var data: Data?
                if let settings = settings {
                    data = settings.data(using: .utf8)!
                }
                completionHandler(data)
            }
        } else {
            completionHandler(nil)
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }
    
    override func wake() {
        // After sleep the device may have switched interfaces, but NWPathMonitor
        // independently delivers path-satisfied for real changes — so wake() only
        // exists as a safety net.  Use minWakeDrivenRestartInterval (5 min) rather
        // than the 30 s path-driven interval, because wakes come from IKEv2
        // keep-alives every 60-90 s on stationary WiFi.  At 30 s every keep-alive
        // wake passes the rate-limit and burns 4 fresh DoT connections that the
        // kernel can't reclaim before the next wake arrives, eventually saturating
        // the NECP flow table (ENOMEM / error 12).
        pathMonitorQueue.async { [weak self] in
            guard let self else { return }
            let timeSinceLast = Date().timeIntervalSince(self.lastPathDrivenRestartDate)
            guard timeSinceLast >= Constants.minWakeDrivenRestartInterval else {
                self.suppressedWakeCount += 1
                self.log.debug("Suppressing wake-driven DNS proxy restart — last restart was \(Int(timeSinceLast))s ago (min wake interval \(Int(Constants.minWakeDrivenRestartInterval))s)")
                return
            }
            let suppressed = self.suppressedWakeCount
            self.suppressedWakeCount = 0
            if suppressed > 0 {
                self.log.notice("Device waking up — refreshing DNS proxy connections (\(suppressed) wakes suppressed since the last restart)")
            } else {
                self.log.notice("Device waking up — refreshing DNS proxy connections")
            }
            self.lastPathDrivenRestartDate = Date()
            self.restartDnsProxyIfNeeded(forceRestart: true)
        }
    }

    private func restartDnsProxyIfNeeded(forceRestart: Bool = false) {
        // Quick pre-flight: bail out before the potentially-expensive cache-clear and
        // re-resolve if the fundamental prerequisites are already missing.
        guard dnsProxyConfiguration != nil else {
            log.debug("DNS proxy not started – missing upstream configuration")
            stopDnsProxy()
            return
        }

        guard let listenEndpoint = dnsProxyListenEndpoint else {
            log.debug("DNS proxy not started – missing listen endpoint")
            stopDnsProxy()
            return
        }

        if forceRestart {
            // Clear the in-memory DNS resolution cache so that getaddrinfo() is re-run
            // against the current network interface (e.g. to obtain NAT64-synthesized
            // IPv6 addresses on cellular instead of cached IPv4 addresses from WiFi).
            // Then re-derive dnsProxyConfiguration so the fresh IPs propagate into
            // the DNSProxy.Configuration below.
            dnsConfigurator.clearResolvedServerCache()
            if let currentSettings = lastAppliedNetworkSettings?.copy() as? NETunnelNetworkSettings {
                applyDnsConfiguration(to: currentSettings)
            }
        }

        // Re-read proxyConfiguration after a potential refresh above.
        guard let proxyConfiguration = dnsProxyConfiguration else {
            log.debug("DNS proxy not started – missing upstream configuration after refresh")
            stopDnsProxy()
            return
        }

        let refreshedConfiguration = DNSProxy.Configuration(listenAddress: listenEndpoint.address,
                                                            listenPort: listenEndpoint.port,
                                                            upstreamServerName: proxyConfiguration.serverName,
                                                            upstreamPort: proxyConfiguration.port,
                                                            upstreamAddresses: proxyConfiguration.resolvedAddresses)

        logUpstreamSetIfChanged(refreshedConfiguration.upstreamAddresses)

        // When forceRestart is false, skip the restart if configuration is unchanged.
        // When forceRestart is true (e.g. called after a network interface change or
        // device wake), always restart so upstream TLS connections are refreshed even
        // though the resolved IP list hasn't changed.  The 2-second debounce in
        // scheduleSatisfiedActions gives WireGuard time to complete its re-handshake on
        // the new interface before we create new DoT connections.
        if !forceRestart, let currentProxy = dnsProxy, currentProxy.currentConfiguration == refreshedConfiguration {
            log.notice("DNS proxy already running with current configuration — skipping settings-driven restart")
            return
        }

        stopDnsProxy()

        guard let proxy = DNSProxy(configuration: refreshedConfiguration,
                                   failureHandler: { [weak self] reason in
                                       self?.handleDnsProxyFailure(reason)
                                   },
                                   onUpstreamExhaustion: { [weak self] in
                                       self?.handleUpstreamExhaustion()
                                   },
                                   onSustainedFailure: { [weak self] in
                                       self?.handleSustainedDNSFailure()
                                   }) else {
            log.error("Failed to initialize DNS proxy")
            return
        }

        log.info("Starting DNS proxy listening on \(refreshedConfiguration.listenAddress, privacy: .private):\(refreshedConfiguration.listenPort) → \(refreshedConfiguration.upstreamServerName, privacy: .private):\(refreshedConfiguration.upstreamPort)")
        proxy.start()
        dnsProxy = proxy
    }

    private func stopDnsProxy() {
        if dnsProxy != nil {
            log.notice("Stopping DNS proxy")
        }
        dnsProxy?.stop()
        dnsProxy = nil
        // Do NOT reset lastPathDrivenRestartDate here.  stopDnsProxy() is called
        // from inside restartDnsProxyIfNeeded (which is called from
        // scheduleSatisfiedActions), so resetting here would undo the rate-limit
        // timestamp set just before the call, allowing rapid-fire restarts.
        // The reset is done only by scheduleUnsatisfiedTeardown, after a genuine
        // network outage, so the proxy can restart immediately when connectivity
        // is restored.
    }

    private func determineDnsListenAddress(from settings: NEPacketTunnelNetworkSettings) -> String? {
        return "127.0.0.1"
        // 127.0.0.1 is never captured by tunnel routing (loopback bypasses all VPN routes),
            // so DNS queries to this address reach the NWListener instead of being swallowed
            // by the WireGuard packetFlow.
            
        
        // Prefer IPv4 for the DNS proxy listen address because the proxy stack is
        // known-good on IPv4, while some deployments may not have a functional
        // IPv6 route or listener. Fall back to IPv6 only when no IPv4 address is
        // present to avoid selecting an unreachable endpoint that would break DNS
        // resolution entirely.
    }

    private func applyDnsConfiguration(to networkSettings: NETunnelNetworkSettings) {
        if let packetSettings = networkSettings as? NEPacketTunnelNetworkSettings {
            let localAddress = determineDnsListenAddress(from: packetSettings)
            let proxyConfiguration = dnsConfigurator.applyDnsSettings(to: packetSettings, localProxyAddress: localAddress)
            let usingProxy = localAddress != nil && proxyConfiguration != nil
            dnsProxyListenEndpoint = usingProxy ? localAddress.map { ($0, Constants.localDnsPort) } : nil
            dnsProxyConfiguration = usingProxy ? proxyConfiguration : nil

            if usingProxy, let localAddress {
                log.debug("Configured DNS proxy endpoint \(localAddress, privacy: .public):\(Constants.localDnsPort)")
            } else if localAddress != nil {
                log.notice("DNS proxy not started – secure DNS configuration unavailable or disabled")
            } else {
                log.notice("DNS proxy disabled – using direct DoT configuration")
            }
        } else {
            dnsConfigurator.applyDnsSettings(to: networkSettings)
            dnsProxyConfiguration = nil
            dnsProxyListenEndpoint = nil
            log.notice("Applied DNS settings to non-packet tunnel configuration")
        }
    }

    private func startNetworkPathMonitor() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkPathUpdate(path)
        }

        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
        log.debug("Started network path monitor for DNS proxy resilience")
    }

    private func stopNetworkPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastObservedPathDescription = nil
        lastObservedPathStatus = nil
        pendingSatisfiedUpdate?.cancel()
        pendingUnsatisfiedTeardown?.cancel()
    }

    private func handleNetworkPathUpdate(_ path: Network.NWPath) {
        let description = describeActive(path: path)
        let status = path.status

        guard description != lastObservedPathDescription || status != lastObservedPathStatus else { return }
        lastObservedPathDescription = description
        lastObservedPathStatus = status

        pendingSatisfiedUpdate?.cancel()

        let statusDescription: String
        switch status {
        case .satisfied:
            statusDescription = "satisfied"
        case .unsatisfied:
            statusDescription = "unsatisfied"
        case .requiresConnection:
            statusDescription = "requires-connection"
        @unknown default:
            statusDescription = "unknown"
        }

        log.info("Network path updated (\(statusDescription)): \(description, privacy: .private)")

        switch status {
        case .satisfied:
            cancelPendingUnsatisfiedTeardown()
            scheduleSatisfiedActions(description: description)
        case .unsatisfied, .requiresConnection:
            scheduleUnsatisfiedTeardown(reason: statusDescription)
        @unknown default:
            break
        }
    }

    private func handleDnsProxyFailure(_ reason: String) {
        log.error("DNS proxy reported listener failure: \(reason, privacy: .public)")
        // Use forceRestart: true so the restart always proceeds even if dnsProxy is
        // still non-nil with an identical configuration.  Without forceRestart the
        // "already running with current configuration" early-return guard would
        // short-circuit here, leaving the failed proxy assigned to dnsProxy with no
        // further recovery attempt.
        //
        // Dispatch with a short delay so the OS has time to fully release the UDP
        // port before we attempt to bind a new NWListener on it.  Dispatch to
        // pathMonitorQueue so all dnsProxy mutations remain serialized.
        pathMonitorQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.restartDnsProxyIfNeeded(forceRestart: true)
        }
    }

    // DNSProxy fires this when all four DoT upstreams have failed to answer
    // multiple consecutive queries within a short window — the signature of a
    // saturated kernel NECP flow table.  Restarting the proxy from inside this
    // process cannot help (the kernel state is process-external); we have to ask
    // NE to respawn the extension entirely.  After respawn, the new process gets
    // a fresh start and — combined with the 5-min ENOMEM cooldown and the
    // wake-restart rate limit — should not re-enter the same trap.
    // Every upstream has been failing continuously for long enough, over enough
    // queries, that the resolved upstream set must be presumed unusable on whatever
    // interface the device is on now.  Rebuild the proxy with freshly resolved
    // addresses, bypassing the wake and path rate limiters.
    //
    // Deliberately much cheaper than handleUpstreamExhaustion() below: that tears down
    // the whole extension via cancelTunnelWithError to clear kernel state.  This only
    // restarts the DNS proxy, which is what a stale address set actually needs — and
    // forceRestart clears the resolution cache so getaddrinfo() re-runs against the
    // current interface (NAT64-synthesised IPv6 on cellular instead of cached IPv4
    // from Wi-Fi, which is precisely the 2026-09-08 failure).
    /// Records which upstreams the proxy is actually configured with, whenever that set
    /// changes.
    ///
    /// Pool composition previously had to be inferred from failure lines, which is a
    /// biased sample — only an upstream with a stale connection ever gets named — and that
    /// inference was wrong at least once, in the opposite direction. It also left the
    /// 2026-09-08 outage log saying "All 2 DoT upstreams failed" with no way to know which
    /// two, or when the set had shrunk to two.
    ///
    /// Logged on change rather than on every proxy start: restarts run around six an hour,
    /// so per-start logging would be ~150 repetitive lines a day, while per-change is a
    /// handful and captures exactly the transitions that matter.
    ///
    /// Addresses are `.public`, matching the twenty-odd other sites that already name
    /// them. They are Glacier's own resolvers, resolvable by anyone from the configured
    /// hostname, and say nothing about the user. Query contents are never logged anywhere
    /// in this extension — only byte counts.
    private func logUpstreamSetIfChanged(_ addresses: [String]) {
        guard lastLoggedUpstreamSet != addresses else { return }
        lastLoggedUpstreamSet = addresses

        let ipv6Count = addresses.filter { IPv6Address($0) != nil }.count
        let ipv4Count = addresses.filter { IPv4Address($0) != nil }.count
        let list = addresses.joined(separator: ", ")
        log.notice("DoT upstream set changed: \(list, privacy: .public) — \(ipv4Count) IPv4, \(ipv6Count) IPv6")
    }

    private func handleSustainedDNSFailure() {
        pathMonitorQueue.async { [weak self] in
            guard let self else { return }

            let timeSinceLast = Date().timeIntervalSince(self.lastFailureDrivenRestartDate)
            guard timeSinceLast >= Constants.minFailureDrivenRestartInterval else {
                self.log.notice("Suppressing failure-driven DNS proxy restart — last one was \(Int(timeSinceLast))s ago (min \(Int(Constants.minFailureDrivenRestartInterval))s)")
                return
            }
            self.lastFailureDrivenRestartDate = Date()

            self.log.notice("Sustained total DNS failure — forcing DNS proxy restart to re-resolve upstreams against the current interface")
            // Also stamp the path-driven clock: a restart genuinely happened, and the
            // path limiter should measure from it like any other.
            self.lastPathDrivenRestartDate = Date()
            self.restartDnsProxyIfNeeded(forceRestart: true)
        }
    }

    private func handleUpstreamExhaustion() {
        log.fault("Sustained DoT upstream exhaustion — calling cancelTunnelWithError to respawn extension with fresh NECP context")
        let error = NSError(domain: NEVPNErrorDomain,
                            code: NEVPNError.connectionFailed.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "DoT upstreams exhausted — extension requesting respawn"])
        cancelTunnelWithError(error)
    }

    private func describeActive(path: Network.NWPath) -> String {
        let activeInterfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
        let interfaces = (activeInterfaces.isEmpty ? path.availableInterfaces : activeInterfaces).map { interface -> String in
            let name = interface.name
            let typeDescription: String
            switch interface.type {
            case .wifi: typeDescription = "wifi"
            case .cellular: typeDescription = "cellular"
            case .wiredEthernet: typeDescription = "ethernet"
            case .loopback: typeDescription = "loopback"
            case .other: typeDescription = "other"
            @unknown default: typeDescription = "unknown"
            }

            return name.isEmpty ? typeDescription : "\(typeDescription):\(name)"
        }

        if interfaces.isEmpty {
            return "no-interfaces"
        }

        let interfaceDescription = interfaces.sorted().joined(separator: ",")
        return path.isExpensive ? "\(interfaceDescription);expensive" : interfaceDescription
    }

    private func scheduleSatisfiedActions(description: String) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.lastObservedPathStatus == .satisfied, self.lastObservedPathDescription == description else { return }

            // Rate-limit path-driven proxy restarts.  On cellular, the device IP can
            // churn every 3-5 s (tower handoff / short outage), emitting a
            // path-satisfied event each time.  Without a minimum interval the 2-second
            // debounce is not enough: every event fires stopDnsProxy() and creates
            // four new DoT connections, accumulating 200+ NECP zombie entries in
            // 10 minutes and causing ENOMEM on all subsequent connection attempts.
            //
            // When a restart IS suppressed, the existing UpstreamConnection instances
            // handle reconnection through their own NWPath monitors (handlePathUpdate),
            // so DNS continues to work between proxy-level restarts.
            let timeSinceLast = Date().timeIntervalSince(self.lastPathDrivenRestartDate)
            guard timeSinceLast >= Constants.minPathDrivenRestartInterval else {
                // .notice so this appears in device logs without a logging profile — essential
                // for diagnosing whether the rate limit is actually firing in production.
                self.log.notice("Suppressing path-driven DNS proxy restart — last restart was \(Int(timeSinceLast))s ago (min interval \(Int(Constants.minPathDrivenRestartInterval))s)")
                return
            }

            self.lastPathDrivenRestartDate = Date()
            // Force-restart so that upstream TLS connections are refreshed even when the
            // resolved DoT server IPs haven't changed.  This is the key fix for the
            // WiFi→cellular hang: without forceRestart, the proxy's configuration is
            // considered unchanged and the stale connections are kept, relying on
            // self-healing that can take 30-75 seconds under WireGuard re-handshake.
            self.restartDnsProxyIfNeeded(forceRestart: true)
            //self.reapplyNetworkSettings(reason: "network path changed: \(description)")
        }

        pendingSatisfiedUpdate = workItem
        pathMonitorQueue.asyncAfter(deadline: .now() + Constants.pathSatisfiedDebounceInterval, execute: workItem)
    }

    private func scheduleUnsatisfiedTeardown(reason: String) {
        pendingUnsatisfiedTeardown?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.lastObservedPathStatus != .satisfied else { return }

            self.log.notice("Stopping DNS proxy after prolonged \(reason, privacy: .public)")
            self.stopDnsProxy()
            // Reset the rate-limit timer here — after a genuine network outage the
            // proxy should be allowed to restart immediately when connectivity returns.
            // This is the only place the reset belongs; doing it in stopDnsProxy()
            // itself would undo the timestamp set in scheduleSatisfiedActions, making
            // the 30-second rate limit a no-op.
            self.lastPathDrivenRestartDate = .distantPast
        }

        pendingUnsatisfiedTeardown = workItem
        pathMonitorQueue.asyncAfter(deadline: .now() + Constants.unsatisfiedTeardownDelay, execute: workItem)
    }

    private func cancelPendingUnsatisfiedTeardown() {
        pendingUnsatisfiedTeardown?.cancel()
        pendingUnsatisfiedTeardown = nil
    }

    private func reapplyNetworkSettings(reason: String) {
        guard !isReapplyingNetworkSettings,
              let currentSettings = lastAppliedNetworkSettings?.copy() as? NETunnelNetworkSettings else {
            return
        }

        isReapplyingNetworkSettings = true
        log.notice("Reapplying tunnel network settings after \(reason, privacy: .public)")

        setTunnelNetworkSettings(currentSettings) { [weak self] error in
            guard let self else { return }
            self.isReapplyingNetworkSettings = false

            if let error {
                self.log.error("Failed to reapply tunnel network settings: \(error.localizedDescription, privacy: .public)")
            } else {
                self.log.notice("Successfully re-applied tunnel network settings")
            }
        }
    }
}

extension WireGuardLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose:
            return .debug
        case .error:
            return .error
        }
    }
}
