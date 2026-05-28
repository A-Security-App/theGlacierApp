//
//  UserAuthenticationHomeViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 20/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 UserAuthenticationHomeViewModel defines view model requirements for user authentication view
 */
protocol UserAuthenticationHomeViewModel: GlacierViewModelWithRootCoordinator {
    func presentUserRegistrationScreen()
    func presentUserLoginScreen()
}

/**
 UserAuthenticationHomeVM provides data/states, business logic and navigation flows for user authentication view
 */
final class UserAuthenticationHomeVM: UserAuthenticationHomeViewModel, ObservableObject {
    
    // MARK: - Private properties
    
    let rootCoordinator: any GlacierRootCoordinator
    
    // MARK: - Initializer
    
    init(rootCoodinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoodinator
    }
    
    // MARK: - Public methods
    
    func presentUserRegistrationScreen() {
        presentSheet(.userRegistration)
    }
    
    func presentUserLoginScreen() {
        presentSheet(.userLogin)
    }
}
