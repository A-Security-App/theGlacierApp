//
//  GlacierDNSSetupGuide.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI
import UIKit

/**
 GlacierDNSSetupGuide is a slide-up, step-by-step guide for selecting Glacier in iOS Settings
 (General → VPN & Device Management → DNS → Glacier). A miniature Settings app shows where to tap
 on each step, and the last step opens iOS Settings.

 Users can open Settings from the header on any step, or from the last step's button, and the
 guide stays up while they're there. Each time the app comes back, and on reaching the last step,
 it checks whether Glacier is selected. Once it is, the guide switches to a success state with a
 single Done button, and closing it any other way counts as Done too.

 It is presented in the overlay window, like GlacierPopup, so `dismissPopup()` removes it too.
 Cancel and Done slide the sheet away before calling back, and the caller is expected to call
 `dismissPopup()` from those callbacks. Open Settings leaves the guide on screen.
 */
struct GlacierDNSSetupGuide: View {

    // MARK: - Private properties

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var glacierColorScheme = GlacierColorScheme()

    @State private var step = 0
    @State private var isPresented = false
    @State private var isClosing = false
    @State private var dragOffset: CGFloat = 0
    @State private var didPickGlacier = false
    /// Whether iOS reports Glacier selected in Settings, as of the last check.
    @State private var isDNSSelected = false

    private let onCancel: () -> Void
    private let onOpenSettings: () -> Void
    private let onDone: () -> Void
    private let checkDNSSelected: (@escaping (Bool) -> Void) -> Void

    private static let steps: [(title: String, body: String)] = [
        (
            NSLocalizedString("Open the Settings app", comment: "DNS setup guide step 1 title"),
            NSLocalizedString("In Settings page, navigate to General.", comment: "DNS setup guide step 1 body")
        ),
        (
            NSLocalizedString("Tap VPN & Device Management", comment: "DNS setup guide step 2 title"),
            NSLocalizedString("Scroll down in General to find it.", comment: "DNS setup guide step 2 body")
        ),
        (
            NSLocalizedString("Tap DNS", comment: "DNS setup guide step 3 title"),
            NSLocalizedString("It’s below VPN.", comment: "DNS setup guide step 3 body")
        ),
        (
            NSLocalizedString("Then select Glacier.", comment: "DNS setup guide step 4 title"),
            .dnsSettingsReopenTip
        ),
        (
            NSLocalizedString("Return to Glacier", comment: "DNS setup guide step 5 title"),
            NSLocalizedString("Tap ◀ Glacier at the top-left of Settings, or switch back to the app. Secure DNS shows as connected.", comment: "DNS setup guide step 5 body")
        )
    ]

    private var isLastStep: Bool { step == Self.steps.count - 1 }

    /// Closing the guide once Glacier is selected finishes it, however the user closes it.
    private var dismissAction: () -> Void {
        isDNSSelected ? onDone : onCancel
    }

    private var title: String {
        isDNSSelected
            ? NSLocalizedString("You’re all set", comment: "DNS setup guide success title")
            : Self.steps[step].title
    }

    private var bodyText: String {
        isDNSSelected
            ? NSLocalizedString("Glacier is now filtering DNS on this device.", comment: "DNS setup guide success body")
            : Self.steps[step].body
    }
    private var isDark: Bool { glacierColorScheme.activeScheme == .dark }

