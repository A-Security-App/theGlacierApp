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
    /// Prevents duplicate ConfirmSignUp submissions; see confirmAccount(userName:confirmationCode:).
    private var isConfirmationInProgress = false
    
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
                if cognitoAuthError(from: error) == .userCancelled {
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
                presentProgressIndicator()
                let result = try await authenticationService.confirmSignUp(for: userName, confirmationCode: confirmationCode)
                dismissProgressIndicator()
                
                guard let authResult = result, authResult.isSignUpComplete else {
                    isConfirmationInProgress = false
                    presentAlertWith(title: .errorText, description: errorDescription)
                    return
                }
                
                isUserAccountConfirmationPending = false
                UserDefaultsService.shared.set(true, for: \.isUserAccountConfirmed)
                
                autoLoginUserAfterAccountConfirmation()
            } catch {
                dismissProgressIndicator()
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
                    PendingSignupCredentialStore.save(password)
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
              let password = PendingSignupCredentialStore.read(),
              !password.isEmpty else {
            // No usable stored credentials (verification completed after a
            // relaunch, or the password was already cleared by a previous
            // login). The account is verified — send the user to log in
            // instead of returning silently.
            routeToLoginAfterAccountConfirmation()
            return
        }
        
        Task {
            do {
                presentProgressIndicator()
                // A session from a previously used account can still exist on
                // this device, and Amplify.Auth.signIn throws .invalidState when
                // any user is already signed in. Clear it before auto sign-in.
                _ = await authenticationService.signOut()
                
                let signInResult = try await authenticationService.signIn(with: email, password: password)
                dismissProgressIndicator()
                
                guard let result = signInResult, result.isSignedIn else {
                    routeToLoginAfterAccountConfirmation()
                    return
                }
                
                PendingSignupCredentialStore.clear()
                UserDefaultsService.shared.set(true, for: \.isUserLoggedIn)
                setRootScreen(.userOnboarding)
            } catch {
                dismissProgressIndicator()
                // The account IS confirmed at this point — only the automatic
                // sign-in failed. Don't report it as a confirmation failure;
                // let the user log in manually.
                routeToLoginAfterAccountConfirmation()
            }
        }
    }
    
    @MainActor
    private func routeToLoginAfterAccountConfirmation() {
        PendingSignupCredentialStore.clear()
        presentAlertWith(
            title: .successText,
            description: NSLocalizedString(
                "Your account has been verified. Please log in to continue.",
                comment: "User account confirmation screen verified, manual login required"
            )
        )
        setRootScreen(.userAuthentication)
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
