//
//  PasswordResetViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 30/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 PasswordResetViewModel protocol defines requirements for view models for password reset screen
 */
protocol PasswordResetViewModel: GlacierViewModelWithRootCoordinator {
    var email: String { get set }
    var isContinueButtonEnabled: Bool { get set }
    var isPresentedFromLoginScreen: Bool { get }
    var isLinkSent: Bool { get set }
    
    init(
        rootCoodinator: any GlacierRootCoordinator,
        passwordResetCoordinator: any GlacierCoordinator,
        authenticationService: GlacierAuthenticationService,
        isPresentedFromLoginScreen: Bool
    )
    
    @MainActor
    func sendPasswordResetLink()
    func presentPsswordInputScreen(with confirmationCode: String)
}

/**
 PasswordResetVM provides and manages data/state and business logic for user password reset related workflows.
 */
final class PasswordResetVM: PasswordResetViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var email: String = "" {
        didSet {
            let isValid = doesEmailMeetRequirements()
            withAnimation(.easeIn(duration: 0.2)) {
                isContinueButtonEnabled = isValid
            }
        }
    }
    
    @Published var isContinueButtonEnabled: Bool = false
    @Published var isPresentedFromLoginScreen: Bool = false
    @Published var isLinkSent: Bool = false
    
    // MARK: - Private properties
    
    let rootCoordinator: any GlacierRootCoordinator
    var passwordResetCoordinator: any GlacierCoordinator
    let authenticationService: GlacierAuthenticationService
    
    // MARK: - Initializer
    
    init(
        rootCoodinator: any GlacierRootCoordinator,
        passwordResetCoordinator: any GlacierCoordinator,
        authenticationService: GlacierAuthenticationService,
        isPresentedFromLoginScreen: Bool
    ) {
        self.rootCoordinator = rootCoodinator
        self.passwordResetCoordinator = passwordResetCoordinator
        self.authenticationService = authenticationService
        self.isPresentedFromLoginScreen = isPresentedFromLoginScreen
        
        getUserEmail()
    }
    
    // MARK: - Public methods
    
    @MainActor
    func sendPasswordResetLink() {
        Task {
            let errorDescription = NSLocalizedString(
                "Something went wrong while sending password reset email. Please try again.",
                comment: "Password reset screen email delivery failure"
            )
            
            do {
                guard !email.isEmpty else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                
                presentProgressIndicator()
                let result = try await authenticationService.resetPassword(for: email)
                dismissProgressIndicator()
                
                guard case .confirmResetPasswordWithCode(_, _) = result?.nextStep else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }

                isLinkSent = true
            } catch {
                dismissProgressIndicator()
                presentAlertWith(title: .errorText, description: errorDescription)
            }
        }
    }
    
    func presentPsswordInputScreen(with confirmationCode: String) {
        guard let coordinator = passwordResetCoordinator as? PasswordResetCoordinator else { return }
        coordinator.presentScreen(.newPasswordInput(userName: email, confirmationCode: confirmationCode))
    }
    
    // MARK: - Private methods
    
    private func doesEmailMeetRequirements() -> Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            return false
        }
        
        guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
            return false
        }
        return true
    }
    
    private func getUserEmail() {
        guard let glacierAccount = GlacierAccountModel.getGlacierAccount() else {
            return
        }
        email = glacierAccount.username
    }
}
