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
    /// When `true` the screen is shown mid-session from the base-subscription *grace* nag. It is
    /// dismissible (the user is still within the grace window and protection is intact), but like the
    /// lapse paywall it must NOT record onboarding progress — otherwise the onboarding coordinator
    /// would re-enter the purchase screen on the next login.
    private let isGraceRenewal: Bool
    /// Account actions offered on the lapse paywall. The paywall covers Settings and can't be
    /// dismissed, so without these a lapsed user has no in-app way to cancel their subscription,
    /// sign out, or delete their account (App Review 5.1.1(v)) short of paying.
    private let lapseAccountActions: (any SettingsViewModel)?

    // MARK: - Initializer

    init(
        viewModel: ViewModel,
        isLapsePaywall: Bool = false,
        isGraceRenewal: Bool = false,
        lapseAccountActions: (any SettingsViewModel)? = nil
    ) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.isLapsePaywall = isLapsePaywall
        self.isGraceRenewal = isGraceRenewal
        self.lapseAccountActions = lapseAccountActions
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        NavigationStack {
            ZStack {
                GlacierBackground()
                    .ignoresSafeArea()
                
                // Lays out exactly as before when it fits; scrolls only if it doesn't (e.g. the lapse
                // paywall's extra account-actions row on an SE-sized screen). A plain ScrollView
                // would collapse the Spacer and change the layout everywhere.
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView {
                        content
                    }
                }
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
                if !isLapsePaywall && !isGraceRenewal {
                    // Only track onboarding progress during the initial onboarding flow.
                    // When shown mid-session (lapse paywall or grace-renewal paywall), skip this
                    // write so that UserOnboardingCoordinator does not re-enter the purchase screen
                    // on the next login.
                    UserDefaultsService.shared.set(Sheet.glacierPlanPurchase.name, for: \.inProgressUserOnboardingScreen)
                }
                viewModel.loadAvailablePlans()
            }
        }
    }

    // MARK: - Private views

    private var content: some View {
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
                    alignment: .leading,
                    width: 80,
                    isUnderlined: true, action: {
                        viewModel.openTermsOfUseURL()
                    }
                )
                GlacierLabelButton(
                    text: NSLocalizedString("Privacy Policy", comment: "Privacy policy button title"),
                    font: .bodySmall,
                    alignment: .leading,
                    width: 80,
                    isUnderlined: true, action: {
                        viewModel.openPrivacyPolicyURL()
                    }
                )
                Spacer()
            }
            .padding(.top, 16)

            if isLapsePaywall, let accountActions = lapseAccountActions {
                HStack(alignment: .center, spacing: 16) {
                    GlacierLabelButton(
                        text: NSLocalizedString("Manage Subscription", comment: "Lapse paywall manage subscription button title"),
                        font: .bodySmall,
                        alignment: .leading,
                        width: 130,
                        action: {
                            accountActions.manageSubscription()
                        }
                    )
                    GlacierLabelButton(
                        text: NSLocalizedString("Sign Out", comment: "Lapse paywall sign out button title"),
                        font: .bodySmall,
                        alignment: .leading,
                        width: 60,
                        action: {
                            accountActions.signOut()
                        }
                    )
                    GlacierLabelButton(
                        text: NSLocalizedString("Delete Account", comment: "Lapse paywall delete account button title"),
                        font: .bodySmall,
                        alignment: .leading,
                        width: 100,
                        customTextColor: .constant(.ember),
                        action: {
                            accountActions.deleteAccount()
                        }
                    )
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16)
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
