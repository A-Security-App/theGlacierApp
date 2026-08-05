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

    /// True once Cognito has accepted the password and is waiting on the code
    /// emailed by the `web-login-challenge` Lambda.
    var isAwaitingVerificationCode: Bool { get set }

    /// The masked address the code went to, as reported by Cognito.
    var verificationCodeDestination: String? { get set }
    
    init(
        rootCoodinator: any GlacierRootCoordinator,
        passwordResetCoordinator: any GlacierCoordinator,
        authenticationService: GlacierAuthenticationService
    )
    
    func presentPasswordResetScreen()

    @MainActor
    func submitVerificationCode(_ code: String)

    @MainActor
    func cancelVerificationCodeEntry()
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

    @Published var isAwaitingVerificationCode: Bool = false
    @Published var verificationCodeDestination: String?
    
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
                // Amplify wraps the real Cognito/service error inside `AuthError.underlyingError`,
                // so the previous `error as? AWSCognitoAuthError` cast always failed. Every social
                // sign-in failure (Amplify not yet configured, missing presentation anchor, Hosted UI
                // / cert-pinning failure, Cognito service error) was therefore silently swallowed —
                // no alert, no log, no navigation — which is why "Continue with Google" appeared to
                // do nothing. Log the raw error so the underlying cause is diagnosable, then surface
                // everything except a deliberate user cancellation.
                Log.auth.error("[GlacierAuth] Login signInWith(\(authProvider.authProviderName, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
                if cognitoAuthError(from: error) == .userCancelled {
                    return
                }
                presentAlertWith(title: .errorText, description: errorDescription)
            }
        }
    }

    func presentPasswordResetScreen() {
        guard let coordinator = passwordResetCoordinator as? PasswordResetCoordinator else { return }
        coordinator.presentScreen(.passwordReset)
    }

    @MainActor
    func submitVerificationCode(_ code: String) {
        Task {
            do {
                presentProgressIndicator()
                let challengeResult = try await authenticationService.confirmSignIn(challengeResponse: code)

                // `isSignedIn` is derived from `.done`, so this one check covers
                // both. Any other step means the challenge was not satisfied.
                guard let result = challengeResult,
                      case .done = result.nextStep else {
                    // A wrong code ends the Cognito challenge session, so there is
                    // nothing left to answer. The user has to sign in again to be
                    // sent a new one.
                    dismissProgressIndicator()
                    resetVerificationCodeEntry()
                    presentAlertWith(
                        title: .errorText,
                        description: NSLocalizedString(
                            "That code didn't work. Log in again to get a new one.",
                            comment: "User login screen wrong email code"
                        )
                    )
                    return
                }

                await completeSignIn()
            } catch let error as AuthError {
                dismissProgressIndicator()
                resetVerificationCodeEntry()
                presentAlertWith(title: .errorText, description: error.errorDescription)
            }
        }
    }

    @MainActor
    func cancelVerificationCodeEntry() {
        resetVerificationCodeEntry()
    }
    
    // MARK: - Private methods

    /// Back to the password step with the challenge cleared. The password goes
    /// too: the next attempt opens a new Cognito session and runs SRP again.
    @MainActor
    private func resetVerificationCodeEntry() {
        isAwaitingVerificationCode = false
        verificationCodeDestination = nil
        password = ""
    }

    @MainActor
    private func loginUser() {
        Task {
            let errorDescription = NSLocalizedString(
                "Something went wrong while logging you in. Please try again.",
                comment: "User login screen login failure"
            )

            do {
                presentProgressIndicator()
                let signInResult = try await authenticationService.signIn(
                    with: email,
                    password: password,
                    flow: .emailCodeChallenge
                )

                guard let result = signInResult else {
                    dismissProgressIndicator()
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }

                switch result.nextStep {
                case .done:
                    await completeSignIn()

                case .confirmSignInWithCustomChallenge(let additionalInfo):
                    // The Lambda reports the address it mailed, already masked,
                    // in the public challenge parameters. Amplify hands those
                    // back here so the screen can name it.
                    dismissProgressIndicator()
                    verificationCodeDestination = additionalInfo?["destination"]
                    isAwaitingVerificationCode = true

                default:
                    dismissProgressIndicator()
                    presentAlertWith(title: .errorText, description: errorDescription)
                }
            } catch let error as AuthError {
                dismissProgressIndicator()
                presentAlertWith(
                    title: .errorText,
                    description: error.errorDescription
                )
            }
        }
    }

    /// Shared by the sign-in that finishes on the password and the one that
    /// finishes on the emailed code.
    @MainActor
    private func completeSignIn() async {
        // fetchAttributes creates the GlacierAccount DB record on a fresh install
        // and sets the access token on TwilioBackendManager. Both are required
        // before resolveSubscriptionStatus — without them, getGlacierAccount()
        // returns nil and the backend subscription check exits immediately.
        // Keep the progress indicator visible throughout.
        await AWSAcctManager.sharedMgr().fetchAttributes()
        await GlacierApplicationDelegate.appDelegate.resolveSubscriptionStatus()
        dismissProgressIndicator()

        isAwaitingVerificationCode = false
        verificationCodeDestination = nil
        UserDefaultsService.shared.set(true, for: \.isUserLoggedIn)
        setRootScreen(UserOnboardingScreen.shouldShowUserOnboarding ? .userOnboarding : .main)
        dismissSheet()
    }

    /// Amplify wraps Cognito service errors inside `AuthError.underlyingError`;
    /// casting the thrown error directly to `AWSCognitoAuthError` always fails,
    /// which is how social sign-in failures ended up silently swallowed on the
    /// login path. Mirrors the same helper in `UserRegistrationVM`.
    private func cognitoAuthError(from error: Error) -> AWSCognitoAuthError? {
        if let authError = error as? AuthError {
            return authError.underlyingError as? AWSCognitoAuthError
        }
        return error as? AWSCognitoAuthError
    }
}
