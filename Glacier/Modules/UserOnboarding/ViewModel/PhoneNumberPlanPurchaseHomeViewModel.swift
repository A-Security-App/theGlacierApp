//
//  PhoneNumberPlanPurchaseHomeViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 11/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 PhoneNumberPlanPurchaseHomeViewModel defines requirements for PhoneNumberPlanPurchaseHomeScreen view model.
 */
protocol PhoneNumberPlanPurchaseHomeViewModel: GlacierViewModelWithRootCoordinator, GlacierViewModelWithUserOnboardingCoordinator {
    init(rootCoordinator: any GlacierRootCoordinator, userOnboardingCoordinator: any GlacierCoordinator)
    
    func presentPhoneNumberPlanPurchaseView()
    func presentUserPermissionsView()
    func skip()
}

/**
 PhoneNumberPlanPurchaseHomeVM provides data/state and business logic for PhoneNumberPlanPurchaseHomeScreen.
 */
final class PhoneNumberPlanPurchaseHomeVM: PhoneNumberPlanPurchaseHomeViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    let rootCoordinator: any GlacierRootCoordinator
    let userOnboardingCoordinator: any GlacierCoordinator
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator, userOnboardingCoordinator: any GlacierCoordinator) {
        self.rootCoordinator = rootCoordinator
        self.userOnboardingCoordinator = userOnboardingCoordinator
    }
    
    // MARK: - Public methods
    
    func presentPhoneNumberPlanPurchaseView() {
        // Onboarding routing already sends web subscribers past this screen (it gates on the
        // reconciled hasActivePhoneNumberSubscription, which counts the backend), but that gate
        // reads false when the account record isn't loaded yet at early launch. Re-check here so
        // the race can't land a web subscriber in the StoreKit sheet. "Skip for Now" remains
        // available, so the warning can't trap them on this screen.
        presentPhoneNumberPlanPurchase(orWarnManagedElsewhere: {
            self.presentSheet(.phoneNumberPlanPurchase)
        })
    }
    
    func presentUserPermissionsView() {
        dismissSheet()
        setOnboardingScreen(.userPermissions)
    }
    
    func skip() {
        UserDefaultsService.shared.set(true, for: \.didSkipPhoneNumberPurchaseDuringOnboarding)
        connectDNSIfSetUpDuringOnboarding()
        setRootScreen(.main)
    }
}
