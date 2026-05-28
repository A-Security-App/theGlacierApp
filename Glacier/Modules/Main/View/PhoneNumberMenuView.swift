//
//  PhoneNumberMenuView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 26/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 PhoneNumberMenuView presents UI/UX for popup view that opens when user taps on the active phone number under header view.
 - It presents list of user added phone numbers
 - Shows remaining phone numbers that users can add as per the phone number plan
 - Provides links for adding more phone number, upgrading phone number plan and phone number management.
 */
struct PhoneNumberMenuView<ViewModel: PhoneNumberMenuViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @StateObject private var viewModel: ViewModel
    
    @State private var isAppearing = false
    @State private var primaryTextColor: Color?
    @State private var secondaryTextColor: Color?
    @State private var activePhoneNumberBackgroundColor: Color = Color.grey90
    @State private var backgroundColor: Color = Color.grey95
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 8) {
                
                // Phone Numbers list
                ForEach(viewModel.phoneNumbers, id: \.uniqueId) { number in
                    PhoneNumberMenuItemView(
                        number: number,
                        activePhoneNumber: viewModel.activePhoneNumber,
                        primaryTextColor: $primaryTextColor,
                        secondaryTextColor: $secondaryTextColor,
                        activePhoneNumberBackgroundColor: $activePhoneNumberBackgroundColor,
                        backgroundColor: $backgroundColor
                    )
                    .onTapGesture {
                        viewModel.setActivePhoneNumber(number)
                    }
                }
                
                if let activePlan = viewModel.activePhoneNumberPlan {
                    if viewModel.phoneNumbers.count < activePlan.maxPhoneNumbers {
                        
                        // Add phone number button
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
                                }
                                .padding(.all, 16)
                            }
                        )
                        .padding(.top, 24)
                        
                    } else if viewModel.phoneNumbers.count == activePlan.maxPhoneNumbers, viewModel.canUpgradeToHigherPhoneNumberPlan {
                        
                        // Upgrade phone number plan button
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
                                }
                                .padding(.all, 16)
                            }
                        )
                        .padding(.top, 24)
                    }
                }
                
                // Manage phone numbers button and remaining phone number count
                HStack(alignment: .center) {
                    Button(
                        action: {
                            viewModel.presentManagePhoneNumbersView()
                        },
                        label: {
                            GlacierLabel(
                                text: NSLocalizedString("Manage numbers", comment: "Phone number menu view manage numbers"),
                                font: .bodyThick,
                                customTextColor: $primaryTextColor
                            )
                        }
                    )
                    
                    Spacer()
                    
                    GlacierLabel(
                        text: "\(viewModel.phoneNumbers.count)/\(viewModel.activePhoneNumberPlan?.maxPhoneNumbers ?? 0)",
                        font: .bodyThick,
                        customTextColor: $secondaryTextColor
                    )
                }
                .padding(.all, 16)
            }
            .padding(.all, 16)
        }
        .background(backgroundColor)
        .cornerRadius(32)
        .padding(.horizontal, 16)
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
        .onFirstAppear {
            viewModel.initialize()
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
        primaryTextColor = scheme == .dark ? .black : .white
        secondaryTextColor = scheme == .dark ? .grey60 : .grey50
        activePhoneNumberBackgroundColor = scheme == .dark ? .grey20 : .grey90
        backgroundColor = scheme == .dark ? .grey10 : .grey95
    }
}
