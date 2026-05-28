//
//  GlacierWidget.swift
//  GlacierWidget
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import WidgetKit
import SwiftUI

// MARK: - Shared defaults keys (mirrors GlacierConstants.swift)

private let kGlacierGroup            = "group.com.glaciersec.GlacierApp"
private let kActiveConnectionTypeKey = "glacier.activeConnectionType"
private let kWidgetSecurityIssueKey  = "glacier.securityIssueText"

// MARK: - Colors
// Hardcoded so the widget never depends on a named-color asset catalog,
// which lives in the main app bundle and may not be present in the
// widget extension bundle at runtime.

private extension Color {
    static let glacierGreen    = Color(red: 0.314, green: 0.800, blue: 0.561)  // #50CC8F
    static let glacierGray     = Color(red: 0.55,  green: 0.55,  blue: 0.58)
    // Gradient — mirrors Colors.xcassets (main bundle unavailable in extension)
    static let glacierPurple10 = Color(red: 0.847, green: 0.863, blue: 0.976)  // #D8DCF9
    static let glacierPurple25 = Color(red: 0.776, green: 0.792, blue: 0.949)  // #C6CAF2
    static let glacierPurple50 = Color(red: 0.627, green: 0.651, blue: 0.894)  // #A0A6E4
    static let glacierEmber50  = Color(red: 1.000, green: 0.627, blue: 0.494)  // #FFA07E
    static let glacierEmber25  = Color(red: 1.000, green: 0.745, blue: 0.667)  // #FFBEAA
    static let glacierEmber10  = Color(red: 1.000, green: 0.796, blue: 0.725)  // #FFCBB9
    // Container & button palette
    static let glacierGrey10   = Color(red: 0.953, green: 0.953, blue: 0.953)  // #F3F3F3 badge bg light
    static let glacierGrey20   = Color(red: 0.910, green: 0.910, blue: 0.910)  // #E8E8E8 tertiary border light
    static let glacierGrey70   = Color(red: 0.298, green: 0.298, blue: 0.298)  // #4C4C4C tertiary border dark
    static let glacierGrey90   = Color(red: 0.204, green: 0.204, blue: 0.204)  // #343434 container bg dark
    static let glacierGrey95   = Color(red: 0.106, green: 0.098, blue: 0.110)  // #1B191C badge bg dark
    static let glacierHighlight = Color(red: 0.169, green: 0.349, blue: 1.000) // #2B59FF primary button
}

// MARK: - Background modifier

private struct WidgetGradientBackgroundModifier: ViewModifier {
    let gradient: LinearGradient
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(gradient, for: .widget)
        } else {
            content.background(gradient)
        }
    }
}

// MARK: - Timeline entry

struct GlacierWidgetEntry: TimelineEntry {
    let date: Date
    /// "dns", "vpn", or nil when disconnected.
    let activeConnectionType: String?
    /// Non-nil when there is a security warning; drives gradient color only, not displayed.
    let securityIssueText: String?
}

// MARK: - Timeline provider

struct GlacierWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> GlacierWidgetEntry {
        GlacierWidgetEntry(date: .now, activeConnectionType: "vpn", securityIssueText: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlacierWidgetEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlacierWidgetEntry>) -> Void) {
        let entry = makeEntry()
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 5, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func makeEntry() -> GlacierWidgetEntry {
        let defaults     = UserDefaults(suiteName: kGlacierGroup)
        let activeType   = defaults?.string(forKey: kActiveConnectionTypeKey)
        let issueText    = defaults?.string(forKey: kWidgetSecurityIssueKey)
        let displayIssue = (issueText?.isEmpty == false) ? issueText : nil
        return GlacierWidgetEntry(date: .now, activeConnectionType: activeType, securityIssueText: displayIssue)
    }
}

// MARK: - Widget entry view

struct GlacierWidgetEntryView: View {

    let entry: GlacierWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private var isConnected: Bool        { entry.activeConnectionType != nil }
    private var isVPN: Bool              { entry.activeConnectionType == "vpn" }
    private var hasIssue: Bool           { entry.securityIssueText != nil }

    private var primaryTextColor: Color  { colorScheme == .dark ? .white : .black }
    private var badgeBg: Color           { colorScheme == .dark ? .glacierGrey95 : .glacierGrey10 }

    private var securityStatusText: String {
        hasIssue ? "Your system may\nbe at risk." : "All clear.\nNo issues found."
    }

    private var connectionStatusText: String {
        isConnected ? "Connected" : "Disconnected"
    }

    private var statusGradient: LinearGradient {
        let colors: [Color] = hasIssue
            ? [.glacierEmber50, .glacierEmber25, .glacierEmber10]
            : [.glacierPurple10, .glacierPurple25, .glacierPurple50]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        Group {
            if family == .systemSmall {
                smallLayout
            } else {
                mediumLayout
            }
        }
        .modifier(WidgetGradientBackgroundModifier(gradient: statusGradient))
    }

    // MARK: Small layout

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(securityStatusText)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.black)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let issueText = entry.securityIssueText {
                Text(issueText)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(.black)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
            }
            connectionStatusRow(statusFontSize: 12, badgeFontSize: 10, badgePadding: 5, showStatusText: !isConnected)
        }
        .padding(4)
    }

    // MARK: Medium layout

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(securityStatusText)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.black)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 160, alignment: .leading)
            Spacer()
            if let issueText = entry.securityIssueText {
                Text(issueText)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.black)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            connectionStatusRow(statusFontSize: 14, badgeFontSize: 12, badgePadding: 8)
        }
        .padding(12)
    }

    // MARK: Shared sub-views

    private func connectionStatusRow(statusFontSize: CGFloat, badgeFontSize: CGFloat, badgePadding: CGFloat, showStatusText: Bool = true) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if showStatusText {
                Text(connectionStatusText)
                    .font(.system(size: statusFontSize, weight: .semibold))
                    .foregroundColor(.black)
            }

            HStack(spacing: 6) {
                // DNS badge always shown when connected; VPN connection also shows DNS (DoT is active)
                if isConnected {
                    badge("DNS", fontSize: badgeFontSize, padding: badgePadding)
                }
                if isVPN {
                    badge("VPN", fontSize: badgeFontSize, padding: badgePadding)
                }
            }

            Spacer()
        }
    }

    private func badge(_ text: String, fontSize: CGFloat, padding: CGFloat) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(primaryTextColor)
            .padding(.all, padding)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(badgeBg)
            )
    }

    @ViewBuilder
    private func connectButton(height: CGFloat, fontSize: CGFloat) -> some View {
        let action = isConnected ? "disconnect" : "connect"
        let title  = isConnected ? "Disconnect" : "Connect"

        Link(destination: URL(string: "glacierapp://widget/\(action)")!) {
            ZStack {
                if isConnected {
                    // Tertiary style — matches GlacierButton(.tertiary)
                    RoundedRectangle(cornerRadius: 16)
                        .fill(colorScheme == .dark ? Color.glacierGrey90 : .white)
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(colorScheme == .dark ? Color.glacierGrey70 : .glacierGrey20, lineWidth: 1)
                } else {
                    // Primary style — matches GlacierButton(.primary)
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.glacierHighlight)
                }
                Text(title)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(isConnected ? primaryTextColor : .white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
        }
    }
}

// MARK: - Widget

struct GlacierWidget: Widget {

    let kind = "GlacierWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GlacierWidgetProvider()) { entry in
            GlacierWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Glacier")
        .description("Monitor and control your Glacier VPN and DNS protection.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
