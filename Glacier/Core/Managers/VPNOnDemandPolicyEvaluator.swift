//
//  VPNOnDemandPolicyEvaluator.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Network
import NetworkExtension

/**
 Answers one question: *should* the VPN tunnel be connected on the network this
 device is using right now?

 A disconnected tunnel is not automatically a failure. When an on-demand disconnect
 rule holds it down — a trusted Wi-Fi SSID, or Wi-Fi-only policy while on cellular —
 being down is the correct state, and alerting about it would be a false alarm.
 Tunnel status alone cannot tell the two apart, so the on-demand policy has to be
 evaluated against the live network.

 Every method biases toward silence: an undeterminable network path or an unreadable
 SSID reports `false`, because a missed alert is recoverable and a false one trains
 users to ignore the real thing.

 This logic was lifted out of `GlacierApplicationDelegate`'s `vpnHealth` background
 task so the background sweep and `VPNInterruptionMonitor` cannot drift apart. The
 network read has since been fixed — see `currentPrimaryInterface`.
 */
enum VPNOnDemandPolicyEvaluator {

    enum PrimaryInterface {
        case wifi, cellular, other, none
    }

    /// Calls `completion(true)` only when the tunnel should affirmatively be up on
    /// the current network. Anything unknown resolves to `false`.
    static func shouldBeConnectedOnCurrentNetwork(
        _ managers: [NETunnelProviderManager],
        completion: @escaping (Bool) -> Void
    ) {
        guard let manager = managers.first(where: { $0.isEnabled }) ?? managers.first else {
            completion(false)
            return
        }
        shouldBeConnectedOnCurrentNetwork(manager, completion: completion)
    }

    static func shouldBeConnectedOnCurrentNetwork(
        _ manager: NETunnelProviderManager,
        completion: @escaping (Bool) -> Void
    ) {
        let option = ActivateOnDemandOption(from: manager)

        currentPrimaryInterface { interface in
            // No usable network path: the tunnel can't be up regardless, so there's
            // nothing to alert about.
            guard interface != .none else {
                completion(false)
                return
            }
            evaluate(option, on: interface, completion: completion)
        }
    }

    private static func evaluate(
        _ option: ActivateOnDemandOption,
        on interface: PrimaryInterface,
        completion: @escaping (Bool) -> Void
    ) {
        switch option {
        case .off, .anyInterface(.anySSID):
            // No SSID-scoped policy — the tunnel should be up wherever there's a network.
            completion(true)

        case .nonWiFiInterfaceOnly:
            completion(interface == .cellular)

        case .wiFiInterfaceOnly(let ssidOption):
            switch interface {
            case .wifi:
                resolveWiFiConnectDecision(ssidOption, completion: completion)
            default:
                // Cellular (or anything non-Wi-Fi) carries a disconnect rule here.
                completion(false)
            }

        case .anyInterface(let ssidOption):
            switch interface {
            case .cellular:
                completion(true)   // connect rule on the non-Wi-Fi interface
            case .wifi:
                resolveWiFiConnectDecision(ssidOption, completion: completion)
            default:
                completion(false)
            }
        }
    }

    /// Resolves the connect/disconnect decision for the current Wi-Fi network
    /// against an SSID-scoped on-demand option. SSID-specific options require the
    /// current SSID; when it can't be read we report `false` (stay silent).
    static func resolveWiFiConnectDecision(
        _ ssidOption: ActivateOnDemandSSIDOption,
        completion: @escaping (Bool) -> Void
    ) {
        switch ssidOption {
        case .anySSID:
            completion(true)
        case .onlySpecificSSIDs(let ssids):
            fetchCurrentSSID { ssid in
                guard let ssid else { completion(false); return }
                completion(ssids.contains(ssid))
            }
        case .exceptSpecificSSIDs(let ssids):
            fetchCurrentSSID { ssid in
                guard let ssid else { completion(false); return }
                completion(!ssids.contains(ssid))
            }
        }
    }

    static func fetchCurrentSSID(_ completion: @escaping (String?) -> Void) {
        NEHotspotNetwork.fetchCurrent { network in
            if let ssid = network?.ssid {
                completion(ssid)
            } else {
                // Fall back to the Captive Network copy used elsewhere in the app.
                completion(TunnelsManager.retrieveCurrentSSID())
            }
        }
    }

    /// How long to wait for a usable network path before giving up and reporting
    /// `.none`. The physical interface is not the one that just went away, so it
    /// should report satisfied almost immediately; this only has to outlast the churn
    /// of the tunnel interface being torn down.
    private static let pathSettleTimeout: TimeInterval = 3

    /// Waits for a real path update rather than sampling `currentPath` immediately.
    ///
    /// This used to `start()` a monitor and read `currentPath` microseconds later,
    /// treating anything not yet `.satisfied` as "no network". That is wrong in the
    /// only situation this is ever called from: the evaluator runs *because* a tunnel
    /// just dropped, which is precisely when the path is still settling. On device the
    /// read came back `.none`, the caller stayed silent, and iOS re-established the
    /// tunnel through its own on-demand rules five seconds later — our evaluator and
    /// iOS reaching opposite conclusions about the same network.
    ///
    /// Still biased toward silence: no satisfied path inside the timeout reports
    /// `.none`, which callers treat as "stay quiet".
    static func currentPrimaryInterface(completion: @escaping (PrimaryInterface) -> Void) {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.theglacierapp.vpn.policy-path")
        var hasFinished = false

        // All access to hasFinished is on `queue`, which is also the monitor's queue.
        let finish: (PrimaryInterface) -> Void = { result in
            queue.async {
                guard !hasFinished else { return }
                hasFinished = true
                monitor.cancel()
                DispatchQueue.main.async { completion(result) }
            }
        }

        monitor.pathUpdateHandler = { path in
            // Ignore unsatisfied updates and keep waiting; the timeout below is what
            // ends a genuine outage.
            guard path.status == .satisfied else { return }
            if path.usesInterfaceType(.wifi) {
                finish(.wifi)
            } else if path.usesInterfaceType(.cellular) {
                finish(.cellular)
            } else {
                finish(.other)
            }
        }

        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + pathSettleTimeout) { finish(.none) }
    }
}
