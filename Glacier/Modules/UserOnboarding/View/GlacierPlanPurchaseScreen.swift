//
//  GlacierPlanPurchaseScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI
import StoreKit

/**
 GlacierPlanPurchaseScreen presents list of glacier plan which users can purchase.
 GlacierPlanPurchaseViewModel connects to StoreKit,
 - To fetch available glacier plans to purchase.
 - To purchase user selected glacier plan.
 
 After successful purchase of the plan, it sends `glacierPlanPurchaseSuccessful` notification to dismiss glacier plan purchase sheet view
 and take user to the next onboarding screen.
 */
struct GlacierPlanPurchaseScreen<ViewModel: GlacierPlanPurchaseViewModel & ObservableObject>: View {
    
    // MARK: - Private properties

    @SwiftUI.Environment(\.presentationMode) private var presentationMode
    @StateObject private var viewModel: ViewModel
    /// When `true` the screen is being shown mid-session because the base subscription lapsed.
    /// The close button and the onboarding-progress UserDefaults write are suppressed so that
    /// the user must subscribe (or restore) to dismiss the paywall.
    private let isLapsePaywall: Bool

    // MARK: - Initializer

    init(viewModel: ViewModel, isLapsePaywall: Bool = false) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.isLapsePaywall = isLapsePaywall
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        NavigationStack {
            ZStack {
                GlacierBackground()
                    .ignoresSafeArea()
                
                VStack(alignment: .center, spacing: 24) {
                    GlacierViewContainer(padding: 12) {
                        GlacierImage(
                            name: .constant("glacier-logo"),
                            width: 50,
                            height: 50,
                            shouldAdaptToColorSchemeChange: true
                        )
                    }
                    .padding(.top, 30)
                    
                    VStack(alignment: .center, spacing: 8) {
                        GlacierLabel(
                            text: NSLocalizedString("Select your plan", comment: "Glacier plan purchase screen header text"),
                            font: .headerTwo,
                            textAlignment: .center
                        )
                        
                        GlacierLabel(
                            text: NSLocalizedString("Instant privacy. Safe browsing.", comment: "Glacier plan purchase screen sub header text"),
                            font: .headerTwo,
                            textAlignment: .center,
                            customTextColor: .constant(.grey60)
                        )
                    }
                    
                    Spacer()
                    
                    GlacierPlanListView(
                        plans: viewModel.availablePlans,
                        selectedPlan: $viewModel.selectedPlan
                    )
                    
                    GlacierButton(
                        style: .primary,
                        title: NSLocalizedString("Get Glacier", comment: "Glacier plan purchase screen get glacier button title"),
                        isEnabled: $viewModel.isPurchaseButtonEnabled,
                        action: {
                            viewModel.purchasePlan()
                        }
                    )
                    
                    GlacierLabel(
                        text: NSLocalizedString(
                            "Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period. Manage or cancel anytime in Settings.",
                            comment: "Glacier plan purchase screen footer text"
                        ),
                        font: .bodySmall,
                        textAlignment: .leading,
                        customTextColor: .constant(.grey60)
                    )
                    .padding(.top, 16)
                    
                    HStack(alignment: .center, spacing: 24) {
                        GlacierLabelButton(
                            text: NSLocalizedString("Terms of Use", comment: "Terms of use button title"),
                            font: .bodySmall,
                            width: 80,
                            isUnderlined: true, action: {
                                viewModel.openTermsOfUseURL()
                            }
                        )
                        GlacierLabelButton(
                            text: NSLocalizedString("Privacy Policy", comment: "Privacy policy button title"),
                            font: .bodySmall,
                            width: 80,
                            isUnderlined: true, action: {
                                viewModel.openPrivacyPolicyURL()
                            }
                        )
                        Spacer()
                    }
                    .padding(.top, 16)
                }
                .padding(.horizontal, 16)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        viewModel.restorePurchase()
                    } label: {
                        GlacierLabel(
                            text: NSLocalizedString("Restore purchase", comment: "Glacier plan purchase screen restore purchase button title"),
                            font: .bodyThick
                        )
                    }
                }
                if !isLapsePaywall {
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
            .onFirstAppear {
                if !isLapsePaywall {
                    // Only track onboarding progress during the initial onboarding flow.
                    // When shown as the lapse paywall (mid-session), skip this write so that
                    // UserOnboardingCoordinator does not re-enter the purchase screen on next login.
                    UserDefaultsService.shared.set(Sheet.glacierPlanPurchase.name, for: \.inProgressUserOnboardingScreen)
                }
                viewModel.loadAvailablePlans()
            }
        }
    }
}

/**
 GlacierPlanListView displays list of Glacier plan to purchase and lets user
 select the desired plan.
 */
struct GlacierPlanListView: View {
    
    // MARK: - Private properties
    
    private let plans: [Product]
    @Binding private var selectedPlan: Product?
    
    // MARK: - Initializer
    
    init(plans: [Product], selectedPlan: Binding<Product?>) {
        self.plans = plans
        self._selectedPlan = selectedPlan
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            VStack(alignment: .center, spacing: 8) {
                ForEach(plans, id: \.id) { plan in
                    GlacierViewContainer(padding: 12) {
                        HStack(alignment: .center, spacing: 0) {
                            GlacierLabel(
                                text: plan.displayName,
                                font: .bodyThick
                            )
                            
                            GlacierViewContainer(cornerRadius: 8, padding: 12) {
                                GlacierLabel(
                                    text: plan.displayPrice,
                                    font: .bodySmallThick
                                )
                                .padding(.all, 10)
                                .background {
                                    GlacierBackground(cornerRadius: 8)
                                }
                            }
                            
                            Spacer()
                            
                            GlacierImage(
                                name: .constant(selectedPlan?.id == plan.id ? "radioButton-selected-icon" : "radioButton-deselected-icon"),
                                width: 16,
                                height: 16,
                                shouldAdaptToColorSchemeChange: true
                            )
                        }
                        .padding(.horizontal, 12)
                    }
                    .onTapGesture {
                        selectedPlan = plan
                    }
                }
            }
        }
    }
}
