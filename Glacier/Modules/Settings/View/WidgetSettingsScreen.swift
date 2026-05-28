//
//  WidgetSettingsScreen.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

struct WidgetSettingsScreen<ViewModel: WidgetSettingsViewModel & ObservableObject>: View {

    // MARK: - Private properties

    @SwiftUI.Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme

    @StateObject private var viewModel: ViewModel

    @State private var sectionHeaderColor: Color?

    // MARK: - Initializer

    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    // MARK: - UI/UX

    var body: some View {
        NavigationStack {
            ZStack {
                GlacierBackground()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        WidgetPreviewCard()
                            .frame(maxWidth: .infinity)

                        GlacierLabel(
                            text: NSLocalizedString(
                                "Check your security status and VPN connection at a glance from your Home Screen.",
                                comment: "Widget settings screen description"
                            ),
                            font: .bodyRegular
                        )

                        VStack(alignment: .leading, spacing: 12) {
                            GlacierLabel(
                                text: NSLocalizedString(
                                    "How to add the Glacier widget",
                                    comment: "Widget settings section header"
                                ),
                                font: .bodyThick,
                                customTextColor: $sectionHeaderColor
                            )

                            GlacierViewContainer {
                                VStack(alignment: .leading, spacing: 20) {
                                    stepRow(
                                        number: 1,
                                        content: Text(NSLocalizedString(
                                            "Press and hold anywhere on your Home Screen",
                                            comment: "Widget settings step 1"
                                        ))
                                        .font(.bodyRegular)
                                    )

                                    stepRow(
                                        number: 2,
                                        content: Text(NSLocalizedString("Press the ", comment: "Widget step 2a"))
                                            .font(.bodyRegular)
                                        + Text(NSLocalizedString("Edit", comment: "Widget step 2b"))
                                            .font(.bodyThick)
                                        + Text(NSLocalizedString(" button, then select ", comment: "Widget step 2c"))
                                            .font(.bodyRegular)
                                        + Text(NSLocalizedString("Add Widget", comment: "Widget step 2d"))
                                            .font(.bodyThick)
                                    )

                                    stepRow(
                                        number: 3,
                                        content: Text(NSLocalizedString("Select or search for ", comment: "Widget step 3a"))
                                            .font(.bodyRegular)
                                        + Text(NSLocalizedString("Glacier", comment: "Widget step 3b"))
                                            .font(.bodyThick)
                                    )

                                    stepRow(
                                        number: 4,
                                        content: Text(NSLocalizedString("Choose your preferred widget, then press ", comment: "Widget step 4a"))
                                            .font(.bodyRegular)
                                        + Text(NSLocalizedString("Add Widget", comment: "Widget step 4b"))
                                            .font(.bodyThick)
                                        + Text(NSLocalizedString(" to confirm", comment: "Widget step 4c"))
                                            .font(.bodyRegular)
                                    )
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 28)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    GlacierLabel(
                        text: NSLocalizedString("Widget", comment: "Widget settings screen title"),
                        font: .headerTwo
                    )
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        GlacierImage(
                            name: .constant("cross-icon"),
                            contentMode: .fit,
                            width: 24,
                            height: 24,
                            shouldAdaptToColorSchemeChange: true
                        )
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            sectionHeaderColor = glacierColorScheme.activeScheme == .light ? .grey60 : .grey40
        }
        .onChange(of: glacierColorScheme.activeScheme) { colorScheme in
            sectionHeaderColor = colorScheme == .light ? .grey60 : .grey40
        }
    }

    // MARK: - Private helpers

    private func stepRow(number: Int, content: Text) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .font(.bodyThick)
                .foregroundColor(.primary)
                .frame(width: 20, alignment: .leading)

            content
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Widget preview mockup

private struct WidgetPreviewCard: View {

    var body: some View {
        // Phone screen frame
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(red: 0.13, green: 0.12, blue: 0.14))

            VStack(spacing: 0) {
                // Home screen area with widget
                widgetMock
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 20)

                // Dock row — four placeholder app icons
                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .frame(height: 220)
    }

    private var widgetMock: some View {
        ZStack(alignment: .bottomLeading) {
            // Gradient matches the actual widget
            LinearGradient(
                colors: [
                    Color(red: 0.847, green: 0.863, blue: 0.976),
                    Color(red: 0.776, green: 0.792, blue: 0.949),
                    Color(red: 0.627, green: 0.651, blue: 0.894)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 0) {
                Text("All clear.\nNo issues found.")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.black)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 140, alignment: .leading)

                Spacer()

                HStack(spacing: 6) {
                    Text("Connected")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)

                    badge("DNS")
                    badge("VPN")
                }
            }
            .padding(12)
        }
        .frame(height: 110)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.106, green: 0.098, blue: 0.110))
            )
    }
}
