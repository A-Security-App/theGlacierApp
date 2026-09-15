//
//  VPNProtectionAlert.swift
//  Glacier
//
//  Shared between the Glacier app and the WireGuard network extension.
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import NetworkExtension
import UserNotifications
import os

/**
 Single source of truth for the "VPN protection stopped unexpectedly" alert.

 Three different producers can conclude that protection was lost, and each sees a
 different slice of the truth:

 1. `PacketTunnelProvider.stopTunnel(with:)` — the only party that is alive at the
    instant the tunnel goes down, and the only one that learns *why* (including
    `.appUpdate`, the case reported in issue #204). The containing app is normally
    suspended or terminated at that moment, so nothing else can react promptly.
 2. `VPNInterruptionMonitor` — the app's own `NEVPNStatusDidChange` observer, which
    only runs while the app process is alive but can evaluate the full on-demand
    policy against the current network.
 3. The `vpnHealth` `BGAppRefreshTask` — the periodic safety net that has always
    existed; opportunistic and slow, but survives an extension that never got to run.

 Routing all three through this type is what keeps them from talking over each
 other. Two mechanisms do the work:

 - **One fixed notification identifier.** Adding a request with an identifier that
   is already pending *replaces* it, so a flapping tunnel can never stack banners —
   the dedup is enforced by the notification centre itself and therefore works
   across process boundaries, which no in-process guard could do.
 - **Arm-then-confirm.** The extension does not post immediately; it schedules the
   banner `confirmationDelay` seconds out. If the tunnel comes back within the
   window — on-demand re-arming after a transient drop is the common case —
   `startTunnel` cancels the pending request and the user never sees anything.

 Everything this type persists lives in the shared App Group, so a decision made in
 one process is visible to the other.
 */
enum VPNProtectionAlert {

    // MARK: - Identity

    /// The one identifier used for every "protection is off" banner, so re-arming
    /// replaces rather than stacks. See the note on dedup above.
    static let notificationId = "glacier.vpn.protectionOff"

    /// Category carrying the explicit "Open Glacier" action. Registered by the app;
    /// the extension only references the id.
    static let categoryId = "glacier.vpn.protectionOffCategory"
    static let openActionId = "glacier.vpn.protectionOffOpen"

    /// `userInfo` key holding the `Kind` raw value, so the tap handler can tell an
    /// update-driven stop from a plain failure.
    static let kindUserInfoKey = "glacier.vpn.protectionOffKind"

    // MARK: - Shared storage

    private static let appGroupId = "group.com.theglacierapp.GlacierApp"

    /// Kind of the most recent unexpected stop that has not yet been resolved by a
    /// reconnect. Selects the notification copy, and backs the Home screen's fallback
    /// warning for users whose DoT is also down (a dropped tunnel while Secure DNS is
    /// still filtering is worth telling them about, but is not an at-risk device).
    private static let pendingWarningKindKey = "glacier.vpn.pendingWarningKind"
    /// When that stop happened, so a stale record expires instead of warning forever.
    private static let pendingWarningDateKey = "glacier.vpn.pendingWarningDate"
    /// When a banner was last armed. Cleared again if the banner is cancelled before
    /// delivery, so a suppressed-then-cancelled alert doesn't eat the rate limit.
    private static let lastAlertDateKey = "glacier.vpn.lastProtectionAlertDate"
    /// When the app last asked the tunnel to stop. See `noteAppInitiatedStop`.
    private static let appInitiatedStopDateKey = "glacier.vpn.appInitiatedStopDate"
    /// Set while a banner is scheduled or delivered and not yet cleared. Lets
    /// `resolve` answer "is there anything to do?" from a UserDefaults read instead of
    /// a round-trip to the notification daemon — see the note on `resolve`.
    private static let alertOutstandingKey = "glacier.vpn.alertOutstanding"
    /// Localized copy cached by the app for the extension to reuse (see `cacheCopy`).
    private static let cachedTitleKeyPrefix = "glacier.vpn.alertTitle."
    private static let cachedBodyKeyPrefix = "glacier.vpn.alertBody."

    // MARK: - Tunables

    /// How long the tunnel gets to come back before the banner is delivered. Long
    /// enough to absorb on-demand re-arming and a network handoff, short enough that
    /// a genuine loss of protection is still reported promptly.
    static let confirmationDelay: TimeInterval = 45

