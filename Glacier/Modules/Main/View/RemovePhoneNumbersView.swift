//
//  RemovePhoneNumbersView.swift
//  Glacier
//
//  Presented when the user's phone-number subscription tier drops below the number of
//  phone numbers they currently hold (but they still have at least a 1-line subscription).
//  Lets the user choose which number(s) to remove rather than having one picked for them.
//  Removing a number permanently deletes its messages and call history.
//
//  This view is presented over the global overlay window by
//  PhoneSubscriptionLifecycleHandler and therefore owns its own GlacierColorScheme, mirroring
//  GlacierPopup / GlacierProgressIndicator (which are presented the same way). Its color scheme
//  and layout follow ManagePhoneNumbersScreen so it reads as a native phone-management screen.
//

import SwiftUI
import UIKit

/**
 RemovePhoneNumbersView shows the user their current phone numbers and asks them to select the
 one(s) to remove after a subscription downgrade. Tapping the remove button raises a final
 "Are you sure?" confirmation alert (a GlacierPopup) layered over the list, matching the
 burn-number confirmation flow — rather than a second full-screen step.
 */
struct RemovePhoneNumbersView: View {

    // MARK: - Input

    let accounts: [PhoneAccountModel]
    /// Exactly how many numbers the user must remove to get back within their plan limit.
    let removalCount: Int
    /// Called with the phone-number strings the user chose to remove.
    let onRemove: @MainActor ([String]) -> Void
    /// Called when the user defers the decision ("Decide later").
    let onDefer: @MainActor () -> Void

    // MARK: - State

    @StateObject private var glacierColorScheme = GlacierColorScheme()
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedNumbers: Set<String> = []
    @State private var showRemoveConfirmation = false
    @State private var isAppearing = false

    @State private var primaryTextColor: Color? = .black
    @State private var secondaryTextColor: Color? = .grey50
    @State private var rowBackgroundColor: Color = .white

    // MARK: - Derived

