//
//  VPNDNSToggleIntent.swift
//  GlacierWidget
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import AppIntents
import WidgetKit

struct VPNDNSToggleIntent: AppIntent {

    static var title: LocalizedStringResource = "Toggle VPN/DNS"
    static var description = IntentDescription("Toggle Glacier VPN or DNS protection on or off.")

    // MARK: - Shared keys (mirrors GlacierConstants.swift)

    private static let kGroup                = "group.com.theglacierapp.GlacierApp"
    private static let kActiveConnectionType = "glacier.activeConnectionType"
    private static let kLastConnectionType   = "glacier.lastConnectionType"
    private static let kPendingToggle        = "glacier.widgetPendingToggle"
    /// Explicit action stored for the main app: "disconnect" or "connect".
    /// The main app reads this to know what to do without guessing from NE state.
    private static let kRequestedAction      = "glacier.widgetRequestedAction"

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
        //  • If the app is killed: kPendingToggle flag is consumed on next foreground.
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