    /// The overlay container ignores the safe area, so read the device insets from UIKit.
    private var safeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets ?? .zero
    }

    // MARK: - Initializer

    /**
     - Parameters:
       - onCancel: Cancel, the close button, a tap outside, or a drag down.
       - onOpenSettings: Open Settings, in the header or on the last step. The guide stays on screen.
       - onDone: Done, once Glacier is selected in Settings, or closing the guide after that.
       - checkDNSSelected: Reports whether Glacier is selected in iOS Settings, on the main queue.
     */
    init(
        onCancel: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onDone: @escaping () -> Void,
        checkDNSSelected: @escaping (@escaping (Bool) -> Void) -> Void
    ) {
        self.onCancel = onCancel
        self.onOpenSettings = onOpenSettings
        self.onDone = onDone
        self.checkDNSSelected = checkDNSSelected
    }

    // MARK: - UI/UX

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background
            Color.black.opacity(isPresented ? (isDark ? 0.5 : 0.4) : 0)
                .ignoresSafeArea()
                .onTapGesture {
                    close(then: dismissAction)
                }

            if isPresented {
                sheet
                    .offset(y: max(dragOffset, 0))
                    .transition(.move(edge: .bottom))
            }
        }
        .environmentObject(glacierColorScheme)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                isPresented = true
            }
        }
        .onChange(of: colorScheme) { newScheme in
            glacierColorScheme.setScheme(newScheme)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Back from Settings (or anywhere else): if Glacier is selected now, finish on the last
            // step. If not, stay on the step the user left, which is likely where they got stuck.
            checkDNSSelected { isSelected in
                withAnimation(.snappy) {
                    isDNSSelected = isSelected
                    if isSelected {
                        step = Self.steps.count - 1
                    }
                }
            }
        }
        .task(id: step) {
            if isLastStep {
                checkDNSSelected { isSelected in
                    withAnimation(.snappy) { isDNSSelected = isSelected }
                }
            }

            // On "select Glacier", tick Glacier in the mini Settings after a beat.
            didPickGlacier = false
            guard step == 3 else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            didPickGlacier = true
        }
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.grey50.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            header
                .padding(.top, 8)
                .padding(.horizontal, 20)

            GeometryReader { proxy in
                MiniPhone(
                    height: min(462, proxy.size.height),
                    palette: isDark ? .dark : .light,
                    showsBackToApp: !isLastStep
                ) {
                    MiniSettings(step: step, didPickGlacier: didPickGlacier, isDark: isDark)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .padding(.top, 16)
            .accessibilityHidden(true)

            footer
                .padding(.top, 18)
                .padding(.horizontal, 24)
                .padding(.bottom, max(safeAreaInsets.bottom, 16) + 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32, style: .continuous)
                .fill(isDark ? Color.grey95 : Color.grey10)
                .ignoresSafeArea(edges: .bottom)
        )
        .padding(.top, safeAreaInsets.top + 8)
        .gesture(dragGesture)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                close(then: dismissAction)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isDark ? .white : .black)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(isDark ? Color.grey90 : Color.white))
            }
            .accessibilityLabel(NSLocalizedString("Cancel", comment: "Cancel button title"))

            GlacierLabel(
                text: NSLocalizedString("Setup", comment: "DNS setup guide header"),
                font: .neueHassGroteskThickFont(ofSize: 26),
                lineLimit: 1,
                minimumScaleFactor: 0.7
            )
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            // For users who'd rather follow along in Settings from the start. The last step has
            // its own Open Settings button, and there's nothing to open once Glacier is selected.
            if !isLastStep, !isDNSSelected {
                Button {
                    onOpenSettings()
                } label: {
                    HStack(spacing: 4) {
                        GlacierLabel(
                            text: NSLocalizedString("Settings", comment: "DNS setup guide header button that opens iOS Settings"),
                            font: .bodyThick,
                            lineLimit: 1,
                            customTextColor: .constant(.highlight)
                        )
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.highlight)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Capsule().fill(isDark ? Color.grey90 : Color.white))
                }
                .fixedSize()
                .accessibilityLabel(NSLocalizedString("Open Settings", comment: "Open settings button title"))
                .transition(.opacity)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 6) {
                ForEach(Self.steps.indices, id: \.self) { index in
                    Button {
                        withAnimation(.snappy) { step = index }
                    } label: {
                        Capsule()
                            .fill(index <= step ? (isDark ? Color.white : Color.black) : (isDark ? Color.grey70 : Color.grey30))
                            .frame(width: index == step ? 28 : 6, height: 6)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(String(format: NSLocalizedString("Step %d", comment: "DNS setup guide page dot accessibility label"), index + 1))
                    .accessibilityAddTraits(index == step ? .isSelected : [])
                }

                Spacer(minLength: 8)

                GlacierLabel(
                    text: String(
                        format: NSLocalizedString("Step %d of %d", comment: "DNS setup guide step counter"),
                        step + 1,
                        Self.steps.count
                    ),
                    font: .bodySmallThick,
                    customTextColor: .constant(.grey50)
                )
                .monospacedDigit()
            }
            // Hidden rather than removed once Glacier is selected, so the mini phone keeps its size.
            .opacity(isDNSSelected ? 0 : 1)
            .allowsHitTesting(!isDNSSelected)
            .accessibilityHidden(isDNSSelected)

            VStack(alignment: .leading, spacing: 5) {
                GlacierLabel(
                    text: title,
                    font: .headerOne,
                    allowsVerticalGrowth: true
                )

                GlacierLabel(
                    text: bodyText,
                    font: .bodyLarge,
                    lineSpacing: 3,
                    allowsVerticalGrowth: true,
                    customTextColor: .constant(isDark ? .grey40 : .grey60)
                )
            }
            // Room for the longest step (a two-line title or a three-line body), so the mini
            // phone above keeps the same size from step to step.
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .id(isDNSSelected ? -1 : step)
            .transition(.opacity)

            if isDNSSelected {
                GlacierButton(
                    style: .primary,
                    title: NSLocalizedString("Done", comment: "Done button title"),
                    height: 50,
                    padding: 12
                ) {
                    close(then: onDone)
                }
                .transition(.opacity)
            } else {
                stepButtons
            }
        }
    }

    private var stepButtons: some View {
        HStack(spacing: 10) {
            GlacierButton(
                style: .tertiary,
                title: step == 0
                    ? NSLocalizedString("Cancel", comment: "Cancel button title")
                    : NSLocalizedString("Back", comment: "Back button title"),
                height: 50,
                padding: 12
            ) {
                if step == 0 {
                    close(then: onCancel)
                } else {
                    withAnimation(.snappy) { step -= 1 }
                }
            }
            .frame(maxWidth: .infinity)

            // GlacierButton picks its colours on appear, so the last step gets its own button.
            Group {
                if isLastStep {
                    GlacierButton(
                        style: .primary,
                        title: NSLocalizedString("Open Settings", comment: "Open settings button title"),
                        height: 50,
                        padding: 12
                    ) {
                        onOpenSettings()
                    }
                } else {
                    GlacierButton(
                        style: .secondary,
                        title: NSLocalizedString("Next", comment: "Next button title"),
                        height: 50,
                        padding: 12
                    ) {
                        withAnimation(.snappy) { step += 1 }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Drag down to dismiss; swipe sideways to change steps.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let translation = value.translation
                if abs(translation.width) > abs(translation.height) {
                    // Nothing left to step through once Glacier is selected.
                    guard !isDNSSelected else { return }
                    withAnimation(.snappy) {
                        if translation.width < -50, !isLastStep {
                            step += 1
                        } else if translation.width > 50, step > 0 {
                            step -= 1
                        }
                    }
                    return
                }
                if translation.height > 120 || value.predictedEndTranslation.height > 300 {
                    close(then: dismissAction)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - Private methods

    /// Slides the sheet away, then runs `action`. Ignores repeat taps while closing.
    private func close(then action: @escaping () -> Void) {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(.easeIn(duration: 0.25)) {
            isPresented = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            action()
        }
    }
}

// MARK: - Mini iOS Settings

/// Colours of the iOS Settings app, so the miniature looks like the real thing in either mode.
private struct MiniIOSPalette {
    let background: Color
    let card: Color
    let text: Color
    let secondaryText: Color
    let separator: Color
    let tint: Color
    let chevron: Color
    let search: Color
    let highlight: Color
    let bezel: Color
    let isDark: Bool

    static let light = MiniIOSPalette(
        background: Color(hex: 0xF2F2F7), card: .white, text: .black, secondaryText: Color(hex: 0x8A8A8E),
        separator: Color(hex: 0xC6C6C8), tint: Color(hex: 0x007AFF), chevron: Color(hex: 0xC4C4C7),
        search: Color(hex: 0xE3E3E8), highlight: Color(hex: 0xD1D1D6), bezel: Color(hex: 0x0A0A0A), isDark: false
    )

    static let dark = MiniIOSPalette(
        background: .black, card: Color(hex: 0x1C1C1E), text: .white, secondaryText: Color(hex: 0x98989F),
        separator: Color(hex: 0x38383A), tint: Color(hex: 0x0A84FF), chevron: Color(hex: 0x5A5A5F),
        search: Color(hex: 0x1C1C1E), highlight: Color(hex: 0x3A3A3C), bezel: Color(hex: 0x1A1A1C), isDark: true
    )
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private struct MiniIOSPaletteKey: EnvironmentKey {
    static let defaultValue = MiniIOSPalette.light
}

private extension EnvironmentValues {
    var miniIOSPalette: MiniIOSPalette {
        get { self[MiniIOSPaletteKey.self] }
        set { self[MiniIOSPaletteKey.self] = newValue }
    }
}

/// An iPhone frame drawn at `height`. Its content is laid out at a 390pt screen width and scaled
/// down to fit, so it reads like a real screen at any size.
private struct MiniPhone<Content: View>: View {

    let height: CGFloat
    let palette: MiniIOSPalette
    let showsBackToApp: Bool
    @ViewBuilder let content: Content

    private static var screenWidth: CGFloat { 390 }

    var body: some View {
        let width = height * 220 / 462
        let unit = width / 220
        let bezel = 6 * unit
        let innerWidth = width - bezel * 2
        let innerHeight = height - bezel * 2
        let scale = innerWidth / Self.screenWidth

        ZStack(alignment: .top) {
            content
            statusBar
            Capsule()
                .fill(palette.text)
                .frame(width: 134, height: 5)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)
        }
        .frame(width: Self.screenWidth, height: innerHeight / scale, alignment: .top)
        .background(palette.background)
        .environment(\.miniIOSPalette, palette)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: innerWidth, height: innerHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 34 * unit, style: .continuous))
        .padding(bezel)
        .background(
            RoundedRectangle(cornerRadius: 40 * unit, style: .continuous)
                .fill(palette.bezel)
                .shadow(color: .black.opacity(palette.isDark ? 0.6 : 0.18), radius: 20, y: 20)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 40 * unit, style: .continuous)
                .stroke(palette.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private var statusBar: some View {
        ZStack(alignment: .top) {
            HStack {
                Text(verbatim: "9:41")
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrowtriangle.left.fill")
                                .font(.system(size: 7))
                            Text(verbatim: "Glacier")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(palette.tint)
                        .fixedSize()
                        .offset(x: -6, y: 22)
                        .opacity(showsBackToApp ? 1 : 0)
                        .animation(.easeInOut(duration: 0.2), value: showsBackToApp)
                    }

                Spacer()

                HStack(spacing: 5) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach([4, 6, 8, 11], id: \.self) { barHeight in
                            RoundedRectangle(cornerRadius: 1)
                                .frame(width: 3, height: CGFloat(barHeight))
                        }
                    }
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(palette.text.opacity(palette.isDark ? 0.45 : 0.4), lineWidth: 1.5)
                        .frame(width: 25, height: 12)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .frame(width: 17, height: 8)
                                .padding(.leading, 2.5)
                        }
                }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(palette.text)
            .padding(.horizontal, 34)
            .frame(height: 54)

            Capsule()
                .fill(Color.black)
                .frame(width: 124, height: 36)
                .padding(.top, 11)
        }
    }
}

/// The four Settings screens the user taps through, pushed like a navigation stack, followed by
/// Glacier showing Secure DNS as on.
private struct MiniSettings: View {

    let step: Int
    let didPickGlacier: Bool
    let isDark: Bool

    @Environment(\.miniIOSPalette) private var palette

    var body: some View {
        ZStack(alignment: .top) {
            pushed(0) {
                MiniNavigationBar(title: NSLocalizedString("Settings", comment: "iOS Settings app title, shown in the DNS setup guide"), isLarge: true)
                searchField
                MiniGroup {
                    MiniRow(label: NSLocalizedString("Airplane Mode", comment: "iOS Settings row, shown in the DNS setup guide"), tileColor: Color(hex: 0xFF9500), accessory: .none, isFirst: true)
                    MiniRow(label: NSLocalizedString("Wi-Fi", comment: "iOS Settings row, shown in the DNS setup guide"), tileColor: Color(hex: 0x007AFF), value: "Glacier-5G")
                    MiniRow(label: NSLocalizedString("Bluetooth", comment: "iOS Settings row, shown in the DNS setup guide"), tileColor: Color(hex: 0x007AFF), value: NSLocalizedString("On", comment: "iOS Settings Bluetooth value, shown in the DNS setup guide"))
                    MiniRow(label: NSLocalizedString("Cellular", comment: "iOS Settings row, shown in the DNS setup guide"), tileColor: Color(hex: 0x34C759))
                }
                MiniGroup {
                    MiniRow(label: NSLocalizedString("General", comment: "iOS Settings row, shown in the DNS setup guide"), tileColor: Color(hex: 0x8E8E93), tileSymbol: "gearshape.fill", isFirst: true, isTarget: step == 0)
                    MiniRow(label: NSLocalizedString("Accessibility", comment: "iOS Settings row, shown in the DNS setup guide"), tileColor: Color(hex: 0x007AFF))
                    MiniRow(label: NSLocalizedString("Camera", comment: "iOS Settings row, shown in the DNS setup guide"), tileColor: Color(hex: 0x8E8E93))
                    MiniRow(label: NSLocalizedString("Battery", comment: "iOS Settings row, shown in the DNS setup guide"), tileColor: Color(hex: 0x34C759))
                }
            }

            pushed(1) {
                MiniNavigationBar(title: NSLocalizedString("General", comment: "iOS Settings row, shown in the DNS setup guide"), backTitle: NSLocalizedString("Settings", comment: "iOS Settings app title, shown in the DNS setup guide"))
                MiniGroup {
                    MiniRow(label: NSLocalizedString("About", comment: "iOS Settings row, shown in the DNS setup guide"), isFirst: true)
                    MiniRow(label: NSLocalizedString("Software Update", comment: "iOS Settings row, shown in the DNS setup guide"))
                }
                MiniGroup {
                    MiniRow(label: NSLocalizedString("AirDrop", comment: "iOS Settings row, shown in the DNS setup guide"), isFirst: true)
                    MiniRow(label: NSLocalizedString("AirPlay & Continuity", comment: "iOS Settings row, shown in the DNS setup guide"))
                }
                MiniGroup {
                    MiniRow(label: NSLocalizedString("Date & Time", comment: "iOS Settings row, shown in the DNS setup guide"), isFirst: true)
                    MiniRow(label: NSLocalizedString("Keyboard", comment: "iOS Settings row, shown in the DNS setup guide"))
                    MiniRow(label: NSLocalizedString("Language & Region", comment: "iOS Settings row, shown in the DNS setup guide"))
                }
                MiniGroup {
                    MiniRow(label: NSLocalizedString("VPN & Device Management", comment: "iOS Settings row, shown in the DNS setup guide"), isFirst: true, isTarget: step == 1)
                }
                MiniGroup {
                    MiniRow(label: NSLocalizedString("Legal & Regulatory", comment: "iOS Settings row, shown in the DNS setup guide"), isFirst: true)
                }
            }

            pushed(2) {
                MiniNavigationBar(title: NSLocalizedString("VPN & Device Management", comment: "iOS Settings row, shown in the DNS setup guide"), backTitle: NSLocalizedString("General", comment: "iOS Settings row, shown in the DNS setup guide"))
                MiniGroup {
                    MiniRow(label: NSLocalizedString("VPN", comment: "iOS Settings row, shown in the DNS setup guide"), value: NSLocalizedString("Not Connected", comment: "iOS Settings VPN value, shown in the DNS setup guide"), isFirst: true)
                    MiniRow(label: NSLocalizedString("DNS", comment: "iOS Settings row, shown in the DNS setup guide"), value: NSLocalizedString("Automatic", comment: "iOS Settings DNS option, shown in the DNS setup guide"), isTarget: step == 2)
                }
            }

            pushed(3) {
                MiniNavigationBar(title: NSLocalizedString("DNS", comment: "iOS Settings row, shown in the DNS setup guide"), backTitle: NSLocalizedString("Back", comment: "Back button title"))
                MiniGroup(footer: NSLocalizedString("Choose how this device resolves domain names.", comment: "iOS Settings DNS footer, shown in the DNS setup guide")) {
                    MiniRow(label: NSLocalizedString("Automatic", comment: "iOS Settings DNS option, shown in the DNS setup guide"), accessory: .check(!didPickGlacier), isFirst: true)
                    MiniRow(label: "Glacier", accessory: .check(didPickGlacier), isTarget: step == 3 && !didPickGlacier)
                }
            }

            MiniGlacierConnected(isActive: step == 4, isDark: isDark)
                .opacity(step == 4 ? 1 : 0)
                .scaleEffect(step == 4 ? 1 : 0.86)
                .clipShape(RoundedRectangle(cornerRadius: step == 4 ? 0 : 60, style: .continuous))
                .zIndex(10)
                .allowsHitTesting(false)
        }
        .animation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.46), value: step)
        .animation(.spring(response: 0.26, dampingFraction: 0.6), value: didPickGlacier)
    }

    /// One Settings screen: on screen at its step, slid partly left and dimmed once the user has
    /// gone past it, and waiting off to the right before.
    private func pushed<Content: View>(_ index: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.top, 54)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.background)
        .brightness(index < step ? (palette.isDark ? -0.3 : -0.08) : 0)
        .shadow(color: .black.opacity(index > 0 ? (palette.isDark ? 0.5 : 0.08) : 0), radius: 10, x: -8)
        .offset(x: index < step ? -117 : (index == step ? 0 : 400))
        .zIndex(Double(index))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
            Text(NSLocalizedString("Search", comment: "iOS Settings search field, shown in the DNS setup guide"))
                .font(.system(size: 17))
        }
        .foregroundColor(palette.secondaryText)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.search))
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }
}