    /// The overlay window ignores safe area (see OverlayContainerView), so we inset content
    /// ourselves to clear the status bar / notch and the home indicator.
    private var safeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { !$0.safeAreaInsets.top.isZero }?
            .safeAreaInsets
            ?? UIEdgeInsets(top: 44, left: 0, bottom: 34, right: 0)
    }

    private var allowedRemaining: Int {
        max(0, accounts.count - removalCount)
    }

    private var isSelectionComplete: Bool {
        selectedNumbers.count == removalCount
    }

    private var selectedPhoneNumbers: [String] {
        accounts.compactMap { $0.grdbRecord?.phoneNumber }.filter { selectedNumbers.contains($0) }
    }

    // MARK: - UI/UX

    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()

            selectionContent
                .padding(.horizontal, 16)
                .padding(.top, safeAreaInsets.top + 16)
                .padding(.bottom, safeAreaInsets.bottom + 16)

            if showRemoveConfirmation {
                GlacierPopup(configuration: confirmationConfiguration)
                    .transition(.opacity)
            }
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
    }

    // MARK: - Selection

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(
                title: NSLocalizedString(
                    "Choose numbers to remove",
                    comment: "Downgrade number-removal screen title"
                ),
                subtitle: selectionDescription
            )

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    ForEach(accounts, id: \.uniqueId) { account in
                        selectableRow(for: account)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.top, 24)

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                GlacierButton(
                    style: .tertiary,
                    title: removeButtonTitle,
                    customTitleColor: .ember,
                    height: 56,
                    cornerRadius: 24,
                    isEnabled: .constant(isSelectionComplete),
                    action: {
                        withAnimation(.easeIn(duration: 0.2)) {
                            showRemoveConfirmation = true
                        }
                    }
                )

                GlacierButton(
                    style: .tertiary,
                    title: NSLocalizedString("Decide later", comment: "Downgrade number-removal defer button"),
                    height: 56,
                    cornerRadius: 24,
                    action: {
                        onDefer()
                    }
                )
            }
        }
    }

    private var selectionDescription: String {
        let format = NSLocalizedString(
            "Your plan now includes %d number(s). Select %d to remove. Removing a number permanently deletes its messages and call history.",
            comment: "Downgrade number-removal screen description"
        )
        return String(format: format, allowedRemaining, removalCount)
    }

    private var removeButtonTitle: String {
        if selectedNumbers.isEmpty {
            let format = NSLocalizedString(
                "Select %d to remove",
                comment: "Downgrade number-removal primary button — nothing selected yet"
            )
            return String(format: format, removalCount)
        }
        let format = NSLocalizedString(
            "Remove %d of %d",
            comment: "Downgrade number-removal primary button — showing selected vs required count"
        )
        return String(format: format, selectedNumbers.count, removalCount)
    }

    private func selectableRow(for account: PhoneAccountModel) -> some View {
        let number = account.grdbRecord?.phoneNumber
        let isSelected = number.map { selectedNumbers.contains($0) } ?? false

        return Button(
            action: { toggleSelection(for: account) },
            label: {
                ZStack(alignment: .trailing) {
                    // Background stays constant whether or not the row is selected — selection is
                    // shown only by the trailing checkbox (activePhoneNumber is intentionally nil).
                    PhoneNumberMenuItemView(
                        number: account,
                        activePhoneNumber: nil,
                        shouldShowCopyNumberButton: false,
                        shouldShowMenuButton: false,
                        height: 80,
                        cornerRadius: 24,
                        horizontalPadding: 24,
                        verticalPadding: 16,
                        primaryTextColor: $primaryTextColor,
                        secondaryTextColor: $secondaryTextColor,
                        activePhoneNumberBackgroundColor: $rowBackgroundColor,
                        backgroundColor: $rowBackgroundColor
                    )

                    checkbox(isSelected: isSelected)
                        .padding(.trailing, 24)
                }
            }
        )
        .buttonStyle(.plain)
    }

    private func checkbox(isSelected: Bool) -> some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(Color.highlight)
                    .frame(width: 24, height: 24)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Circle()
                    .stroke(Color.grey60, lineWidth: 1.5)
                    .frame(width: 24, height: 24)
            }
        }
    }

    // MARK: - Confirmation alert

    private var confirmationConfiguration: PopupConfiguration {
        let numbers = selectedPhoneNumbers
        let joined = numbers.joined(separator: ", ")
        let isSingle = numbers.count == 1

        let title = isSingle
            ? NSLocalizedString("Remove this number?", comment: "Downgrade number-removal confirm alert title — single")
            : NSLocalizedString("Remove these numbers?", comment: "Downgrade number-removal confirm alert title — multiple")

        let descriptionFormat = isSingle
            ? NSLocalizedString(
                "%@ will be permanently removed, including its messages and call history. This can't be undone.",
                comment: "Downgrade number-removal confirm alert description — single"
            )
            : NSLocalizedString(
                "%@ will be permanently removed, including their messages and call history. This can't be undone.",
                comment: "Downgrade number-removal confirm alert description — multiple"
            )

        return PopupConfiguration(
            title: title,
            description: String(format: descriptionFormat, joined),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Remove permanently", comment: "Downgrade number-removal confirm button"),
                    titleColor: .ember,
                    onTap: {
                        onRemove(numbers)
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                    onTap: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showRemoveConfirmation = false
                        }
                    }
                )
            ],
            buttonsAlignment: .vertical
        )
    }

    // MARK: - Shared header

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GlacierLabel(
                text: title,
                font: .headerTwo,
                customTextColor: $primaryTextColor
            )

            GlacierLabel(
                text: subtitle,
                font: .bodyRegular,
                allowsVerticalGrowth: true,
                customTextColor: $secondaryTextColor
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func toggleSelection(for account: PhoneAccountModel) {
        guard let number = account.grdbRecord?.phoneNumber else { return }
        if selectedNumbers.contains(number) {
            selectedNumbers.remove(number)
        } else {
            // Never allow selecting more than the number the user must remove.
            guard selectedNumbers.count < removalCount else { return }
            selectedNumbers.insert(number)
        }
    }

    // MARK: - Colors (mirrors ManagePhoneNumbersScreen)

    private func setupColors(for scheme: ColorScheme) {
        primaryTextColor = scheme == .dark ? .white : .black
        secondaryTextColor = scheme == .dark ? .grey60 : .grey50
        rowBackgroundColor = scheme == .dark ? .grey90 : .white
    }
}
