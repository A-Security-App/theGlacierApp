//
//  UserRegistrationViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 27/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI
import Amplify
import AWSCognitoAuthPlugin

/**
 UserRegistrationViewModel protocol defines requirements for view models that provides user registration related workflows.
 */
protocol UserRegistrationViewModel: UserAuthenticationViewModel, GlacierViewModel {
    var colorScheme: ColorScheme { get set }
    var passwordValidationChecklistStatus: AttributedString { get set }
    
    var isUserAccountCreated: Bool { get set }
    var isUserAccountConfirmationPending: Bool { get set }
    
    init(
        rootCoodinator: any GlacierRootCoordinator,
        authenticationService: GlacierAuthenticationService
    )
    
    @MainActor
    func resendAccountConfirmationEmail()

    @MainActor
    func confirmAccount(userName: String, confirmationCode: String)

    @MainActor
    func confirmAccountManually(confirmationCode: String)
}

/**
 UserRegistrationVM manages data/states and provide user account creation and confirmation related business logic.
 */
final class UserRegistrationVM: UserRegistrationViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var email: String = "" {
        didSet {
            let isValid = doesEmailMeetRequirements()
            isValidEmail = isValid
            withAnimation(.easeIn(duration: 0.2)) {
                if shouldShowPasswordTextField {
                    isContinueButtonEnabled = isValid && isValidPassword
                } else {
                    isContinueButtonEnabled = isValid
                }
            }
        }
    }
    
    @Published var isValidEmail: Bool = false
    
    @Published var shouldShowPasswordTextField: Bool = false
    @Published var password: String = "" {
        didSet {
            let validationChecklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: password)
            isValidPassword = validationChecklist.isValidPassword
            passwordValidationChecklistStatus = validationChecklist.validationChecklistStatus(for: colorScheme)
            withAnimation(.easeIn(duration: 0.2)) {
                isContinueButtonEnabled = isValidEmail && isValidPassword
            }
        }
    }
    @Published var passwordTextFieldState: GlacierTextFieldState = .idle
    @Published var isValidPassword: Bool = false
    @Published var passwordValidationChecklistStatus: AttributedString = AttributedString("")
    
    @Published var isContinueButtonEnabled: Bool = false
    @Published var userAccount: UserAccount?
    
    @Published var isUserAccountCreated: Bool = false
    @Published var isUserAccountConfirmationPending: Bool = true
    
    var colorScheme: ColorScheme = .dark {
        didSet {
            let validationChecklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: password)
            passwordValidationChecklistStatus = validationChecklist.validationChecklistStatus(for: colorScheme)
        }
    }
    
    // MARK: - Private properties
    
    let rootCoordinator: any GlacierRootCoordinator
    let authenticationService: GlacierAuthenticationService
    
    // MARK: - Initializer
    
    init(
        rootCoodinator: any GlacierRootCoordinator,
        authenticationService: GlacierAuthenticationService
    ) {
        self.rootCoordinator = rootCoodinator
        self.authenticationService = authenticationService
    }
    
    // MARK: - Public methods
    
    @MainActor
    func signInWithEmail() {
        switch (isValidEmail, isValidPassword) {
        case (true, true):
            UIApplication.shared.dismissKeyboard()
            createUserAccount()
            
        case (true, false):
            shouldShowPasswordTextField = true
            passwordValidationChecklistStatus = UserPasswordValidationChecklist.defaultState.validationChecklistStatus(for: colorScheme)
            isContinueButtonEnabled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.passwordTextFieldState = .active
            }
        default:
            break
        }
    }
    
    @MainActor
    func signInWith(_ authProvider: AuthProvider) {
        Task {
            let errorDescription = NSLocalizedString(
                "Something went wrong while creating your account. Please try again.",
                comment: "User registation screen account creation failure"
            )
            
            do {
                let result = try await authenticationService.signIn(with: authProvider)
                guard let authResult = result, authResult.isSignedIn else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                
                UserDefaultsService.shared.set(true, for: \.isUserAccountCreated)
                UserDefaultsService.shared.set(true, for: \.isUserAccountConfirmed)
                UserDefaultsService.shared.set(true, for: \.isUserLoggedIn)
                UserDefaultsService.shared.set(authProvider.authProviderName, for: \.hostedUIProvider)

                setRootScreen(.userOnboarding)
                dismissSheet()
            } catch {
                if let authError = error as? AWSCognitoAuthError, authError != .userCancelled {
                    presentAlertWith(title: .errorText, description: errorDescription)
                }
            }
        }
    }
    
    @MainActor
    func resendAccountConfirmationEmail() {
        Task {
            let errorDescription = NSLocalizedString(
                "Something went wrong while resending the confirmation email. Please try again.",
                comment: "User registration screen confirmation email failure"
            )
            
            do {
                guard let email: String = UserDefaultsService.shared.get(for: \.userEmail) else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }

                presentProgressIndicator()
                let _ = try await authenticationService.resendSignUpCode(for: email)
                dismissProgressIndicator()
                
                presentAlertWith(
                    title: .successText,
                    description: NSLocalizedString(
                        "We sent you email for account verification.",
                        comment: "User registration screen confirmation email success"
                    )
                )
            } catch {
                dismissProgressIndicator()
                presentAlertWith(title: .errorText, description: errorDescription)
            }
        }
    }
    
    @MainActor
    func confirmAccountManually(confirmationCode: String) {
        guard let email: String = UserDefaultsService.shared.get(for: \.userEmail) else {
            presentAlertWith(
                title: .errorText,
                description: NSLocalizedString(
                    "Something went wrong while confirming your account. Please try again.",
                    comment: "User account confirmation screen confirmation failure"
                )
            )
            return
        }
        confirmAccount(userName: email, confirmationCode: confirmationCode)
    }

    @MainActor
    func confirmAccount(userName: String, confirmationCode: String) {
        Task {
            let errorDescription = NSLocalizedString(
                "Something went wrong while confirming your account. Please try again.",
                comment: "User account confirmation screen confirmation failure"
            )
            
            do {
                presentProgressIndicator()
                let result = try await authenticationService.confirmSignUp(for: userName, confirmationCode: confirmationCode)
                dismissProgressIndicator()
                
                guard let authResult = result, authResult.isSignUpComplete else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                
                isUserAccountConfirmationPending = false
                UserDefaultsService.shared.set(true, for: \.isUserAccountConfirmed)
                
                autoLoginUserAfterAccountConfirmation()
            } catch {
                dismissProgressIndicator()
                if let authError = error as? AWSCognitoAuthError, authError != .userCancelled {
                    presentAlertWith(title: .errorText, description: errorDescription)
                }
            }
        }
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
    
    @MainActor
    private func createUserAccount() {
        Task {
            let errorDescription = NSLocalizedString(
                "Something went wrong while creating your account. Please try again.",
                comment: "User registation screen account creation failure"
            )
            
            do {
                presentProgressIndicator()
                let signupResult = try await authenticationService.createUserAccount(with: email, password: password)
                dismissProgressIndicator()
                
                guard let result = signupResult else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                
                switch result.nextStep {
                case .confirmUser:
                    isUserAccountCreated = true
                    isUserAccountConfirmationPending = true
                 
                    UserDefaultsService.shared.set(email, for: \.userEmail)
                    UserDefaultsService.shared.set(password, for: \.userPassword)
                    UserDefaultsService.shared.set(true, for: \.isUserAccountCreated)
                    UserDefaultsService.shared.set(false, for: \.isUserAccountConfirmed)
                    
                    setRootScreen(.userAccountConfirmation)
                    dismissSheet()
                case .done:
                    setRootScreen(.userOnboarding)
                    dismissSheet()
                default:
                    break
                }
            } catch let error as AuthError {
                dismissProgressIndicator()
                guard let authError = error.underlyingError as? AWSCognitoAuthError else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                
                if case .usernameExists = authError {
                    presentAlertWith(
                        title: .errorText,
                        description: NSLocalizedString(
                            "An account with this email is already registered. Please log in or reset your password.",
                            comment: "User registation screen account already exists error"
                        )
                    )
                } else if case .codeDelivery = authError {
                    presentAlertWith(
                        title: .errorText,
                        description: NSLocalizedString(
                            "Something went wrong while sending account confirmation email. Please try again.",
                            comment: "User registation screen account confirmation email delivery error"
                        )
                    )
                } else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                }
            } catch {
                dismissProgressIndicator()
                presentAlertWith(title: .errorText, description: errorDescription)
            }
        }
    }
    
    @MainActor
    private func autoLoginUserAfterAccountConfirmation() {
        guard let email: String = UserDefaultsService.shared.get(for: \.userEmail),
              let password: String = UserDefaultsService.shared.get(for: \.userPassword) else {
            return
        }
        
        Task {
            let errorDescription = NSLocalizedString(
                "Something went wrong while confirming your account. Please try again.",
                comment: "User account confirmation screen confirmation failure"
            )
            
            do {
                presentProgressIndicator()
                let signInResult = try await authenticationService.signIn(with: email, password: password)
                dismissProgressIndicator()
                
                guard let result = signInResult, result.isSignedIn else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                
                UserDefaultsService.shared.set("", for: \.userPassword)
                UserDefaultsService.shared.set(true, for: \.isUserLoggedIn)
                setRootScreen(.userOnboarding)
            } catch let error {
                dismissProgressIndicator()
                guard let authError = error as? AWSCognitoAuthError else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                
                if case .codeExpired = authError {
                    presentAlertWith(
                        title: .errorText,
                        description: NSLocalizedString(
                            "This account confirmation email has expired. Please request a new one.",
                            comment: "User account confirmation screen confirmation email expired error"
                        )
                    )
                } else if case .userNotConfirmed = authError {
                    presentAlertWith(title: .errorText, description: errorDescription)
                }
            }
        }
    }
}
