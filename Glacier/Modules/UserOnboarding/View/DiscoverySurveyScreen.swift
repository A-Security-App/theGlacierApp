//
//  DiscoverySurveyScreen.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 DiscoverySurveyScreen is the last onboarding screen, however onboarding ends. It asks once per
 account how the user first heard about Glacier, with an optional follow-up for
 some answers. Answering is optional: **Skip** finishes onboarding just like **Submit**, and
 neither waits on the network.

 Its option cards follow `AccountDeletionReasonPopup`, the app's other one-question survey.
 */
struct DiscoverySurveyScreen<ViewModel: DiscoverySurveyViewModel>: View {

    // MARK: - Environment objects

    @EnvironmentObject var glacierColorScheme: GlacierColorScheme

    // MARK: - Private properties

    @StateObject private var viewModel: ViewModel
    @FocusState private var isDetailFocused: Bool
    @State private var isContentVisible = false

    private static var detailAnchor: String { "detail" }

    /// The channels in pairs, in the backend's order, for the two-column grid.
    private let channelRows: [[DiscoveryChannel]] = {
        let channels = DiscoveryChannel.allCases
        return stride(from: 0, to: channels.count, by: 2).map {
            Array(channels[$0..<min($0 + 2, channels.count)])
        }
    }()

    private var isDark: Bool { glacierColorScheme.activeScheme == .dark }
    private var optionBackgroundColor: Color { isDark ? .grey90 : .white }
    private var optionBorderColor: Color { isDark ? .grey70 : .grey20 }
    private var optionTextColor: Color { isDark ? .white : .black }

    // MARK: - Initializer

    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    // MARK: - UI/UX

    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
                .onTapGesture {
                    isDetailFocused = false
                }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    content
                        .padding(.top, 56)
                        .padding(.bottom, 24)
                        .padding(.horizontal, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: isDetailFocused) { isFocused in
                    guard isFocused else { return }
                    withAnimation {
                        proxy.scrollTo(Self.detailAnchor, anchor: .bottom)
                    }
                }
            }
            .opacity(isContentVisible ? 1 : 0)
        }
        .onFirstAppear {
            UserDefaultsService.shared.set(OnboardingScreen.discoverySurvey.name, for: \.inProgressUserOnboardingScreen)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                isContentVisible = true
            }
        }
    }

    // MARK: - Private views

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlacierLabel(
                text: NSLocalizedString("One last thing.", comment: "Discovery survey screen header"),
                font: .headerOne,
                customTextColor: .constant(.grey50)
            )

            GlacierLabel(
                text: NSLocalizedString("How did you first hear about Glacier?", comment: "Discovery survey question"),
                font: .headerOne,
                allowsVerticalGrowth: true
            )
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)

            GlacierLabel(
                text: NSLocalizedString(
                    "Optional. Your answer helps us understand how people discover Glacier.",
                    comment: "Discovery survey description"
                ),
                font: .bodyLarge,
                lineSpacing: 2,
                allowsVerticalGrowth: true,
                customTextColor: .constant(.grey60)
            )
            .padding(.top, 12)

            // `Grid` rather than `LazyVGrid` so both cards in a row match the taller one.
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(channelRows, id: \.first) { row in
                    GridRow {
                        ForEach(row) { channel in
                            channelOption(channel)
                        }
                    }
                }
            }
            .padding(.top, 24)

            if let prompt = viewModel.selectedChannel?.detailPrompt {
                detailEditor(prompt: prompt)
                    .padding(.top, 20)
                    .id(Self.detailAnchor)
            }

            buttons
                .padding(.top, 24)
        }
    }

    private func channelOption(_ channel: DiscoveryChannel) -> some View {
        let isSelected = viewModel.selectedChannel == channel
        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                viewModel.select(channel)
            }
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

                Text(channel.title)
                    .font(.bodyRegular)
                    .foregroundColor(optionTextColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
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

    private func detailEditor(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GlacierLabel(
                text: prompt,
                font: .bodyThick,
                allowsVerticalGrowth: true
            )

            TextField(
                "",
                text: $viewModel.detail,
                prompt: Text(NSLocalizedString("Optional", comment: "Discovery survey detail placeholder"))
                    .foregroundColor(.grey50),
                axis: .vertical
            )
            .font(.bodyLarge)
            .foregroundColor(optionTextColor)
            .lineLimit(1...4)
            .textInputAutocapitalization(.sentences)
            .submitLabel(.done)
            .focused($isDetailFocused)
            // A vertical text field puts Return into the text. Treat it as Done instead.
            .onChange(of: viewModel.detail) { newValue in
                guard newValue.contains(where: \.isNewline) else { return }
                viewModel.detail = newValue.filter { !$0.isNewline }
                isDetailFocused = false
            }
            .accessibilityLabel(prompt)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(optionBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isDetailFocused ? Color.highlight : optionBorderColor, lineWidth: 1)
            )

            GlacierLabel(
                text: "\(viewModel.detail.unicodeScalars.count)/\(DiscoverySurveyAnswer.maxDetailLength)",
                font: .bodySmall,
                customTextColor: .constant(.grey60)
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityHidden(true)
        }
    }

    private var buttons: some View {
        VStack(alignment: .center, spacing: 10) {
            GlacierButton(
                style: .secondary,
                title: NSLocalizedString("Submit", comment: "Discovery survey submit button title"),
                height: 56,
                isEnabled: .constant(viewModel.selectedChannel != nil),
                action: {
                    isDetailFocused = false
                    viewModel.submit()
                }
            )

            GlacierButton(
                style: .tertiary,
                title: NSLocalizedString("Skip", comment: "Discovery survey skip button title"),
                height: 56,
                action: {
                    isDetailFocused = false
                    viewModel.skip()
                }
            )
        }
    }
}
