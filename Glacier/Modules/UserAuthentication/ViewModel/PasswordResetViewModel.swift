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
    private let signInMethodService: SignInMethodLookup
    
    // MARK: - Initializer
    
    convenience init(
        rootCoodinator: any GlacierRootCoordinator,
        passwordResetCoordinator: any GlacierCoordinator,
        authenticationService: GlacierAuthenticationService,
        isPresentedFromLoginScreen: Bool
    ) {
        self.init(
            rootCoodinator: rootCoodinator,
            passwordResetCoordinator: passwordResetCoordinator,
            authenticationService: authenticationService,
            signInMethodService: ConsoleSignInMethodService(),
            isPresentedFromLoginScreen: isPresentedFromLoginScreen
        )
    }
    
    /// - Parameter savedEmail: The signed-in account's email, to fill in. Reads the account
    ///   database by default; tests pass their own, because the database crashes on purpose
    ///   when the keychain isn't available.
    init(
        rootCoodinator: any GlacierRootCoordinator,
        passwordResetCoordinator: any GlacierCoordinator,
        authenticationService: GlacierAuthenticationService,
        signInMethodService: SignInMethodLookup,
        isPresentedFromLoginScreen: Bool,
        savedEmail: () -> String? = { GlacierAccountModel.getGlacierAccount()?.username }
    ) {
        self.rootCoordinator = rootCoodinator
        self.passwordResetCoordinator = passwordResetCoordinator
        self.authenticationService = authenticationService
        self.signInMethodService = signInMethodService
        self.isPresentedFromLoginScreen = isPresentedFromLoginScreen
        
        fillInEmail(savedEmail())
    }
    
    // MARK: - Public methods
    
    /// Someone who signed up with Google or Apple has no password, so Cognito
    /// sends no reset email and they wait for one that never comes. Check how
    /// the email signs in first and say so. An account created with a password
    /// and linked later still has one, so they can send the email anyway.
    @MainActor
    func sendPasswordResetLink() {
        guard !email.isEmpty else {
            requestPasswordReset()
            return
        }
        Task {
            presentProgressIndicator()
            let method = await signInMethodService.signInMethod(for: email)
            guard case .federated(let provider) = method else {
                // The reset keeps this spinner up (presenting it again is a
                // no-op) and dismisses it, so it doesn't flicker between steps.
                requestPasswordReset()
                return
            }
            dismissProgressIndicator()
            presentLinkedProviderAlert(for: provider)
        }
    }
    
    /// What to tell someone resetting the password of an email that signs in
    /// with Google or Apple.
    static func linkedProviderAlert(for provider: FederatedSignInProvider) -> AuthAlertContent {
        AuthAlertContent(
            title: String(
                format: NSLocalizedString(
                    "Linked to %@",
                    comment: "Alert title: wrong password for an email linked to Google or Apple. %@ is the provider name."
                ),
                provider.displayName
            ),
            message: String(
                format: NSLocalizedString(
                    "This email signs in with %1$@. If you never set a password, no reset email will arrive. Go back and use Continue with %1$@ instead.",
                    comment: "Password reset screen: the email signs in with Google or Apple. %1$@ is the provider name."
                ),
                provider.displayName
            )
        )
    }
    
    @MainActor
    private func presentLinkedProviderAlert(for provider: FederatedSignInProvider) {
        let alert = Self.linkedProviderAlert(for: provider)
        presentPopup(with: PopupConfiguration(
            title: alert.title,
            description: alert.message,
            buttons: [
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Ok", comment: "Ok button title"),
                    onTap: { [weak self] in
                        self?.rootCoordinator.dismissPopup()
                    }
                ),
                PopupButton(
                    style: .secondary,
                    title: NSLocalizedString(
                        "I have a password, send the email",
                        comment: "Password reset screen button: send the reset email for an email linked to Google or Apple"
                    ),
                    onTap: { [weak self] in
                        self?.rootCoordinator.dismissPopup()
                        self?.requestPasswordReset()
                    }
                )
            ],
            buttonsAlignment: .vertical
        ))
    }
    
    @MainActor
    private func requestPasswordReset() {
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
    
    /// Set through a method rather than in `init` directly, so `email`'s `didSet` runs and
    /// enables Continue.
    private func fillInEmail(_ savedEmail: String?) {
        guard let savedEmail else {
            return
        }
        email = savedEmail
    }
}
