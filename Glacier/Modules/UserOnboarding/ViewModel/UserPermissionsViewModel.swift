//
//  UserPermissionsViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 09/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 UserPermissionsViewModel defines requirements for UserPermissionsScreen view models.
 */
protocol UserPermissionsViewModel: GlacierViewModelWithRootCoordinator, GlacierViewModelWithUserOnboardingCoordinator {
    init(rootCoordinator: any GlacierRootCoordinator, userOnboardingCoordinator: any GlacierCoordinator)
    
    func presentSuccessfulPurchaseAlert()
    func presentContactsAccessPrompt()
}

/**
 UserPermissionsVM provides data/state and business logic for UserPermissionsScreen.
 */
final class UserPermissionsVM: UserPermissionsViewModel, GlacierViewModel {
    
    // MARK: - Public properties
    
    let rootCoordinator: any GlacierRootCoordinator
    let userOnboardingCoordinator: any GlacierCoordinator
    
    // MARK: - Initializer
    
    required init(rootCoordinator: any GlacierRootCoordinator, userOnboardingCoordinator: any GlacierCoordinator) {
        self.rootCoordinator = rootCoordinator
        self.userOnboardingCoordinator = userOnboardingCoordinator
    }
    
    // MARK: - Public methods
    func presentSuccessfulPurchaseAlert() {
        presentAlertWith(
            title: NSLocalizedString("You're all set", comment: "Phone number plan purchase success title"),
            description: NSLocalizedString("Your purchase was successful.", comment: "Phone number plan purchase success description")
        )
    }
    
    func presentContactsAccessPrompt() {
        let userPermissionsManager = UserPermissionManager()
        userPermissionsManager.requestContactsPermission { [weak self] _ in
            userPermissionsManager.requestPushNotificationPermission { [weak self] _ in
                guard let strongSelf = self else { return }
                strongSelf.setOnboardingScreen(.phoneNumberSelectionHome)
            }
        }
    }
}
