//
//  ManagePhoneNumbersScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 27/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 ManagePhoneNumbersScreen provides UI/UX for phone number management features like,
 - Adding new phone number
 - Burning any existing phone number
 - Changing phone number display name
 - Copy phone number
 - Turning voicemail on/off for each number
 */
struct ManagePhoneNumbersScreen<ViewModel: ManagePhoneNumbersViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @StateObject private var viewModel: ViewModel
    
    @State private var isAppearing = false
    @State private var primaryTextColor: Color?
    @State private var secondaryTextColor: Color?
    @State private var activePhoneNumberBackgroundColor: Color = Color.grey90
    @State private var backgroundColor: Color = Color.grey95
    
    @State private var actionsSheetItem: PhoneNumberActionsSheetItem?
    @State private var actionsSheetHeight: CGFloat = 360
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
            
            VStack(alignment: .leading) {
                GlacierLineSeparator(lineThickness: 1)
                
                VStack(alignment: .leading, spacing: 16) {
                    
                    // Phone Numbers list
                    ForEach(viewModel.phoneNumbers, id: \.uniqueId) { number in
                        PhoneNumberMenuItemView(
                            number: number,
                            activePhoneNumber: nil,
                            shouldShowCopyNumberButton: true,
                            shouldShowMenuButton: true,
                            height: 80,
                            cornerRadius: 24,
                            horizontalPadding: 24,
                            verticalPadding: 16,
                            primaryTextColor: $primaryTextColor,
                            secondaryTextColor: $secondaryTextColor,
                            activePhoneNumberBackgroundColor: $activePhoneNumberBackgroundColor,
                            backgroundColor: $backgroundColor,
                            onCopyNumberButtonTap: {
                                viewModel.copyPhoneNumber(number)
                            },
                            onMenuButtonTap: { _ in
                                actionsSheetItem = PhoneNumberActionsSheetItem(number: number)
                            }
                        )
                    }
                    
                    if let activePlan = viewModel.activePhoneNumberPlan {
                        if viewModel.phoneNumbers.count < activePlan.maxPhoneNumbers {
                            
                            // Add phone number button
                            ZStack {
                                RoundedRectangle(cornerRadius: 24)
                                    .fill(backgroundColor)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 80)
                                
                                Button(
                                    action: {
                                        viewModel.presentPhoneNumberSelectionView()
                                    },
                                    label: {
                                        HStack(alignment: .center, spacing: 16) {
                                            GlacierImage(
                                                name: .constant("plus-icon"),
                                                width: 12,
                                                height: 12,
                                                shouldAdaptToColorSchemeChange: false,
                                                customTintColor: $primaryTextColor
                                            )
                                            
                                            GlacierLabel(
                                                text: NSLocalizedString("Add number", comment: "Phone number selection screen add number"),
                                                font: .bodyThick,
                                                customTextColor: $primaryTextColor
                                            )
                                            
                                            Spacer()
                                            
                                            ZStack {
                                                GlacierBackground(cornerRadius: 8)
                                                    .frame(width: 36, height: 32)
                                                
                                                GlacierLabel(
                                                    text: "\(viewModel.phoneNumbers.count)/\(viewModel.activePhoneNumberPlan?.maxPhoneNumbers ?? 0)",
                                                    font: .bodySmallThick,
                                                    customTextColor: $primaryTextColor
                                                )
                                            }
                                        }
                                        .padding(.vertical, 16)
                                        .padding(.horizontal, 24)
                                    }
                                )
                            }
                        } else if viewModel.phoneNumbers.count == activePlan.maxPhoneNumbers, viewModel.canUpgradeToHigherPhoneNumberPlan {
                            
                            // Upgrade phone number plan button
                            ZStack {
                                RoundedRectangle(cornerRadius: 24)
                                    .fill(backgroundColor)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 80)
                                
                                Button(
                                    action: {
                                        viewModel.presentPhoneNumberPlanPurchaseView()
                                    },
                                    label: {
                                        HStack(alignment: .center, spacing: 16) {
                                            GlacierImage(
                                                name: .constant("plus-icon"),
                                                width: 12,
                                                height: 12,
                                                shouldAdaptToColorSchemeChange: false,
                                                customTintColor: $primaryTextColor
                                            )
                                            
                                            GlacierLabel(
                                                text: NSLocalizedString("Upgrade to add phone lines", comment: "Phone number menu view upgrade plan"),
                                                font: .bodyThick,
                                                customTextColor: $primaryTextColor
                                            )
                                            
                                            Spacer()
                                        }
                                        .padding(.vertical, 16)
                                        .padding(.horizontal, 24)
                                    }
                                )
                            }
                        }
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .padding(.horizontal, 0)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        // `sheet(item:)` hands the number straight to the content. With `isPresented:`
        // the first open could build the content before the number was set → blank sheet.
        .sheet(item: $actionsSheetItem) { item in
            phoneNumberActionsSheet(for: item.number)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    actionsSheetHeight = height
                }
                .presentationDetents([.height(actionsSheetHeight)])
                .presentationDragIndicator(.visible)
                .presentationBackground(backgroundColor)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                GlacierLabel(
                    text: NSLocalizedString("Manage numbers", comment: "Manage phone number screen title"),
                    font: .headerTwo
                )
            }
        }
        .onFirstAppear {
            viewModel.initialize()
            viewModel.getUserPhoneNumbers()
            viewModel.refreshVoicemailSetting()
        }
        .onAppear {
            isAppearing = true
            setupColors(for: glacierColorScheme.activeScheme)
        }
        .onDisappear {
            isAppearing = false
        }
        .onChange(of: glacierColorScheme.activeScheme) { newScheme in
            guard isAppearing else { return }
            setupColors(for: newScheme)
        }
    }
    
    // MARK: - Subviews

    /// Half-height sheet with the actions for one number, matching the Android layout.
    private func phoneNumberActionsSheet(for phoneNumber: PhoneAccountModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                GlacierLabel(
                    text: phoneNumber.grdbRecord?.phoneNumber ?? "",
                    font: .bodyThick,
                    customTextColor: $primaryTextColor
                )

                if phoneNumber.hasValidDisplayName, let name = phoneNumber.grdbRecord?.displayName {
                    GlacierLabel(
                        text: name,
                        font: .bodySmall,
                        customTextColor: $secondaryTextColor
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 16)

            GlacierLineSeparator(lineThickness: 1)

            VStack(alignment: .leading, spacing: 0) {
                actionRow(icon: "copy-icon", title: NSLocalizedString("Copy number", comment: "Manage phone number screen copy phone number")) {
                    viewModel.copyPhoneNumber(phoneNumber)
                    actionsSheetItem = nil
                }

                actionRow(icon: "edit-icon", title: NSLocalizedString("Edit name", comment: "Mnage phone number screen edit phone number name")) {
                    dismissSheetThen { viewModel.presentEditPhoneNumberNamePrompt(for: phoneNumber) }
                }

                HStack(alignment: .center, spacing: 16) {
                    GlacierImage(
                        systemName: .constant("recordingtape"),
                        width: 20,
                        height: 20,
                        shouldAdaptToColorSchemeChange: false,
                        customTintColor: $secondaryTextColor
                    )

                    GlacierLabel(
                        text: NSLocalizedString("Voicemail", comment: "Manage phone numbers screen voicemail toggle title"),
                        font: .bodyThick,
                        customTextColor: $primaryTextColor
                    )

                    Spacer()

                    Toggle(
                        isOn: Binding(
                            get: { viewModel.isVoicemailEnabled(for: phoneNumber) },
                            set: { viewModel.setVoicemailEnabled($0, for: phoneNumber) }
                        ),
                        label: { Text("") }
                    )
                    .labelsHidden()
                    .fixedSize()
                    .toggleStyle(SwitchToggleStyle(tint: .green50))
                    .disabled(viewModel.isUpdatingVoicemail(for: phoneNumber))
                }
                .padding(.horizontal, 24)
                .frame(height: 48)

                actionRow(icon: "trash-icon", title: NSLocalizedString("Burn number", comment: "Mnage phone number screen burn phone number"), isDestructive: true) {
                    dismissSheetThen { viewModel.presentBurnNumberConfirmationPrompt(for: phoneNumber) }
                }

                actionRow(icon: "trash-icon", title: NSLocalizedString("Delete history", comment: "Mnage phone number screen delete call history"), isDestructive: true) {
                    dismissSheetThen { viewModel.presentDeleteHistoryConfirmationPrompt(for: phoneNumber) }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        // Report the rows' natural height so the sheet fits them instead of using half the screen.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func actionRow(icon: String, title: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                GlacierImage(
                    name: .constant(icon),
                    width: 20,
                    height: 20,
                    shouldAdaptToColorSchemeChange: false,
                    customTintColor: isDestructive ? .constant(.ember) : $secondaryTextColor
                )

                GlacierLabel(
                    text: title,
                    font: .bodyThick,
                    customTextColor: isDestructive ? .constant(.ember) : $primaryTextColor
                )

                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Prompts are presented in the overlay window, so close the sheet first to keep
    /// them (and the rename keyboard) from stacking on top of it.
    private func dismissSheetThen(_ action: @escaping @MainActor () -> Void) {
        actionsSheetItem = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            action()
        }
    }

    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        primaryTextColor = scheme == .dark ? .white : .black
        secondaryTextColor = scheme == .dark ? .grey60 : .grey50
        activePhoneNumberBackgroundColor = scheme == .dark ? .grey20 : .grey90
        backgroundColor = scheme == .dark ? .grey90 : .white
    }
}

/// Identifiable wrapper so the actions sheet can be driven by `sheet(item:)`.
private struct PhoneNumberActionsSheetItem: Identifiable {
    let number: PhoneAccountModel
    var id: String { number.uniqueId }
}
