//
//  VPNInterruptionMonitor.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import NetworkExtension
import UserNotifications

/**
 Watches the VPN connection for the whole life of the app process and alerts the
 user when protection stops without them asking for it (issue #204).

 This is the app-side half of the feature. `PacketTunnelProvider` handles the case
 where the app isn't running — it sees the stop reason and arms the banner directly.
 This monitor covers the complement: the app *is* alive, so it can weigh the
 on-demand policy against the live network before deciding, and it can cancel a
 banner the moment protection comes back.

 It deliberately observes `NEVPNStatusDidChange` itself rather than hanging off
 `TunnelsManager`. `TunnelsManager` is created lazily by whichever screen needs it
 first and its delegates are reassigned as view models come and go; the monitor has
 to be running before any of that and must not be affected by it.

 ## Telling a deliberate disconnect from a failure

 Every deliberate disconnect in Glacier disables on-demand *before* deactivating the
 tunnel — `HomeVM.toggleVPNConnection(false)` and `VPNSettingsVM` both do this so
 iOS cannot immediately re-arm what the user just switched off. That gives a
 reliable read at the moment of a drop:

 - on-demand **off** → the user (or the app on their behalf) asked for this. Silent.
 - on-demand **on**  → nobody asked; iOS stopped it. Now ask the policy evaluator
   whether the tunnel should be up on *this* network, which is what keeps
   trusted-network suppression from raising a false alarm.
 */
final class VPNInterruptionMonitor {

    static let shared = VPNInterruptionMonitor()

    /// Posted after an unexpected drop is confirmed, and again when protection
    /// returns, so the Home screen can refresh its warning without polling.
    static let protectionStateDidChange = Notification.Name("glacier.vpn.protectionStateDidChange")

    /// `true` once this process has seen the tunnel connected. Without it, the
    /// `.disconnected` that NE reports for an idle configuration at launch would
    /// read as a drop.
    private var hasObservedConnection = false

