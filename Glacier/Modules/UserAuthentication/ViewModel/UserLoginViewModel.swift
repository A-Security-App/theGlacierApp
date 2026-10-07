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

    /// The social provider the backend says the entered email belongs to.
    /// Set once the email step is done; the password field still shows,
    /// because an account can have a password and a linked provider.
    var linkedProvider: FederatedSignInProvider? { get }

    /// True after a password attempt failed for an email with no linked
    /// provider, so the Google and Apple buttons come back.
    var shouldShowFederatedSignInOptions: Bool { get }

    /// True when the email is linked to a provider and the user hasn't asked
    /// for the password: the screen offers only that provider, plus a link
    /// back to the password.
    var shouldShowLinkedProviderOnly: Bool { get }

    /// Brings the password field back for an email linked to a provider. An
    /// account created with a password and linked later still has one.
    @MainActor
    func usePasswordInstead()

    /// The social provider this device last signed in with, if any.
    var lastSignInProvider: FederatedSignInProvider? { get }
    
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
            if Self.normalized(email) != Self.normalized(oldValue) {
                linkedProvider = nil
                shouldShowFederatedSignInOptions = false
                prefersPasswordEntry = false
            }
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

    @Published private(set) var linkedProvider: FederatedSignInProvider?
    @Published private(set) var shouldShowFederatedSignInOptions: Bool = false
    @Published private(set) var prefersPasswordEntry: Bool = false
    let lastSignInProvider: FederatedSignInProvider?

    var shouldShowLinkedProviderOnly: Bool {
        shouldShowPasswordTextField && linkedProvider != nil && !prefersPasswordEntry
    }
    
    // MARK: - Private properties
    
    let rootCoordinator: any GlacierRootCoordinator
    var passwordResetCoordinator: any GlacierCoordinator
    let authenticationService: GlacierAuthenticationService
    private let signInMethodService: SignInMethodLookup
    private let pendingCredentialStore: PendingSignupCredentialAccess

    /// The lookup for the email it was started with. Reused while the email is
    /// unchanged, so a failed password attempt doesn't ask a second time.
    private var signInMethodLookup: (email: String, task: Task<SignInMethod, Never>)?
    
    // MARK: - Initializer
    
    convenience init(
        rootCoodinator: any GlacierRootCoordinator,
        passwordResetCoordinator: any GlacierCoordinator,
        authenticationService: GlacierAuthenticationService
    ) {
        self.init(
            rootCoodinator: rootCoodinator,
            passwordResetCoordinator: passwordResetCoordinator,
            authenticationService: authenticationService,
            signInMethodService: ConsoleSignInMethodService(),
            lastSignInProvider: LastSignInProviderStore.provider
        )
    }

    init(
        rootCoodinator: any GlacierRootCoordinator,
        passwordResetCoordinator: any GlacierCoordinator,
        authenticationService: GlacierAuthenticationService,
        signInMethodService: SignInMethodLookup,
        lastSignInProvider: FederatedSignInProvider?,
        pendingCredentialStore: PendingSignupCredentialAccess = .keychain
    ) {
        self.rootCoordinator = rootCoodinator
        self.passwordResetCoordinator = passwordResetCoordinator
        self.authenticationService = authenticationService
        self.signInMethodService = signInMethodService
        self.lastSignInProvider = lastSignInProvider
        self.pendingCredentialStore = pendingCredentialStore
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
            showLinkedProviderWhenKnown()
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
                if let provider = FederatedSignInProvider(authProvider) {
                    LastSignInProviderStore.record(provider)
                }

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
                if let provider = FederatedSignInProvider(authProvider),
                   let alert = PreSignUpRejection.federatedSignInAlert(for: error, provider: provider) {
                    presentAlertWith(title: alert.title, description: alert.message)
                    return
                }
                presentAlertWith(title: .errorText, description: errorDescription)
            }
        }
    }

    @MainActor
    func usePasswordInstead() {
        prefersPasswordEntry = true
        passwordTextFieldState = .active
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

                case .confirmSignUp:
                    await routeToAccountConfirmation()

                default:
                    dismissProgressIndicator()
                    presentAlertWith(title: .errorText, description: errorDescription)
                }
            } catch let error as AuthError {
                guard Self.isRejectedCredentials(error) else {
                    dismissProgressIndicator()
                    presentAlertWith(title: .errorText, description: error.errorDescription)
                    return
                }

                // Usually answered already: the lookup started when the email
                // step finished. If not, its own 5 s timeout bounds the wait.
                let method = await lookUpSignInMethod().value
                dismissProgressIndicator()
                applySignInMethod(method)
                let alert = Self.rejectedPasswordAlert(for: method, errorDescription: error.errorDescription)
                presentAlertWith(title: alert.title, description: alert.message)
            }
        }
    }

    /// The account was created but its email never verified. Cognito only says
    /// so once the password is right, and Amplify reports it as a sign-up step
    /// rather than an error. Hand over to the confirmation screen sign-up uses:
    /// it reads the email and the pending password from the same places, and
    /// signs the user in once the code is entered.
    @MainActor
    private func routeToAccountConfirmation() async {
        let email = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaultsService.shared.set(email, for: \.userEmail)
        pendingCredentialStore.save(password)
        UserDefaultsService.shared.set(true, for: \.isUserAccountCreated)
        UserDefaultsService.shared.set(false, for: \.isUserAccountConfirmed)

        // The code from sign-up has most likely expired. If this send fails,
        // the confirmation screen's own resend button is still there.
        _ = try? await authenticationService.resendSignUpCode(for: email)

        dismissProgressIndicator()
        setRootScreen(.userAccountConfirmation)
        dismissSheet()
    }

    /// Starts the lookup for the current email, or returns the one already
    /// running for it.
    private func lookUpSignInMethod() -> Task<SignInMethod, Never> {
        let email = Self.normalized(self.email)
        if let lookup = signInMethodLookup, lookup.email == email {
            return lookup.task
        }
        let service = signInMethodService
        let task = Task { await service.signInMethod(for: email) }
        signInMethodLookup = (email, task)
        return task
    }

    /// Runs in the background while the user types their password. Nothing
    /// waits on it; if it never answers, the screen just shows no notice.
    @MainActor
    private func showLinkedProviderWhenKnown() {
        let email = Self.normalized(self.email)
        let task = lookUpSignInMethod()
        Task {
            let method = await task.value
            // The email may have been edited while the lookup ran.
            guard Self.normalized(self.email) == email else { return }
            if case .federated(let provider) = method {
                // Someone already typing a password keeps the field.
                if !password.isEmpty {
                    prefersPasswordEntry = true
                } else {
                    UIApplication.shared.dismissKeyboard()
                }
                linkedProvider = provider
            }
        }
    }

    @MainActor
    private func applySignInMethod(_ method: SignInMethod) {
        switch method {
        case .federated(let provider):
            // They have just used the password field; don't take it away.
            prefersPasswordEntry = true
            linkedProvider = provider
            shouldShowFederatedSignInOptions = false
        case .password:
            shouldShowFederatedSignInOptions = true
        }
    }

    /// What to show when Cognito turns down the email and password. An email
    /// linked to a provider may still have a password of its own, so the
    /// message offers both.
    static func rejectedPasswordAlert(for method: SignInMethod, errorDescription: String) -> AuthAlertContent {
        switch method {
        case .federated(let provider):
            return AuthAlertContent(
                title: String(
                    format: NSLocalizedString(
                        "Linked to %@",
                        comment: "Alert title: wrong password for an email linked to Google or Apple. %@ is the provider name."
                    ),
                    provider.displayName
                ),
                message: String(
                    format: NSLocalizedString(
                        "This email is linked to %1$@. Sign in with %1$@, or check your password.",
                        comment: "User login screen wrong password for an email linked to Google or Apple. %1$@ is the provider name."
                    ),
                    provider.displayName
                )
            )
        case .password:
            let hint = NSLocalizedString(
                "If you signed up with Apple or Google, use those buttons instead.",
                comment: "User login screen wrong password hint pointing to the Google and Apple buttons"
            )
            return AuthAlertContent(
                title: NSLocalizedString(
                    "Couldn't log in",
                    comment: "Alert title: email and password rejected"
                ),
                message: "\(errorDescription)\n\n\(hint)"
            )
        }
    }

    /// A wrong password, or an email with no password account. Cognito reports
    /// both as `.notAuthorized` when user existence errors are hidden, and as
    /// `userNotFound` when they aren't.
    static func isRejectedCredentials(_ error: AuthError) -> Bool {
        if case .notAuthorized = error { return true }
        return error.underlyingError as? AWSCognitoAuthError == .userNotFound
    }

    private static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        // They sign in with a password now, so a reminder about a provider
        // would point them the wrong way.
        LastSignInProviderStore.clear()
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
