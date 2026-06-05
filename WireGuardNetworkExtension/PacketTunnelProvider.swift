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
    }

    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { logLevel, message in
            //wg_log(logLevel.osLogLevel, message: message)
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
    private var lastAppliedNetworkSettings: NETunnelNetworkSettings?
    private var isReapplyingNetworkSettings = false
    /// Timestamp of the most recent proxy restart driven by a path-satisfied event or a
    /// device wake callback.  Used by scheduleSatisfiedActions and wake() to enforce
    /// minPathDrivenRestartInterval.
    /// Reset to .distantPast by scheduleUnsatisfiedTeardown (not stopDnsProxy) so
    /// the proxy can restart immediately when the network returns after a genuine
    /// outage without bypassing the rate limit during normal path-churn / wake restarts.
    private var lastPathDrivenRestartDate: Date = .distantPast

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
                    //wg_log(.error, staticMessage: "Starting tunnel failed: could not determine file descriptor")
                    errorNotifier.notify(PacketTunnelProviderError.couldNotDetermineFileDescriptor)
                    completionHandler(PacketTunnelProviderError.couldNotDetermineFileDescriptor)

                case .dnsResolution(let dnsErrors):
                    let hostnamesWithDnsResolutionFailure = dnsErrors.map { $0.address }
                        .joined(separator: ", ")
                    //wg_log(.error, message: "DNS resolution failed for the following hostnames: \(hostnamesWithDnsResolutionFailure)")
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
        log.notice("Stopping tunnel")

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
                self.log.notice("Suppressing wake-driven DNS proxy restart — last restart was \(Int(timeSinceLast))s ago (min wake interval \(Int(Constants.minWakeDrivenRestartInterval))s)")
                return
            }
            self.log.notice("Device waking up — refreshing DNS proxy connections")
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
        /*if let address = settings.ipv4Settings?.addresses.first, !address.isEmpty {
            return address
        }

        if let address = settings.ipv6Settings?.addresses.first, !address.isEmpty {
            return address
        }

        log.error("Unable to determine tunnel interface address for DNS proxy")
        return nil*/
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
