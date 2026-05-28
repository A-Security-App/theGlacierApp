//
//  PhoneNumberSelectionHomeViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 09/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 PhoneNumberSelectionHomeViewModel defines requirements for PhoneNumberSelectionHomeScreen view model.
 */
protocol PhoneNumberSelectionHomeViewModel: GlacierViewModelWithRootCoordinator {
    var availablePhoneNumbersToAdd: Int { get }
    var subHeaderText: String { get }
    
    init(rootCoordinator: any GlacierRootCoordinator)
    
    func presentPhoneNumberSelectionView()
    func skip()
}

/**
 PhoneNumberSelectionHomeVM provides data/state and business logic for PhoneNumberSelectionHomeScreen.
 */
final class PhoneNumberSelectionHomeVM: PhoneNumberSelectionHomeViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published private(set) var availablePhoneNumbersToAdd: Int = 0
    @Published private(set) var subHeaderText: String = ""
    
    let rootCoordinator: any GlacierRootCoordinator
    
    // MARK: - Initializer
    
    required init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        getAvailablePhoneNumbersToAdd()
    }
    
    // MARK: - Public methods
    
    func presentPhoneNumberSelectionView() {
        presentSheet(.phoneNumberSelection(false))
    }
    
    func skip() {
        UserDefaultsService.shared.set(true, for: \.didSkipPhoneNumberSelectionDuringOnboarding)
        connectDNSIfSetUpDuringOnboarding()
        setRootScreen(.main)
    }
    
    // MARK: - Private methods
    
    private func getAvailablePhoneNumbersToAdd() {
        let text = NSLocalizedString("You have %@ phone lines ready to use.", comment: "Phone number selection screen sub header")
        guard let activePlan = GlacierPhoneNumberSubscriptionPlan.activePlan else {
            subHeaderText = String(format: text, arguments: ["\(0)"])
            return
        }
        subHeaderText = String(format: text, arguments: ["\(activePlan.maxPhoneNumbers)"])
    }
}
