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
import SAMKeychain

/**
 UserRegistrationViewModel protocol defines requirements for view models that provides user registration related workflows.
 */
protocol UserRegistrationViewModel: UserAuthenticationViewModel, GlacierViewModel {
    var colorScheme: ColorScheme { get set }
    var passwordValidationChecklistStatus: AttributedString { get set }
    
    var isUserAccountCreated: Bool { get set }
    var isUserAccountConfirmationPending: Bool { get set }

    /// Set when the email already uses Google or Apple, so the screen can
    /// offer that provider's button.
    var linkedProvider: FederatedSignInProvider? { get }

    /// A password sign-up for an email that uses a provider is always refused,
    /// so the password step is replaced by that provider until the email
    /// changes.
    var shouldShowLinkedProviderOnly: Bool { get }
    
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
            if Self.normalized(email) != Self.normalized(oldValue) {
                linkedProvider = nil
            }
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
    @Published private(set) var linkedProvider: FederatedSignInProvider?

    var shouldShowLinkedProviderOnly: Bool {
        shouldShowPasswordTextField && linkedProvider != nil
    }
    
    var colorScheme: ColorScheme = .dark {
        didSet {
            let validationChecklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: password)
            passwordValidationChecklistStatus = validationChecklist.validationChecklistStatus(for: colorScheme)
        }
    }
    
    // MARK: - Private properties
    
    let rootCoordinator: any GlacierRootCoordinator
    let authenticationService: GlacierAuthenticationService
    private let postAuthenticationBootstrap: @MainActor () async -> Void
    private let registrationProgressChanged: @MainActor (Bool) -> Void
    private let pendingCredentialStore: PendingSignupCredentialAccess
    private let signInMethodService: SignInMethodLookup
    /// The lookup for the email it was started with, reused if the sign-up is
    /// later refused.
    private var signInMethodLookup: (email: String, task: Task<SignInMethod, Never>)?
    private var isRegistrationProgressPresented = false
    /// Prevents duplicate ConfirmSignUp submissions; see confirmAccount(userName:confirmationCode:).
    private var isConfirmationInProgress = false
    
    // MARK: - Initializer
    
    init(
        rootCoodinator: any GlacierRootCoordinator,
        authenticationService: GlacierAuthenticationService
    ) {
        self.rootCoordinator = rootCoodinator
        self.authenticationService = authenticationService
        self.postAuthenticationBootstrap = {
            // fetchAttributes creates the GlacierAccount DB record and installs
            // the backend access token required by the subscription lookup.
            await AWSAcctManager.sharedMgr().fetchAttributes()
            await GlacierApplicationDelegate.appDelegate.resolveSubscriptionStatus()
        }
        self.registrationProgressChanged = { _ in }
        self.pendingCredentialStore = .keychain
        self.signInMethodService = ConsoleSignInMethodService()
    }

    /// Injectable for tests so registration routing can be held until account
    /// hydration and backend subscription reconciliation have both completed.
    /// `pendingCredentialStore` is also injectable because the real store uses a
    /// shared-access-group Keychain that is unavailable under the unit-test run
    /// (`CODE_SIGNING_ALLOWED=NO` applies no entitlements), so tests supply an
    /// in-memory implementation instead.
    init(
        rootCoodinator: any GlacierRootCoordinator,
        authenticationService: GlacierAuthenticationService,
        postAuthenticationBootstrap: @escaping @MainActor () async -> Void,
        registrationProgressChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        pendingCredentialStore: PendingSignupCredentialAccess = .keychain,
        signInMethodService: SignInMethodLookup = ConsoleSignInMethodService()
    ) {
        self.rootCoordinator = rootCoodinator
        self.authenticationService = authenticationService
        self.postAuthenticationBootstrap = postAuthenticationBootstrap
        self.registrationProgressChanged = registrationProgressChanged
        self.pendingCredentialStore = pendingCredentialStore
        self.signInMethodService = signInMethodService
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
            showLinkedProviderWhenKnown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.passwordTextFieldState = .active
            }
        default:
            break
        }
    }

    /// Runs in the background while the user picks a password. Nothing waits on
    /// it; if it never answers, the screen just shows no notice.
    @MainActor
    private func showLinkedProviderWhenKnown() {
        let email = Self.normalized(self.email)
        let task = lookUpSignInMethod()
        Task {
            let method = await task.value
            // The email may have been edited while the lookup ran.
            guard Self.normalized(self.email) == email else { return }
            if case .federated(let provider) = method {
                UIApplication.shared.dismissKeyboard()
                linkedProvider = provider
            }
        }
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

    private static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    
    @MainActor
    func signInWith(_ authProvider: AuthProvider) {
        Task {
            let errorDescription = NSLocalizedString(
                "Something went wrong while creating your account. Please try again.",
                comment: "User registation screen account creation failure"
            )
            
            do {
                // No progress overlay while the provider's sign-in sheet is up. The overlay lives in
                // a window above the app's, and Google's sign-in page is presented in the app's own
                // window, so the spinner would cover the page and swallow every tap: the user could
                // never enter an email and sign-in would never return. It's shown from here, once
                // the sheet has closed, to cover the slow post-sign-in bootstrap.
                let result = try await authenticationService.signIn(with: authProvider)
                guard let authResult = result, authResult.isSignedIn else {
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                presentRegistrationProgress()
                
                UserDefaultsService.shared.set(true, for: \.isUserAccountCreated)
                UserDefaultsService.shared.set(true, for: \.isUserAccountConfirmed)
                UserDefaultsService.shared.set(true, for: \.isUserLoggedIn)
                UserDefaultsService.shared.set(authProvider.authProviderName, for: \.hostedUIProvider)
                if let provider = FederatedSignInProvider(authProvider) {
                    LastSignInProviderStore.record(provider)
                }

                await postAuthenticationBootstrap()
                dismissRegistrationProgress()
                setRootScreen(.userOnboarding)
                dismissSheet()
            } catch {
                dismissRegistrationProgress()
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
        // The verification deep link sets the OTP field AND calls this method
        // directly, and the OTP field auto-submits at 6 digits — without this
        // guard a single email-link tap fires two ConfirmSignUp requests, and
        // the second one fails with "User cannot be confirmed. Current status
        // is CONFIRMED", surfacing an error for an account that just verified.
        guard !isConfirmationInProgress else { return }
        isConfirmationInProgress = true
        
        Task {
            let errorDescription = NSLocalizedString(
                "Something went wrong while confirming your account. Please try again.",
                comment: "User account confirmation screen confirmation failure"
            )
            
            do {
                presentRegistrationProgress()
                let result = try await authenticationService.confirmSignUp(for: userName, confirmationCode: confirmationCode)
                guard let authResult = result, authResult.isSignUpComplete else {
                    dismissRegistrationProgress()
                    isConfirmationInProgress = false
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                
                isUserAccountConfirmationPending = false
                UserDefaultsService.shared.set(true, for: \.isUserAccountConfirmed)
                
                autoLoginUserAfterAccountConfirmation()
            } catch {
                isConfirmationInProgress = false
                
                // ConfirmSignUp on an account that is already CONFIRMED throws
                // .notAuthorized. The account is verified — treat it as success
                // and move the user forward instead of stranding them on a
                // screen where every retry fails with the same error.
                if let authError = error as? AuthError, case .notAuthorized = authError {
                    isUserAccountConfirmationPending = false
                    UserDefaultsService.shared.set(true, for: \.isUserAccountConfirmed)
                    autoLoginUserAfterAccountConfirmation()
                    return
                }

                dismissRegistrationProgress()
                
                if cognitoAuthError(from: error) == .userCancelled {
                    return
                }
                presentAlertWith(title: .errorText, description: errorDescription)
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
    
    /// The `pre-signup-link` Lambda turned the sign-up down. Its usual reason
    /// is that the email already uses Google or Apple; the sign-in method
    /// lookup confirms which, so the message can be translated and the screen
    /// can offer that provider. Anything else shows the Lambda's own reason.
    @MainActor
    private func presentPreSignUpRejection(_ error: AuthError) async {
        let method = await lookUpSignInMethod().value
        dismissRegistrationProgress()

        if case .federated(let provider) = method {
            linkedProvider = provider
            let alert = PreSignUpRejection.existingProviderAlert(for: provider)
            presentAlertWith(title: alert.title, description: alert.message)
            return
        }
        presentAlertWith(
            title: PreSignUpRejection.signUpRefusedTitle,
            description: PreSignUpRejection.reason(from: error) ?? NSLocalizedString(
                "Something went wrong while creating your account. Please try again.",
                comment: "User registation screen account creation failure"
            )
        )
    }

    @MainActor
    private func createUserAccount() {
        Task {
            let errorDescription = NSLocalizedString(
                "Something went wrong while creating your account. Please try again.",
                comment: "User registation screen account creation failure"
            )
            
            do {
                presentRegistrationProgress()
                let signupResult = try await authenticationService.createUserAccount(with: email, password: password)
                
                guard let result = signupResult else {
                    dismissRegistrationProgress()
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                
                switch result.nextStep {
                case .confirmUser:
                    isUserAccountCreated = true
                    isUserAccountConfirmationPending = true
                 
                    UserDefaultsService.shared.set(email, for: \.userEmail)
                    pendingCredentialStore.save(password)
                    UserDefaultsService.shared.set(true, for: \.isUserAccountCreated)
                    UserDefaultsService.shared.set(false, for: \.isUserAccountConfirmed)
                    
                    dismissRegistrationProgress()
                    setRootScreen(.userAccountConfirmation)
                    dismissSheet()
                case .done:
                    let signInResult = try? await authenticationService.signIn(
                        with: email,
                        password: password,
                        flow: .passwordOnly
                    )
                    guard let signInResult, signInResult.isSignedIn else {
                        dismissRegistrationProgress()
                        routeToLoginAfterAccountConfirmation()
                        return
                    }

                    UserDefaultsService.shared.set(true, for: \.isUserAccountCreated)
                    UserDefaultsService.shared.set(true, for: \.isUserAccountConfirmed)
                    UserDefaultsService.shared.set(true, for: \.isUserLoggedIn)
                    await postAuthenticationBootstrap()
                    dismissRegistrationProgress()
                    setRootScreen(.userOnboarding)
                    dismissSheet()
                default:
                    dismissRegistrationProgress()
                    break
                }
            } catch let error as AuthError {
                if error.underlyingError as? AWSCognitoAuthError == .lambda {
                    await presentPreSignUpRejection(error)
                    return
                }
                dismissRegistrationProgress()
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
                dismissRegistrationProgress()
                presentAlertWith(title: .errorText, description: errorDescription)
            }
        }
    }
    
    @MainActor
    private func autoLoginUserAfterAccountConfirmation() {
        guard let email: String = UserDefaultsService.shared.get(for: \.userEmail),
              let password = pendingCredentialStore.read(),
              !password.isEmpty else {
            // No usable stored credentials (verification completed after a
            // relaunch, or the password was already cleared by a previous
            // login). The account is verified — send the user to log in
            // instead of returning silently.
            dismissRegistrationProgress()
            routeToLoginAfterAccountConfirmation()
            return
        }
        
        Task {
            do {
                presentRegistrationProgress()
                // A session from a previously used account can still exist on
                // this device. `signIn` clears such a stale session itself (it
                // recovers from Amplify's `.invalidState`), so no pre-sign-out is
                // needed here.
                // `.passwordOnly` on purpose. The user has just typed a code out
                // of their inbox to confirm this account; asking for the email
                // challenge here would mail them a second one straight away, and
                // this sign-in expects `isSignedIn` rather than a challenge step.
                let signInResult = try await authenticationService.signIn(
                    with: email,
                    password: password,
                    flow: .passwordOnly
                )
                guard let result = signInResult, result.isSignedIn else {
                    dismissRegistrationProgress()
                    routeToLoginAfterAccountConfirmation()
                    return
                }
                
                pendingCredentialStore.clear()
                UserDefaultsService.shared.set(true, for: \.isUserLoggedIn)
                await postAuthenticationBootstrap()
                dismissRegistrationProgress()
                setRootScreen(.userOnboarding)
            } catch {
                dismissRegistrationProgress()
                // The account IS confirmed at this point — only the automatic
                // sign-in failed. Don't report it as a confirmation failure;
                // let the user log in manually.
                routeToLoginAfterAccountConfirmation()
            }
        }
    }
    
    @MainActor
    private func routeToLoginAfterAccountConfirmation() {
        pendingCredentialStore.clear()
        presentAlertWith(
            title: .successText,
            description: NSLocalizedString(
                "Your account has been verified. Please log in to continue.",
                comment: "User account confirmation screen verified, manual login required"
            )
        )
        setRootScreen(.userAuthentication)
    }

    @MainActor
    private func presentRegistrationProgress() {
        guard !isRegistrationProgressPresented else { return }
        isRegistrationProgressPresented = true
        presentProgressIndicator()
        registrationProgressChanged(true)
    }

    @MainActor
    private func dismissRegistrationProgress() {
        guard isRegistrationProgressPresented else { return }
        isRegistrationProgressPresented = false
        dismissProgressIndicator()
        registrationProgressChanged(false)
    }
    
    /// Amplify wraps Cognito service errors inside `AuthError.underlyingError`;
    /// casting the thrown error directly to `AWSCognitoAuthError` always fails,
    /// which is how sign-in failures ended up presented as confirmation
    /// failures (and real confirmation errors were silently swallowed).
    private func cognitoAuthError(from error: Error) -> AWSCognitoAuthError? {
        if let authError = error as? AuthError {
            return authError.underlyingError as? AWSCognitoAuthError
        }
        return error as? AWSCognitoAuthError
    }
}

/**
 Indirection over `PendingSignupCredentialStore` used by `UserRegistrationVM`.

 The production value (`.keychain`) forwards straight to the Keychain-backed store. Tests inject
 an in-memory implementation instead: the real store uses a shared-access-group Keychain that
 requires code-signing entitlements, and the unit-test run builds with `CODE_SIGNING_ALLOWED=NO`
 (no entitlements), so a real `save`/`read` round-trip does not persist under test. Routing the
 view model's save/read/clear through this seam lets the post-confirmation auto-login path be
 exercised deterministically without a real Keychain.
 */
struct PendingSignupCredentialAccess: Sendable {
    var save: @Sendable (String) -> Void
    var read: @Sendable () -> String?
    var clear: @Sendable () -> Void

    /// Production implementation backed by the Keychain store.
    static let keychain = PendingSignupCredentialAccess(
        save: { PendingSignupCredentialStore.save($0) },
        read: { PendingSignupCredentialStore.read() },
        clear: { PendingSignupCredentialStore.clear() }
    )
}

/**
 Stores the sign-up password only for the short window between account creation and the
 automatic sign-in that runs after email confirmation.

 The password used to live in `UserDefaults` (an unencrypted plist), which is inappropriate
 for a credential. It now lives in the Keychain, using the app's shared service/access group
 and the global accessibility set in `GlacierApplicationDelegate`
 (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-only, not iCloud-synced, and
 available after first unlock so the confirmation deep link can complete in the background).

 The value is written at account creation and deleted as soon as auto sign-in succeeds or the
 user is routed to manual login, so it is never persisted long-term.
 */
enum PendingSignupCredentialStore {

    /// Legacy `UserDefaults` key that previously held the plaintext password. Retained only so
    /// `clear()` can purge values written by older builds. Do not write to it.
    private static let legacyUserDefaultsKey = "userPassword"

    /// Persists the sign-up password to the Keychain for the pending-confirmation flow.
    static func save(_ password: String) {
        var error: NSError?
        let stored = SAMKeychain.setPassword(
            password,
            forService: kServiceName,
            account: kGlacierPendingSignupAcct,
            accessGroup: kGlacierKeyGroup,
            error: &error
        )
        if !stored {
            Log.auth.error("Failed to store pending sign-up password: \(String(describing: error?.localizedDescription))")
        }
    }

    /// Returns the stored sign-up password, or `nil` if none is present.
    static func read() -> String? {
        var error: NSError?
        let password = SAMKeychain.password(
            forService: kServiceName,
            account: kGlacierPendingSignupAcct,
            accessGroup: kGlacierKeyGroup,
            error: &error
        )
        // errSecItemNotFound is expected when nothing is stored; don't log it as an error.
        if let error, error.code != Int(errSecItemNotFound) {
            Log.auth.error("Failed to read pending sign-up password: \(error.localizedDescription)")
        }
        return password
    }

    /// Removes the stored sign-up password from the Keychain and purges any legacy plaintext
    /// value left in `UserDefaults` by an older build.
    static func clear() {
        var error: NSError?
        SAMKeychain.deletePassword(
            forService: kServiceName,
            account: kGlacierPendingSignupAcct,
            accessGroup: kGlacierKeyGroup,
            error: &error
        )
        if let error, error.code != Int(errSecItemNotFound) {
            Log.auth.error("Failed to delete pending sign-up password: \(error.localizedDescription)")
        }
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
    }
}
