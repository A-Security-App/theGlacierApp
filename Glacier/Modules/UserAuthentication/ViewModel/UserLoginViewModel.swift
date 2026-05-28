//
//  UserLoginViewModel.swift
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
 UserLoginViewModel protocol defines requirements for view models that provides user login related workflows.
 */
protocol UserLoginViewModel: UserAuthenticationViewModel {
    var emailValidationError: String? { get set }
    var passwordValidationError: String? { get set }
    var passwordResetCoordinator: any GlacierCoordinator { get set }
    
    init(
        rootCoodinator: any GlacierRootCoordinator,
        passwordResetCoordinator: any GlacierCoordinator,
        authenticationService: GlacierAuthenticationService
    )
    
    func presentPasswordResetScreen()
}

/**
 UserLoginVM manages data/states and provide user login related business logic.
 */
final class UserLoginVM: UserLoginViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var email: String = "" {
        didSet {
            isValidEmail = !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            withAnimation(.easeIn(duration: 0.2)) {
                if shouldShowPasswordTextField {
                    isContinueButtonEnabled = isValidEmail && isValidPassword
                } else {
                    isContinueButtonEnabled = isValidEmail
                }
            }
        }
    }
    
    @Published var isValidEmail: Bool = false
    @Published var emailValidationError: String?
    
    @Published var shouldShowPasswordTextField: Bool = false
    @Published var password: String = "" {
        didSet {
            isValidPassword = !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            withAnimation(.easeIn(duration: 0.2)) {
                isContinueButtonEnabled = isValidEmail && isValidPassword
            }
        }
    }
    @Published var passwordTextFieldState: GlacierTextFieldState = .idle
    @Published var isValidPassword: Bool = false
    @Published var passwordValidationError: String?
    
    @Published var isContinueButtonEnabled: Bool = false
    @Published var userAccount: UserAccount?
    
    // MARK: - Private properties
    
    let rootCoordinator: any GlacierRootCoordinator
    var passwordResetCoordinator: any GlacierCoordinator
    let authenticationService: GlacierAuthenticationService
    
    // MARK: - Initializer
    
    init(
        rootCoodinator: any GlacierRootCoordinator,
        passwordResetCoordinator: any GlacierCoordinator,
        authenticationService: GlacierAuthenticationService
    ) {
        self.rootCoordinator = rootCoodinator
        self.passwordResetCoordinator = passwordResetCoordinator
        self.authenticationService = authenticationService
    }
    
    // MARK: - Public methods
    
    @MainActor
    func signInWithEmail() {
        switch (isValidEmail, isValidPassword) {
        case (true, true):
            UIApplication.shared.dismissKeyboard()
            loginUser()
            
        case (true, false):
            shouldShowPasswordTextField = true
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
                "Something went wrong while logging you in. Please try again.",
                comment: "User login screen login failure"
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

                // fetchAttributes creates the GlacierAccount DB record on a fresh install
                // and sets the access token on TwilioBackendManager. Both are required
                // before resolveSubscriptionStatus — without them, getGlacierAccount()
                // returns nil and the backend subscription check exits immediately.
                await AWSAcctManager.sharedMgr().fetchAttributes()
                await GlacierApplicationDelegate.appDelegate.resolveSubscriptionStatus()

                setRootScreen(UserOnboardingScreen.shouldShowUserOnboarding ? .userOnboarding : .main)
                dismissSheet()
            } catch {
                if let authError = error as? AWSCognitoAuthError, authError != .userCancelled {
                    presentAlertWith(title: .errorText, description: errorDescription)
                }
            }
        }
    }
    
    func presentPasswordResetScreen() {
        guard let coordinator = passwordResetCoordinator as? PasswordResetCoordinator else { return }
        coordinator.presentScreen(.passwordReset)
    }
    
    // MARK: - Private methods
    
    @MainActor
    private func loginUser() {
        Task {
            let errorDescription = NSLocalizedString(
                "Something went wrong while logging you in. Please try again.",
                comment: "User login screen login failure"
            )

            do {
                presentProgressIndicator()
                let signInResult = try await authenticationService.signIn(with: email, password: password)

                guard let result = signInResult,
                      case .done = result.nextStep else {
                    dismissProgressIndicator()
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }

                // fetchAttributes creates the GlacierAccount DB record on a fresh install
                // and sets the access token on TwilioBackendManager. Both are required
                // before resolveSubscriptionStatus — without them, getGlacierAccount()
                // returns nil and the backend subscription check exits immediately.
                // Keep the progress indicator visible throughout.
                await AWSAcctManager.sharedMgr().fetchAttributes()
                await GlacierApplicationDelegate.appDelegate.resolveSubscriptionStatus()
                dismissProgressIndicator()

                UserDefaultsService.shared.set(true, for: \.isUserLoggedIn)
                setRootScreen(UserOnboardingScreen.shouldShowUserOnboarding ? .userOnboarding : .main)
                dismissSheet()
            } catch let error as AuthError {
                dismissProgressIndicator()
                presentAlertWith(
                    title: .errorText,
                    description: error.errorDescription
                )
            }
        }
    }
}
