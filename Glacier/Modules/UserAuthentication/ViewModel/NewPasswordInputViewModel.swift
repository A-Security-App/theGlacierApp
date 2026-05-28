//
//  NewPasswordInputViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 31/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 NewPasswordInputViewModel protocol defines requirements for view models for new passwords input screen for password reset.
 */
protocol NewPasswordInputViewModel: GlacierViewModelWithRootCoordinator {
    var colorScheme: ColorScheme { get set }
    
    var passwordOne: String { get set }
    var passwordOneTextFieldState: GlacierTextFieldState { get set }
    var passwordValidationChecklistStatus: AttributedString { get set }
    var isValidPasswordOne: Bool { get set }
    
    var passwordTwo: String { get set }
    var passwordTwoTextFieldState: GlacierTextFieldState { get set }
    var passwordTwoValidationError: String? { get set }
    
    var isContinueButtonEnabled: Bool { get set }
    
    init(
        rootCoodinator: any GlacierRootCoordinator,
        passwordResetCoordinator: any GlacierCoordinator,
        authenticationService: GlacierAuthenticationService,
        userName: String,
        confirmationCode: String,
        isPresentedFromLoginScreen: Bool
    )
    
    @MainActor
    func resetPassword()
}

/**
 NewPasswordInputVM provides and manages data/state and business logic for new passwords input, validation and integration with backend API.
 */
final class NewPasswordInputVM: NewPasswordInputViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var passwordOne: String = "" {
        didSet {
            guard !passwordOne.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            let validationChecklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: passwordOne)
            isValidPasswordOne = validationChecklist.isValidPassword
            passwordValidationChecklistStatus = validationChecklist.validationChecklistStatus(for: colorScheme)
            withAnimation(.easeIn(duration: 0.2)) {
                isContinueButtonEnabled = isValidPasswordOne && (passwordOne == passwordTwo)
            }
        }
    }
    @Published var passwordOneTextFieldState: GlacierTextFieldState = .idle
    @Published var isValidPasswordOne: Bool = false
    @Published var passwordValidationChecklistStatus: AttributedString = AttributedString("")
    
    @Published var passwordTwo: String = "" {
        didSet {
            let isPasswordTwoEmpty = passwordTwo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            withAnimation(.easeIn(duration: 0.2)) {
                isContinueButtonEnabled = isValidPasswordOne && !isPasswordTwoEmpty
            }
        }
    }
    @Published var passwordTwoTextFieldState: GlacierTextFieldState = .idle
    @Published var passwordTwoValidationError: String?
    
    @Published var isContinueButtonEnabled: Bool = false
    
    var colorScheme: ColorScheme = .dark {
        didSet {
            let validationChecklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: passwordOne)
            passwordValidationChecklistStatus = validationChecklist.validationChecklistStatus(for: colorScheme)
        }
    }
    
    // MARK: - Private properties
    
    let rootCoordinator: any GlacierRootCoordinator
    let passwordResetCoordinator: any GlacierCoordinator
    let authenticationService: GlacierAuthenticationService
    let userName: String
    let confirmationCode: String
    let isPresentedFromLoginScreen: Bool
    
    // MARK: - Initializer
    
    init(
        rootCoodinator: any GlacierRootCoordinator,
        passwordResetCoordinator: any GlacierCoordinator,
        authenticationService: GlacierAuthenticationService,
        userName: String,
        confirmationCode: String,
        isPresentedFromLoginScreen: Bool
    ) {
        self.rootCoordinator = rootCoodinator
        self.passwordResetCoordinator = passwordResetCoordinator
        self.authenticationService = authenticationService
        self.userName = userName
        self.confirmationCode = confirmationCode
        self.isPresentedFromLoginScreen = isPresentedFromLoginScreen
    }
    
    // MARK: - Public methods
    
    @MainActor
    func resetPassword() {
        let areBothPasswordsSame = passwordOne == passwordTwo
        guard areBothPasswordsSame else {
            withAnimation(.easeIn(duration: 0.2)) {
                passwordTwoValidationError = NSLocalizedString("Passwords don’t match", comment: "New password input screen passwords don't match")
            }
            return
        }
        
        withAnimation(.easeIn(duration: 0.2)) {
            passwordTwoValidationError = nil
        }
        
        Task {
            let errorDescription = NSLocalizedString(
                "Something went wrong while updating your password. Please try again.",
                comment: "New password input screen reset failure"
            )
            
            do {
                guard !confirmationCode.isEmpty, !userName.isEmpty else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                
                presentProgressIndicator()
                let didResetPassword = try await authenticationService.confirmResetPassword(for: userName, with: passwordTwo, confirmationCode: confirmationCode)
                dismissProgressIndicator()
                
                guard didResetPassword else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                
                presentSuccessfulPasswordUpdateAlert()
            } catch {
                dismissProgressIndicator()
                presentAlertWith(title: .errorText, description: errorDescription)
            }
        }
    }
    
    // MARK: - Private methods
    
    @MainActor
    private func presentSuccessfulPasswordUpdateAlert() {
        let configuration = PopupConfiguration(
            title: nil,
            description: NSLocalizedString(
                "Your password has been updated successfully. Please log in with your new password.",
                comment: "New password input screen password update successful alert"
            ),
            buttons: [
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Ok", comment: "Ok button title"),
                    onTap: {
                        self.dismissPopup()
                        self.presentNextScreen()
                    }
                )
            ]
        )
        presentPopup(with: configuration)
    }
    
    @MainActor
    private func presentNextScreen() {
        if isPresentedFromLoginScreen {
            // Let's take user back to login screen
            guard let coordinator = passwordResetCoordinator as? PasswordResetCoordinator else { return }
            coordinator.presentRootScreen()
        } else {
            // Let's inform password reset sheet view presenter screen to that it dismisses
            // password reset sheet view and take user to the user authentication screen
            NotificationCenter.default.post(
                name: .userSuccessfullyResetPassword,
                object: nil,
                userInfo: nil
            )
        }
    }
}
