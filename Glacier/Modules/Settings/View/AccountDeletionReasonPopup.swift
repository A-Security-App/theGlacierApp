//
//  AccountDeletionReasonPopup.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 AccountDeletionReasonPopup asks why the user is deleting their account. It's shown after they
 confirm the deletion and before the delete request goes out, and matches the console's
 "Before you go" survey in the style of `GlacierPopup`.

 Answering is optional: **Delete Account** needs a reason, **Skip and delete** sends none.
 Only the close button and **Never mind** back out without deleting anything.
 */
struct AccountDeletionReasonPopup: View {

    // MARK: - Private properties

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var glacierColorScheme = GlacierColorScheme()
    @FocusState private var isDetailsFocused: Bool

    @State private var selectedReason: AccountDeletionReason?
    @State private var details: String = ""
    @State private var keyboardHeight: CGFloat = 0
    @State private var cardHeight: CGFloat = 0

    @State private var backgroundColor: Color = .grey10
    @State private var optionBackgroundColor: Color = .white
    @State private var optionBorderColor: Color = .grey20
    @State private var optionTextColor: Color? = .black
    @State private var secondaryTextColor: Color? = .grey60
    @State private var darkBackgroundOpacity: Double = 0.6
    @State private var isAppearing = false

    private let onDelete: (AccountDeletionFeedback?) -> Void
    private let onCancel: () -> Void

    /// The reasons in pairs, in the backend's order, for the two-column grid.
    private let reasonRows: [[AccountDeletionReason]] = {
        let reasons = AccountDeletionReason.allCases
        return stride(from: 0, to: reasons.count, by: 2).map {
            Array(reasons[$0..<min($0 + 2, reasons.count)])
        }
    }()

    // MARK: - Initializer

    /// - Parameters:
    ///   - onDelete: Called with the user's answer, or `nil` when they skipped the question.
    ///   - onCancel: Called when the user backs out. Nothing has been deleted.
    init(
        onDelete: @escaping (AccountDeletionFeedback?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    // MARK: - UI/UX

    var body: some View {
        ZStack {

            // Background
            Color.black.opacity(darkBackgroundOpacity)
                .ignoresSafeArea()
                .onTapGesture {
                    isDetailsFocused = false
                }

            // Sized to the card so it sits centred like any popup, and scrolls only when the card
            // doesn't fit (small screens, or the keyboard is up). Not `ViewThatFits` like the plan
            // paywall: raising the keyboard would swap in a second copy of the text editor and
            // drop its focus, which lowers the keyboard again.
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    card
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            cardHeight = height
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: cardHeight > 0 ? cardHeight : .infinity)
                .onChange(of: isDetailsFocused) { isFocused in
                    guard isFocused else { return }
                    withAnimation {
                        proxy.scrollTo(Self.detailsAnchor, anchor: .bottom)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 60)
            .padding(.bottom, max(keyboardHeight, 40))
        }
        .environmentObject(glacierColorScheme)
        .onAppear {
            isAppearing = true
            setupColors(for: glacierColorScheme.activeScheme)
        }
        .onDisappear {
            isAppearing = false
        }
        .onChange(of: colorScheme) { newScheme in
            glacierColorScheme.setScheme(newScheme)
        }
        .onChange(of: glacierColorScheme.activeScheme) { newScheme in
            guard isAppearing else { return }
            setupColors(for: newScheme)
        }
        // The overlay window ignores every safe area, keyboard included, so make room for it here.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = max(0, UIScreen.main.bounds.height - frame.minY)
            }
        }
    }

    // MARK: - Private views

    private static let detailsAnchor = "details"

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            GlacierLabel(
                text: NSLocalizedString("Before you go", comment: "Account deletion reason title"),
                font: .neueHassGroteskThickFont(ofSize: 26),
                customTextColor: .constant(.black)
            )
            .padding(.top, 16)

            GlacierLabel(
                text: NSLocalizedString(
                    "Why are you deleting your account? Your feedback helps us make Glacier better.",
                    comment: "Account deletion reason description"
                ),
                font: .bodyLarge,
                lineSpacing: 2,
                allowsVerticalGrowth: true,
                customTextColor: .constant(.grey60)
            )
            .padding(.top, 6)

            GlacierLabel(
                text: NSLocalizedString("Choose the main reason", comment: "Account deletion reason list header"),
                font: .bodyThick,
                customTextColor: .constant(.black)
            )
            .padding(.top, 20)

