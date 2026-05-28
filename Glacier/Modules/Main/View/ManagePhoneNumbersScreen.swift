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
    
    @State private var menuFrame: CGRect = .zero
    @State private var showMenu = false
    
    @State private var selectedPhoneNumber: PhoneAccountModel?
    
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
                            onMenuButtonTap: { frame in
                                selectedPhoneNumber = number
                                menuFrame = frame
                                withAnimation(.easeIn(duration: 0.3)) {
                                    showMenu = true
                                }
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
            
            // Phone number context menu
            if showMenu {
                Color.black.opacity(0.01)
                    .onTapGesture {
                        showMenu = false
                        selectedPhoneNumber = nil
                    }
                
                GlacierMenuView(menuItems: [
                    GlacierMenuItem(
                        icon: "edit-icon",
                        title: NSLocalizedString("Edit name", comment: "Mnage phone number screen edit phone number name"),
                        action: {
                            showMenu = false
                            guard let phoneNumber = selectedPhoneNumber else {
                                return
                            }
                            viewModel.presentEditPhoneNumberNamePrompt(for: phoneNumber)
                            selectedPhoneNumber = nil
                        }
                    ),
                    GlacierMenuItem(
                        icon: "trash-icon",
                        title: NSLocalizedString("Burn number", comment: "Mnage phone number screen burn phone number"),
                        action: {
                            showMenu = false
                            guard let phoneNumber = selectedPhoneNumber else {
                                return
                            }
                            viewModel.presentBurnNumberConfirmationPrompt(for: phoneNumber)
                            selectedPhoneNumber = nil
                        }
                    )
                ]
                )
                .position(x: menuFrame.minX - 40, y: menuFrame.minY - 60)
            }
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
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        primaryTextColor = scheme == .dark ? .white : .black
        secondaryTextColor = scheme == .dark ? .grey60 : .grey50
        activePhoneNumberBackgroundColor = scheme == .dark ? .grey20 : .grey90
        backgroundColor = scheme == .dark ? .grey90 : .white
    }
}
