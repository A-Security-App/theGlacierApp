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
        presentSheet(.phoneNumberPlanPurchase)
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