private struct MiniNavigationBar: View {

    let title: String
    var backTitle: String? = nil
    var isLarge = false

    @Environment(\.miniIOSPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if !isLarge {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 70)
                }
                if let backTitle {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                        Text(backTitle)
                            .font(.system(size: 17))
                            .lineLimit(1)
                    }
                    .foregroundColor(palette.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                }
            }
            .frame(height: 44)

            if isLarge {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .foregroundColor(palette.text)
        .padding(.bottom, 6)
    }
}

private struct MiniGroup<Content: View>: View {

    var footer: String? = nil
    @ViewBuilder let content: Content

    @Environment(\.miniIOSPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                content
            }
            .background(palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let footer {
                Text(footer)
                    .font(.system(size: 13))
                    .foregroundColor(palette.secondaryText)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 22)
    }
}

private struct MiniRow: View {

    enum Accessory {
        case chevron
        case check(Bool)
        case none
    }

    let label: String
    var tileColor: Color? = nil
    var tileSymbol: String? = nil
    var value: String? = nil
    var accessory: Accessory = .chevron
    var isFirst = false
    /// The row to tap on this step: it flashes and a touch indicator pulses over it.
    var isTarget = false

    @Environment(\.miniIOSPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isTarget, !reduceMotion {
            // Captured as a constant: the animator's content closure is Sendable.
            let highlightColor = palette.highlight
            row
                .keyframeAnimator(initialValue: TapPulse(), repeating: true) { content, pulse in
                    content
                        .background(highlightColor.opacity(pulse.highlight))
                        .overlay { TapRing(opacity: pulse.ringOpacity, scale: pulse.ringScale) }
                } keyframes: { _ in
                    KeyframeTrack(\.ringOpacity) {
                        CubicKeyframe(0.9, duration: 0.45)
                        CubicKeyframe(0.9, duration: 0.54)
                        CubicKeyframe(0, duration: 0.45)
                        LinearKeyframe(0, duration: 0.36)
                    }
                    KeyframeTrack(\.ringScale) {
                        CubicKeyframe(1, duration: 0.45)
                        CubicKeyframe(0.85, duration: 0.54)
                        CubicKeyframe(1.1, duration: 0.45)
                        LinearKeyframe(1.6, duration: 0.36)
                    }
                    KeyframeTrack(\.highlight) {
                        LinearKeyframe(0, duration: 0.54)
                        CubicKeyframe(1, duration: 0.27)
                        LinearKeyframe(1, duration: 0.27)
                        CubicKeyframe(0, duration: 0.36)
                        LinearKeyframe(0, duration: 0.36)
                    }
                }
        } else if isTarget {
            // Reduce Motion: hold the pressed state instead of looping it.
            row
                .background(palette.highlight)
                .overlay { TapRing(opacity: 0.9, scale: 1) }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 14) {
            if let tileColor {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tileColor)
                    .frame(width: 29, height: 29)
                    .overlay {
                        if let tileSymbol {
                            Image(systemName: tileSymbol)
                                .font(.system(size: 17))
                                .foregroundColor(.white)
                        } else {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.55))
                                .frame(width: 12, height: 12)
                        }
                    }
            }

            HStack(spacing: 8) {
                Text(label)
                    .foregroundColor(palette.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let value {
                    Text(value)
                        .foregroundColor(palette.secondaryText)
                        .lineLimit(1)
                }

                switch accessory {
                case .chevron:
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(palette.chevron)
                case .check(let isChecked):
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(palette.tint)
                        .opacity(isChecked ? 1 : 0)
                        .scaleEffect(isChecked ? 1 : 0.4)
                        .frame(width: 20)
                case .none:
                    EmptyView()
                }
            }
            .font(.system(size: 17))
            .padding(.trailing, 14)
            .frame(height: 46)
            .overlay(alignment: .top) {
                if !isFirst {
                    Rectangle()
                        .fill(palette.separator)
                        .frame(height: 0.5)
                }
            }
        }
        .padding(.leading, 16)
    }
}