            // `Grid` rather than `LazyVGrid` so both cards in a row match the taller one.
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(reasonRows, id: \.first) { row in
                    GridRow {
                        ForEach(row) { reason in
                            reasonOption(reason)
                        }
                    }
                }
            }
            .padding(.top, 10)

            GlacierLabel(
                text: NSLocalizedString("Anything else you'd like us to know?", comment: "Account deletion details header"),
                font: .bodyThick,
                customTextColor: .constant(.black)
            )
            .padding(.top, 20)

            detailsEditor
                .padding(.top, 10)
                .id(Self.detailsAnchor)

            buttons
                .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 36)
                .fill(backgroundColor)
        )
    }

    private var header: some View {
        HStack(alignment: .top) {
            GlacierViewContainer(cornerRadius: 14, padding: 8, darkColor: .white) {
                GlacierImage(
                    name: .constant("glacier-logo"),
                    width: 28,
                    height: 28
                )
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.grey30))
            }
            .accessibilityLabel(NSLocalizedString("Close", comment: "Close button accessibility label"))
        }
    }

    private func reasonOption(_ reason: AccountDeletionReason) -> some View {
        let isSelected = selectedReason == reason
        return Button {
            selectedReason = reason
        } label: {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.highlight : Color.grey50, lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    if isSelected {
                        Circle()
                            .fill(Color.highlight)
                            .frame(width: 10, height: 10)
                    }
                }

                GlacierLabel(
                    text: reason.title,
                    font: .bodyRegular,
                    allowsVerticalGrowth: true,
                    customTextColor: $optionTextColor
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(optionBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.highlight : optionBorderColor, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var detailsEditor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(optionBackgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(optionBorderColor, lineWidth: 1)
                    )

                if details.isEmpty {
                    GlacierLabel(
                        text: NSLocalizedString("Optional feedback", comment: "Account deletion details placeholder"),
                        font: .bodyLarge,
                        customTextColor: .constant(.grey50)
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
                }

                TextEditor(text: $details)
                    .font(.bodyLarge)
                    .foregroundColor(optionTextColor)
                    .scrollContentBackground(.hidden)
                    .focused($isDetailsFocused)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .onChange(of: details) { newValue in
                        if newValue.count > AccountDeletionFeedback.maxDetailsLength {
                            details = String(newValue.prefix(AccountDeletionFeedback.maxDetailsLength))
                        }
                    }
            }
            .frame(height: 88)

            GlacierLabel(
                text: "\(details.count)/\(AccountDeletionFeedback.maxDetailsLength)",
                font: .bodySmall,
                customTextColor: .constant(.grey60)
            )
        }
    }

    private var buttons: some View {
        VStack(alignment: .center, spacing: 10) {
            GlacierButton(
                style: .secondary,
                title: NSLocalizedString("Delete Account", comment: "Account deletion reason submit button title"),
                height: 48,
                cornerRadius: 24,
                padding: 12,
                isEnabled: .constant(selectedReason != nil),
                action: {
                    guard let reason = selectedReason else { return }
                    isDetailsFocused = false
                    onDelete(AccountDeletionFeedback(reason: reason, details: details))
                }
            )

            GlacierButton(
                style: .tertiary,
                title: NSLocalizedString("Never mind", comment: "Account deletion reason cancel button title"),
                height: 48,
                cornerRadius: 24,
                padding: 12,
                action: onCancel
            )

            GlacierLabelButton(
                text: NSLocalizedString("Skip and delete", comment: "Account deletion reason skip button title"),
                font: .bodyRegular,
                customTextColor: $secondaryTextColor,
                action: {
                    isDetailsFocused = false
                    onDelete(nil)
                }
            )
            .padding(.top, 4)
        }
    }

    // MARK: - Private methods

    private func setupColors(for scheme: ColorScheme) {
        backgroundColor = scheme == .dark ? .grey40 : .grey10
        optionBackgroundColor = scheme == .dark ? .grey90 : .white
        optionBorderColor = scheme == .dark ? .grey70 : .grey20
        optionTextColor = scheme == .dark ? .white : .black
        secondaryTextColor = scheme == .dark ? .grey70 : .grey60
        darkBackgroundOpacity = scheme == .dark ? 0.4 : 0.6
    }
}