    private var isStarted = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Cache localized copy for the extension, which has no access to the app's
        // Localizable.strings and would otherwise always post English.
        cacheLocalizedCopy()
        registerNotificationCategory()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange(_:)),
            name: .NEVPNStatusDidChange,
            object: nil
        )

        // Seed `hasObservedConnection` so a drop that happens before the first status
        // callback still counts as a drop.
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let managers else { return }
            let connected = managers.contains {
                let status = $0.connection.status
                return status == .connected || status == .connecting || status == .reasserting
            }
            guard connected else { return }
            DispatchQueue.main.async {
                self?.hasObservedConnection = true
                VPNProtectionAlert.resolve(reason: "connected at launch", logger: Log.vpn)
            }
        }
    }

    /// Called when the app comes to the foreground. If protection is back, any banner
    /// or in-app warning left over from a drop is cleared; the user can see the state
    /// for themselves now.
    func reconcileOnForeground() {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            guard let managers, !managers.isEmpty else { return }
            let connected = managers.contains {
                let status = $0.connection.status
                return status == .connected || status == .connecting || status == .reasserting
            }
            guard connected else { return }
            VPNProtectionAlert.resolve(reason: "connected on foreground", logger: Log.vpn) {
                NotificationCenter.default.post(name: Self.protectionStateDidChange, object: nil)
            }
        }
    }

    // MARK: - Status handling

    @objc private func vpnStatusDidChange(_ notification: Notification) {
        guard let connection = notification.object as? NEVPNConnection else { return }
        let manager = (connection as? NETunnelProviderSession)?.manager as? NETunnelProviderManager
        let status = connection.status

        // NEVPNStatusDidChange is delivered on whatever queue NE happens to use, so
        // hop to main before touching `hasObservedConnection`.
        DispatchQueue.main.async { [weak self] in
            self?.apply(status: status, manager: manager)
        }
    }

    private func apply(status: NEVPNStatus, manager: NETunnelProviderManager?) {
        switch status {
        case .connected:
            hasObservedConnection = true
            // The bounce this window was covering is over. Retire it now rather than
            // letting it run out, so a genuine drop moments later isn't written off as
            // the tail of an app-initiated restart.
            VPNProtectionAlert.clearAppInitiatedStop()
            VPNProtectionAlert.resolve(reason: "status connected", logger: Log.vpn) {
                NotificationCenter.default.post(name: Self.protectionStateDidChange, object: nil)
            }

        case .disconnected:
            guard hasObservedConnection else { return }
            hasObservedConnection = false
            handleDisconnect(manager: manager)

        default:
            break
        }
    }

    private func handleDisconnect(manager: NETunnelProviderManager?) {
        guard let manager else { return }

        // Glacier itself stopped the tunnel — a config-change bounce, a region switch,
        // an on-demand rule edit. These leave on-demand enabled, so they look exactly
        // like a system kill to the test below; only the flag set at the call site
        // tells them apart. Stay silent and let the restart run.
        guard !VPNProtectionAlert.isWithinAppInitiatedStopWindow() else {
            Log.vpn.notice("[VPNAlert] disconnect inside an app-initiated stop window — staying silent")
            VPNProtectionAlert.resolve(reason: "app-initiated tunnel stop", logger: Log.vpn)
            return
        }

        // On-demand disabled means this disconnect was asked for — see the note on
        // the class. Nothing to warn about, and any banner the extension armed for an
        // overlapping reason should go away.
        guard manager.isOnDemandEnabled else {
            VPNProtectionAlert.resolve(reason: "on-demand disabled — deliberate disconnect", logger: Log.vpn)
            return
        }

        VPNOnDemandPolicyEvaluator.shouldBeConnectedOnCurrentNetwork(manager) { shouldConnect in
            guard shouldConnect else {
                Log.vpn.notice("[VPNAlert] tunnel down but on-demand policy does not require it on this network — staying silent")
                return
            }

            // If the extension already classified this stop as an app update, keep that
            // — its copy tells the user to finish updating first, which a generic
            // failure message would throw away.
            let kind = VPNProtectionAlert.pendingWarningKind() == .appUpdate ? VPNProtectionAlert.Kind.appUpdate : .failure

            // Arm rather than post. On-demand usually brings the tunnel straight back
            // after a handoff or a brief provider restart, and `startTunnel` cancels
            // the banner when it does.
            VPNProtectionAlert.arm(
                kind,
                delay: VPNProtectionAlert.confirmationDelay,
                logger: Log.vpn
            ) {
                NotificationCenter.default.post(name: Self.protectionStateDidChange, object: nil)
            }
        }
    }

    // MARK: - Notification presentation

    /// Registers the category carrying an explicit "Open Glacier" action, so the
    /// alert offers a visible way in rather than relying on the user knowing that
    /// tapping the banner opens the app.
    private func registerNotificationCategory() {
        let open = UNNotificationAction(
            identifier: VPNProtectionAlert.openActionId,
            title: NSLocalizedString("Open Glacier", comment: "VPN protection off notification action"),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: VPNProtectionAlert.categoryId,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )

        // Merge rather than replace: other Glacier categories may already be
        // registered, and setNotificationCategories overwrites the whole set.
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var categories = existing.filter { $0.identifier != VPNProtectionAlert.categoryId }
            categories.insert(category)
            center.setNotificationCategories(categories)
        }
    }

    private func cacheLocalizedCopy() {
        VPNProtectionAlert.cacheCopy(
            title: NSLocalizedString(
                "VPN protection is off",
                comment: "Title of the notification shown when the VPN stops unexpectedly"
            ),
            body: NSLocalizedString(
                "Glacier's VPN stopped for an app update. Finish updating, then reconnect.",
                comment: "Body of the notification shown when an app update stopped the VPN"
            ),
            for: .appUpdate
        )
        VPNProtectionAlert.cacheCopy(
            title: NSLocalizedString(
                "VPN protection is off",
                comment: "Title of the notification shown when the VPN stops unexpectedly"
            ),
            body: NSLocalizedString(
                "Your Glacier VPN stopped unexpectedly. Open Glacier to reconnect.",
                comment: "Body of the notification shown when the VPN stops unexpectedly"
            ),
            for: .failure
        )
    }
}
