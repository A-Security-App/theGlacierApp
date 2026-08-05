//
//  NotificationSettingsScreen.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 NotificationSettingsScreen presents the app's notification options, each controlled
 by a toggle: the weekly Reboot Reminder and the Weekly Privacy Report email.
 */
struct NotificationSettingsScreen<ViewModel: NotificationSettingsViewModel & ObservableObject>: View {

    // MARK: - Private properties

    @SwiftUI.Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme

    @StateObject private var viewModel: ViewModel

    @State private var descriptionTextColor: Color?

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

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .center, spacing: 16) {
                        notificationBox(
                            title: viewModel.rebootReminderTitle,
                            description: viewModel.rebootReminderDescription,
                            isOn: $viewModel.isRebootReminderEnabled
                        )

                        notificationBox(
                            title: viewModel.weeklyPrivacyReportTitle,
                            description: viewModel.weeklyPrivacyReportDescription,
                            isOn: $viewModel.isWeeklyPrivacyReportEnabled
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 28)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    GlacierLabel(
                        text: NSLocalizedString("Notifications", comment: "Notifications settings screen title"),
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
        .presentationDetents([.fraction(0.75), .large])
        .onAppear {
            descriptionTextColor = glacierColorScheme.activeScheme == .light ? .grey60 : .grey40
        }
        .onChange(of: glacierColorScheme.activeScheme) { colorScheme in
            descriptionTextColor = colorScheme == .light ? .grey60 : .grey40
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func notificationBox(title: String, description: String, isOn: Binding<Bool>) -> some View {
        GlacierViewContainer {
            VStack(alignment: .leading, spacing: 40) {
                HStack(alignment: .center, spacing: 8) {
                    GlacierLabel(
                        text: title,
                        font: .bodyThick
                    )

                    Spacer()

                    Toggle(isOn: isOn, label: { Text("") })
                        .labelsHidden()
                        .fixedSize()
                        .toggleStyle(SwitchToggleStyle(tint: .green50))
                }

                GlacierLabel(
                    text: description,
                    font: .bodyRegular,
                    allowsVerticalGrowth: true,
                    customTextColor: $descriptionTextColor
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 60)
            }
        }
    }
}