    /// Minimum gap between two delivered banners. A tunnel that flaps every few
    /// minutes must not produce a banner every few minutes.
    static let minimumAlertInterval: TimeInterval = 30 * 60

    /// An unresolved warning older than this is dropped rather than shown. Protects
    /// against a record written just before the app was force-quit for a week.
    static let warningLifetime: TimeInterval = 24 * 60 * 60

    /// How long a stop stays attributable to the app after the app asked for it.
    /// Sized for the slowest app-driven bounce — `TunnelsManager.modify`'s
    /// introduce-on-demand-rules path deactivates and then waits for on-demand to
    /// re-arm on the next network event, which is not instant. A genuine failure
    /// inside this window is still caught by the periodic background sweep.
    static let appInitiatedStopWindow: TimeInterval = 120

    // MARK: - Kinds

    /// What the user needs to do, which is the only distinction the copy makes.
    enum Kind: String {
        /// The tunnel was torn down because the app was being updated. The customer
        /// report in issue #204 is exactly this case: finishing the update comes
        /// before reconnecting, so the copy says so.
        case appUpdate
        /// The tunnel failed or was killed for a reason the user did not ask for.
        case failure
    }

    // MARK: - Stop-reason classification

    /// How a `NEProviderStopReason` should be treated.
    ///
    /// The split is deliberately conservative, because a false "protection is off"
    /// alert on a trusted network would be worse than a missed one. Only `failure`
    /// arms a banner from the extension, so a policy-driven teardown is *structurally*
    /// unable to produce a false alert here rather than merely being filtered out
    /// afterwards.
    ///
    /// Measured on iOS 26 (iPhone Air, 2026-09-02 sysdiagnose), the two reasons that
    /// actually occur in normal use are:
    ///
    /// - `1` (`.userInitiated`) — the user switching the VPN off.
    /// - `0` (`.none`) — an on-demand rule suppressing the tunnel. The app logged
    ///   "re-applying enabled profile while tunnel suppressed" in the same
    ///   millisecond, confirming what this is. Despite the name, `.none` is the
    ///   everyday trusted-network case, so it MUST NOT be promoted to `failure`; that
    ///   single change would fire a false alert every time a user walks into their
    ///   home or office Wi-Fi.
    ///
    /// Anything ambiguous lands in `transient` and is left to the app-side paths,
    /// which can evaluate the on-demand policy against the live network before
    /// deciding.
    enum Disposition {
        /// The user asked for this. Clear any warning and stay silent.
        case deliberate
        /// Might resolve itself; record it but let the app decide later.
        case transient
        /// Protection was lost and nobody asked for it.
        case failure(Kind)
    }

    static func disposition(for reason: NEProviderStopReason) -> Disposition {
        // `.internalError` is iOS 18.1+ and the deployment target is 18.0, so it
        // cannot be named inside the switch below. An internal NE framework error is
        // unambiguous breakage.
        if #available(iOS 18.1, *), reason == .internalError {
            return .failure(.failure)
        }

