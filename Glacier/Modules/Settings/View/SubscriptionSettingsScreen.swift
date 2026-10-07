//
//  SubscriptionSettingsScreen.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 SubscriptionSettingsScreen shows the account's Glacier plan and phone lines, where each is billed,
 and the ways to change them that are available from this device.
 */
struct SubscriptionSettingsScreen<ViewModel: SubscriptionSettingsViewModel & ObservableObject>: View {

    // MARK: - Private properties

    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @StateObject private var viewModel: ViewModel

    @State private var secondaryTextColor: Color?

    // MARK: - Initializer

    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    // MARK: - UI/UX

    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                GlacierLineSeparator(lineThickness: 1)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader(NSLocalizedString("YOUR PLAN", comment: "Subscription settings plan section header"))
                            .padding(.top, 24)

                        valueRow(
                            title: NSLocalizedString("Glacier plan", comment: "Subscription settings Glacier plan row"),
                            value: viewModel.glacierPlanValue
                        )

                        valueRow(
                            title: NSLocalizedString("Phone lines", comment: "Subscription settings phone lines row"),
                            value: viewModel.phoneLinesValue
                        )

                        if let renews = viewModel.renewsValue {
                            valueRow(
                                title: NSLocalizedString("Renews", comment: "Subscription settings renewal date row"),
                                value: renews
                            )
                        }

                        ForEach(viewModel.notices) { notice in
                            GlacierViewContainer {
                                VStack(alignment: .leading, spacing: 4) {
                                    GlacierLabel(text: notice.title, font: .bodyThick)
                                    GlacierLabel(
                                        text: notice.message,
                                        font: .bodySmall,
                                        allowsVerticalGrowth: true,
                                        customTextColor: $secondaryTextColor
                                    )
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                            }
                        }

                        sectionHeader(NSLocalizedString("MANAGE", comment: "Subscription settings manage section header"))
                            .padding(.top, 8)

                        if viewModel.canRenewGlacierPlan {
                            navigationRow(NSLocalizedString("Renew your Glacier plan", comment: "Subscription settings renew base plan row")) {
                                viewModel.renewGlacierPlan()
                            }
                        }

                        if viewModel.canRenewPhoneLines {
                            navigationRow(NSLocalizedString("Renew your phone lines", comment: "Subscription settings renew phone lines row")) {
                                viewModel.renewPhoneLines()
                            }
                        }

                        if viewModel.canChangePhoneLinePlan {
                            navigationRow(NSLocalizedString("Change your phone-line plan", comment: "Subscription settings change phone plan row")) {
                                viewModel.changePhoneLinePlan()
                            }
                        }

                        if viewModel.canManageInAppStore {
                            navigationRow(NSLocalizedString("Change or cancel in the App Store", comment: "Subscription settings App Store manage row")) {
                                viewModel.manageInAppStore()
                            }
                        }

                        if viewModel.canManageOnWebsite {
                            navigationRow(NSLocalizedString("Manage on the Glacier website", comment: "Subscription settings website manage row")) {
                                viewModel.manageOnWebsite()
                            }
                        }

                        navigationRow(NSLocalizedString("Restore purchases", comment: "Subscription settings restore purchases row")) {
                            viewModel.restorePurchases()
                        }

                        GlacierLabel(
                            text: viewModel.footerText,
                            font: .bodySmall,
                            allowsVerticalGrowth: true,
                            customTextColor: $secondaryTextColor
                        )
                        .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .padding(.top, 8)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                GlacierLabel(
                    text: NSLocalizedString("Subscription", comment: "Subscription settings screen title"),
                    font: .headerTwo
                )
            }
        }
        .onFirstAppear {
            setupColors(for: glacierColorScheme.activeScheme)
            viewModel.refresh()
        }
        .onChange(of: glacierColorScheme.activeScheme) { colorScheme in
            setupColors(for: colorScheme)
        }
    }

    // MARK: - Private views

    private func sectionHeader(_ text: String) -> some View {
        GlacierLabel(text: text, font: .bodySmall, customTextColor: $secondaryTextColor)
            .padding(.horizontal, 16)
    }

    private func valueRow(title: String, value: String) -> some View {
        GlacierViewContainer {
            HStack(alignment: .center) {
                GlacierLabel(text: title, font: .bodyThick, lineLimit: 1)
                    .fixedSize()

                Spacer(minLength: 8)

                GlacierLabel(
                    text: value,
                    font: .bodySmall,
                    textAlignment: .trailing,
                    lineLimit: 1,
                    minimumScaleFactor: 0.7,
                    customTextColor: $secondaryTextColor
                )
            }
            .padding(.vertical, 8)
        }
    }

    private func navigationRow(_ title: String, action: @escaping () -> Void) -> some View {
        GlacierViewContainer {
            HStack(alignment: .center) {
                GlacierLabel(text: title, font: .bodyThick, textAlignment: .leading)

                Spacer()

                GlacierImage(
                    name: .constant("right-arrow-small-icon"),
                    width: 16,
                    height: 16,
                    shouldAdaptToColorSchemeChange: true
                )
            }
            .padding(.vertical, 6)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    // MARK: - Private methods

    private func setupColors(for scheme: ColorScheme) {
        secondaryTextColor = scheme == .light ? .grey60 : .grey40
    }
}
