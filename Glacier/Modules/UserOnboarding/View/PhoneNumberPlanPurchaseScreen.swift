//
//  PhoneNumberPlanPurchaseScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI
import StoreKit

/**
 PhoneNumberPlanPurchaseScreen presents list of phone number plans which users can purchase.
 PhoneNumberPlanPurchaseViewModel connects to StoreKit,
 - To fetch available phone number plans to purchase.
 - To purchase user selected plan.
 
 After successful purchase of the plan, it sends `phoneNumberPlanPurchaseSuccessful` notification to dismiss phone  number plan purchase
 sheet view and take user to the next onboarding screen.
 */
struct PhoneNumberPlanPurchaseScreen<ViewModel: GlacierPlanPurchaseViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @SwiftUI.Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    
    @EnvironmentObject private var userOnboardingCoordinator: UserOnboardingCoordinator
    @StateObject private var viewModel: ViewModel
    
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
                
                VStack(alignment: .center, spacing: 24) {
                    GlacierViewContainer(padding: 12) {
                        GlacierImage(
                            name: .constant("glacier-logo"),
                            width: 50,
                            height: 50,
                            shouldAdaptToColorSchemeChange: true
                        )
                    }
                    .padding(.top, 24)
                    
                    VStack(alignment: .center, spacing: 8) {
                        GlacierLabel(
                            text: NSLocalizedString("Select your monthly plan", comment: "Phone number plan purchase screen header text"),
                            font: .headerTwo,
                            textAlignment: .center
                        )
                        
                        GlacierLabel(
                            text: NSLocalizedString("Completely private phone calls.", comment: "Phone number plan purchase screen sub header text"),
                            font: .headerTwo,
                            textAlignment: .center,
                            customTextColor: .constant(.grey60)
                        )
                    }
                    
                    Spacer()
                    
                    PhoneNumberPlanListView(
                        plans: viewModel.availablePlans,
                        selectedPlan: $viewModel.selectedPlan
                    )
                    
                    GlacierButton(
                        style: .primary,
                        title: NSLocalizedString("Subscribe", comment: "Phone number plan purchase screen subscribe button title"),
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
                }
                .padding(.horizontal, 16)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        viewModel.restorePurchase()
                    } label: {
                        GlacierLabel(
                            text: NSLocalizedString("Restore", comment: "Phone number plan purchase screen restore purchase button title"),
                            font: .bodyThick
                        )
                    }
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
            .onFirstAppear {
                UserDefaultsService.shared.set(Sheet.phoneNumberPlanPurchase.name, for: \.inProgressUserOnboardingScreen)
                viewModel.loadAvailablePlans()
            }
        }
    }
}

/**
 PhoneNumberPlanListView displays list of phone number plans to purchase and lets user
 select the desired plan.
 */
struct PhoneNumberPlanListView: View {
    
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