        switch reason {
        case .userInitiated,
             .providerDisabled,
             .configurationDisabled,
             .configurationRemoved,
             .userLogout,
             .userSwitch:
            return .deliberate

        case .appUpdate:
            return .failure(.appUpdate)

        case .providerFailed,
             .connectionFailed,
             .configurationFailed,
             .authenticationCanceled:
            return .failure(.failure)

        // `.none` is what iOS reports for an on-demand trusted-network suppression —
        // measured, not assumed; see the note above. `.superceded` fires during
        // Glacier's own region switch and restart-on-save flows. Neither is breakage.
        // The rest are expected conditions that on-demand recovers from by itself.
        // A plain `default` (rather than `@unknown default`) also catches reasons Apple
        // adds later, which default to silence — the app-side paths still cover them.
        case NEProviderStopReason.none,
             .noNetworkAvailable,
             .unrecoverableNetworkChange,
             .idleTimeout,
             .superceded,
             .sleep:
            return .transient

        default:
            return .transient
        }
    }

    // MARK: - Copy

    /// English fallback text. The app overwrites these with localized strings via
    /// `cacheCopy()`; the extension has no access to the app's `Localizable.strings`,
    /// so without the cache it would always post English.
    private static func defaultTitle(for kind: Kind) -> String {
        switch kind {
        case .appUpdate: return "VPN protection is off"
        case .failure:   return "VPN protection is off"
        }
    }

    private static func defaultBody(for kind: Kind) -> String {
        switch kind {
        case .appUpdate:
            return "Glacier's VPN stopped for an app update. Finish updating, then reconnect."
        case .failure:
            return "Your Glacier VPN stopped unexpectedly. Open Glacier to reconnect."
        }
    }

    /// Stores localized copy in the App Group so the extension can post in the user's
    /// language. Called by the app on launch and whenever the alert could be armed.
    static func cacheCopy(title: String, body: String, for kind: Kind, defaults: UserDefaults? = nil) {
        let store = defaults ?? sharedDefaults
        store?.set(title, forKey: cachedTitleKeyPrefix + kind.rawValue)
        store?.set(body, forKey: cachedBodyKeyPrefix + kind.rawValue)
    }

    static func title(for kind: Kind, defaults: UserDefaults? = nil) -> String {
        (defaults ?? sharedDefaults)?.string(forKey: cachedTitleKeyPrefix + kind.rawValue) ?? defaultTitle(for: kind)
    }

    static func body(for kind: Kind, defaults: UserDefaults? = nil) -> String {
        (defaults ?? sharedDefaults)?.string(forKey: cachedBodyKeyPrefix + kind.rawValue) ?? defaultBody(for: kind)
    }

    // MARK: - State

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }

    /// The unresolved unexpected stop, if any — i.e. protection dropped and has not
    /// come back. `nil` once the tunnel reconnects, once the user acknowledges, or
    /// after `warningLifetime`.
    ///
    /// This is what satisfies "if notification permission is unavailable, the app
    /// still shows a prominent disconnected warning when opened": the record is
    /// written whether or not the banner could be posted.
    static func pendingWarningKind(defaults: UserDefaults? = nil) -> Kind? {
        guard let store = defaults ?? sharedDefaults,
              let raw = store.string(forKey: pendingWarningKindKey),
              let kind = Kind(rawValue: raw) else { return nil }

        let stamp = store.double(forKey: pendingWarningDateKey)
        guard stamp > 0 else { return kind }

        guard Date().timeIntervalSince1970 - stamp <= warningLifetime else {
            clearPendingWarning(defaults: store)
            return nil
        }
        return kind
    }

    static func recordPendingWarning(_ kind: Kind, defaults: UserDefaults? = nil) {
        let store = defaults ?? sharedDefaults
        store?.set(kind.rawValue, forKey: pendingWarningKindKey)
        store?.set(Date().timeIntervalSince1970, forKey: pendingWarningDateKey)
    }

    static func clearPendingWarning(defaults: UserDefaults? = nil) {
        let store = defaults ?? sharedDefaults
        store?.removeObject(forKey: pendingWarningKindKey)
        store?.removeObject(forKey: pendingWarningDateKey)
    }

    // MARK: - App-initiated stops

    /// Records that *Glacier itself* just asked the tunnel to stop.
    ///
    /// The on-demand-disabled test in `VPNInterruptionMonitor` catches the user
    /// switching the VPN off, because those paths disable on-demand first. It does not
    /// catch the app bouncing a still-on-demand tunnel to apply a configuration change
    /// — `TunnelsManager.modify` sets `.restarting` and stops the session with
    /// on-demand left enabled, which reads exactly like a system kill. This flag closes
    /// that gap by recording intent at the source: nothing but the app calls these
    /// paths, so a stop inside the window was asked for by definition.
    static func noteAppInitiatedStop(defaults: UserDefaults? = nil) {
        (defaults ?? sharedDefaults)?.set(Date().timeIntervalSince1970, forKey: appInitiatedStopDateKey)
    }

    static func isWithinAppInitiatedStopWindow(defaults: UserDefaults? = nil) -> Bool {
        guard let stamp = (defaults ?? sharedDefaults)?.double(forKey: appInitiatedStopDateKey), stamp > 0 else {
            return false
        }
        return Date().timeIntervalSince1970 - stamp <= appInitiatedStopWindow
    }

    static func clearAppInitiatedStop(defaults: UserDefaults? = nil) {
        (defaults ?? sharedDefaults)?.removeObject(forKey: appInitiatedStopDateKey)
    }

    // MARK: - Arming

    /// Schedules the "protection is off" banner, unless one was delivered recently.
    ///
    /// - Parameters:
    ///   - kind: selects the copy, and rides along in `userInfo` for the tap handler.
    ///   - delay: `0` posts immediately — used by the callers that have *already*
    ///     confirmed the tunnel is down and should be up (the BGTask sweep). The
    ///     extension passes `confirmationDelay` instead, so a tunnel that comes
    ///     straight back cancels the banner before anyone sees it.
    ///   - force: skips the rate limit. Reserved for a user-visible retry; not used
    ///     by the automatic paths.
    ///
    /// The pending-warning record is written even when the banner itself is
    /// suppressed, so the in-app warning is never lost to the rate limiter.
    static func arm(_ kind: Kind,
                    delay: TimeInterval,
                    force: Bool = false,
                    logger: Logger,
                    defaults: UserDefaults? = nil,
                    completion: (() -> Void)? = nil) {

        let store = defaults ?? sharedDefaults
        recordPendingWarning(kind, defaults: store)

        let now = Date().timeIntervalSince1970
        let last = store?.double(forKey: lastAlertDateKey) ?? 0
        if !force, last > 0, now - last < minimumAlertInterval {
            logger.notice("[VPNAlert] suppressed — last alert \(Int(now - last))s ago (min \(Int(minimumAlertInterval))s)")
            completion?()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title(for: kind, defaults: store)
        content.body = body(for: kind, defaults: store)
        content.sound = .default
        content.categoryIdentifier = categoryId
        content.userInfo = [kindUserInfoKey: kind.rawValue]

        // A nil trigger fires on delivery to the notification centre; a time-interval
        // trigger hands the wait to the system daemon, so the banner still arrives
        // after this process (extension or app) is gone.
        let trigger: UNNotificationTrigger? = delay > 0
            ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            : nil

        let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)

        store?.set(now, forKey: lastAlertDateKey)
        store?.set(true, forKey: alertOutstandingKey)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error as NSError? {
                logger.error("[VPNAlert] failed to arm \(kind.rawValue, privacy: .public): \(error)")
                // The banner never got scheduled, so it must not hold the rate limit
                // shut against the next attempt, nor make `resolve` do work.
                store?.removeObject(forKey: lastAlertDateKey)
                store?.removeObject(forKey: alertOutstandingKey)
            } else {
                logger.notice("[VPNAlert] armed \(kind.rawValue, privacy: .public) in \(Int(delay))s")
            }
            completion?()
        }
    }

    /// Called whenever protection is known to be back, or the stop turned out to be
    /// deliberate. Removes the banner and clears the in-app warning.
    ///
    /// If the banner was still pending — never shown to anyone — the rate-limit stamp
    /// is released too. Otherwise a 45-second blip would silence a genuine alert for
    /// the following half hour.
    ///
    /// Callers fire this on every `.connected` transition, and NE delivers those in
    /// bursts — a device sysdiagnose showed twelve inside one second for a single
    /// reconnect. Almost all of them have nothing to clear, so the common case must
    /// not cost a round-trip to the notification daemon plus two removals. The
    /// outstanding flag makes "nothing to do" a single UserDefaults read, and keeps
    /// the log readable by only reporting resolves that did something.
    static func resolve(reason: String,
                        logger: Logger,
                        defaults: UserDefaults? = nil,
                        completion: (() -> Void)? = nil) {

        let store = defaults ?? sharedDefaults

        let isOutstanding = store?.bool(forKey: alertOutstandingKey) ?? false
        guard isOutstanding || pendingWarningKind(defaults: store) != nil else {
            completion?()
            return
        }

        clearPendingWarning(defaults: store)
        store?.removeObject(forKey: alertOutstandingKey)

        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let wasStillPending = requests.contains { $0.identifier == notificationId }
            center.removePendingNotificationRequests(withIdentifiers: [notificationId])
            center.removeDeliveredNotifications(withIdentifiers: [notificationId])
            if wasStillPending {
                store?.removeObject(forKey: lastAlertDateKey)
            }
            logger.notice("[VPNAlert] resolved (\(reason, privacy: .public)); banner was \(wasStillPending ? "pending" : "not pending", privacy: .public)")
            completion?()
        }
    }
}