/// One loop of a tap on the target row, every 1.8 seconds: the touch indicator lands and presses
/// while the row flashes.
private struct TapPulse {
    var highlight: Double = 0
    var ringOpacity: Double = 0
    var ringScale: Double = 1.6
}

/// The touch indicator, centred a little right of the middle of the row.
private struct TapRing: View {

    let opacity: Double
    let scale: Double

    var body: some View {
        GeometryReader { proxy in
            Circle()
                .fill(Color.black.opacity(0.28))
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .frame(width: 34, height: 34)
                .scaleEffect(scale)
                .opacity(opacity)
                .position(x: proxy.size.width * 0.62, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
    }
}

/// Glacier after the user returns: Secure DNS on.
private struct MiniGlacierConnected: View {

    let isActive: Bool
    let isDark: Bool

    @State private var checkScale: CGFloat = 0.4
    @State private var checkOpacity: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "Glacier")
                .font(.system(size: 34, weight: .bold))
                .padding(.horizontal, 22)
                .padding(.bottom, 20)

            VStack(spacing: 14) {
                Circle()
                    .fill(Color.greenHighlight)
                    .frame(width: 76, height: 76)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .scaleEffect(checkScale)
                    .opacity(checkOpacity)

                Text(NSLocalizedString("Secure DNS is on", comment: "DNS setup guide preview of Glacier with Secure DNS connected"))
                    .font(.system(size: 24, weight: .bold))

                Text(NSLocalizedString("Glacier is now filtering DNS on this device.", comment: "DNS setup guide preview of Glacier with Secure DNS connected"))
                    .font(.system(size: 17))
                    .foregroundColor(isDark ? .grey40 : .grey60)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(22)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(cardColor))
            .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Text(NSLocalizedString("Secure DNS", comment: "Secure DNS title"))
                    .font(.system(size: 18, weight: .medium))
                Spacer()
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.greenHighlight)
                        .frame(width: 8, height: 8)
                    Text(NSLocalizedString("Active", comment: "DNS setup guide preview of Glacier with Secure DNS connected"))
                        .font(.system(size: 16))
                        .foregroundColor(isDark ? .grey40 : .grey60)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(cardColor))
            .padding(.horizontal, 16)
            .padding(.top, 18)
        }
        .foregroundColor(isDark ? .white : .black)
        .padding(.top, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isDark ? Color.grey95 : Color.grey10)
        .onChange(of: isActive) { isActive in
            guard isActive else {
                checkScale = 0.4
                checkOpacity = 0
                return
            }
            withAnimation(.spring(response: 0.52, dampingFraction: 0.55).delay(0.36)) {
                checkScale = 1
                checkOpacity = 1
            }
        }
    }

    private var cardColor: Color {
        isDark ? .grey90 : .white
    }
}
