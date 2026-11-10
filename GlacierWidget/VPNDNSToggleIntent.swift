//
//  VPNDNSToggleIntent.swift
//  GlacierWidget
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import AppIntents
import WidgetKit

struct VPNDNSToggleIntent: AppIntent {

    static var title: LocalizedStringResource = "Toggle VPN/Secure DNS"
    static var description = IntentDescription("Toggle Glacier VPN or Secure DNS protection on or off.")

    /// Require the device to be unlocked (passcode / Touch ID / Face ID) before this
    /// intent can run. Without this the policy defaults to `.alwaysAllowed`, which lets
    /// Shortcuts / Siri / the Action Button / Control Center invoke it in the background
    /// on a locked device — allowing protection to be disabled without authentication.
    /// This intent is the only way to toggle protection from outside the app. No deep link
    /// does it, because any app or web page can open one.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    // MARK: - Shared keys (mirrors GlacierConstants.swift)

    private static let kGroup                = "group.com.theglacierapp.GlacierApp"
    private static let kActiveConnectionType = "glacier.activeConnectionType"
    private static let kLastConnectionType   = "glacier.lastConnectionType"
    private static let kPendingToggle        = "glacier.widgetPendingToggle"
    /// Explicit action stored for the main app: "disconnect" or "connect".
    /// The main app reads this to know what to do without guessing from NE state.
    private static let kRequestedAction      = "glacier.widgetRequestedAction"
    /// When the request was made (seconds since 1970). The app ignores requests older than a
    /// minute, so one left waiting while the app was killed can't fire hours later.
    private static let kRequestedAt          = "glacier.widgetRequestedAt"

    // MARK: - Perform

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: Self.kGroup)
        let activeType = defaults?.string(forKey: Self.kActiveConnectionType)

        if activeType != nil {
            // Currently connected — request a disconnect.
            // Optimistic UI: show disconnected immediately in the widget.
            defaults?.removeObject(forKey: Self.kActiveConnectionType)
            defaults?.set("disconnect", forKey: Self.kRequestedAction)
        } else {
            // Currently disconnected — request a reconnect to the last type.
            // Optimistic UI: show connecting to last type (default: dns).
            let lastType = defaults?.string(forKey: Self.kLastConnectionType) ?? "dns"
            defaults?.set(lastType, forKey: Self.kActiveConnectionType)
            defaults?.set("connect", forKey: Self.kRequestedAction)
        }

        // Signal the main app. It will read kRequestedAction and call the real
        // NE toggle (which only the main app container is permitted to do).
        //  • If the app is backgrounded: Darwin notification wakes it immediately.
        //  • If the app is killed: the app checks kPendingToggle when it launches or next
        //    comes to the foreground, and acts only if the request is still recent.
        defaults?.set(Date().timeIntervalSince1970, forKey: Self.kRequestedAt)
        defaults?.set(true, forKey: Self.kPendingToggle)
        sendDarwinNotification()

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }

    // MARK: - Darwin notification

    private func sendDarwinNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.theglacierapp.widgetToggle" as CFString),
            nil, nil, true
        )
    }
}
