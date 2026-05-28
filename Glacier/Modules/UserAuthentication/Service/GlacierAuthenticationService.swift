//
//  GlacierAuthenticationService.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 03/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import UIKit
import Authenticator
import Amplify
import AuthenticationServices
import AWSCognitoAuthPlugin

/**
 `GlacierAuthenticationService` defines requirements for user authentication services.
 */
protocol GlacierAuthenticationService {
    func createUserAccount(with email: String, password: String) async throws -> AuthSignUpResult?
    func resendSignUpCode(for userName: String) async throws -> AuthCodeDeliveryDetails
    func confirmSignUp(for userName: String, confirmationCode: String) async throws -> AuthSignUpResult?
    
    func signIn(with email: String, password: String) async throws -> AuthSignInResult?
    func signIn(with provider: AuthProvider) async throws -> AuthSignInResult?
    
    func resetPassword(for userName: String) async throws -> AuthResetPasswordResult?
    func confirmResetPassword(for userName: String, with newPassword: String, confirmationCode: String) async throws -> Bool
    
    func getCurrentUser() async throws -> AuthUser
    func getCurrentAuthSession() async throws -> AuthSession?
    
    func signOut() async -> Bool
}

/**
 AmplifyAuthenticationService integrates user authentication flows with Amplify auth.
 */
final class AmplifyAuthenticationService: GlacierAuthenticationService {
    
    /**
     Calls Amplify.Auth.signUp() method to create new user account with given email and password combination.
     */
    func createUserAccount(with email: String, password: String) async throws -> AuthSignUpResult? {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let options = AuthSignUpRequest.Options(
                        userAttributes: [AuthUserAttribute(.email, value: email)]
                    )
                    let result = try await Amplify.Auth.signUp(
                        username: email,
                        password: password,
                        options: options
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /**
     Calls Amplify.Auth.resendSignUpCode() method for resending user account confirmation code.
     */
    func resendSignUpCode(for userName: String) async throws -> AuthCodeDeliveryDetails {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let details = try await Amplify.Auth.resendSignUpCode(for: userName)
                    continuation.resume(returning: details)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /**
     Calls Amplify.Auth.confirmSignUp() method for confirming user account registration.
     */
    func confirmSignUp(for userName: String, confirmationCode: String) async throws -> AuthSignUpResult? {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let result = try await Amplify.Auth.confirmSignUp(for: userName, confirmationCode: confirmationCode)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /**
     Calls Amplify.Auth.signIn() method to log user in with given email and password.
     */
    func signIn(with email: String, password: String) async throws -> AuthSignInResult? {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let signInResult = try await Amplify.Auth.signIn(
                        username: email,
                        password: password
                    )
                    continuation.resume(returning: signInResult)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /**
     Initiates user authentication flow with Google and Apple authetication providers.
     */
    func signIn(with provider: AuthProvider) async throws -> AuthSignInResult? {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    // preferPrivateSession: true uses an ephemeral ASWebAuthenticationSession,
                    // which suppresses the "Glacier wants to use...to sign in" iOS system dialog.
                    // Amplify stores this preference and reuses it during sign-out, so the sign-out
                    // Hosted UI redirect also runs silently without any popup.
                    let result = try await Amplify.Auth.signInWithWebUI(
                        for: provider,
                        presentationAnchor: presentationAnchor(),
                        options: .init(pluginOptions: AWSAuthWebUISignInOptions(preferPrivateSession: true))
                    )
                    
                    guard result.isSignedIn else {
                        continuation.resume(throwing: UserAuthenticationError.authenticationFailure)
                        return
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /**
     Calls Amplify.Auth.resetPassword() method to initiate user password reset flow.
     */
    func resetPassword(for userName: String) async throws -> AuthResetPasswordResult? {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let result = try await Amplify.Auth.resetPassword(for: userName)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /**
     Calls Amplify.Auth.confirmResetPassword() method to confirm password reset.
     */
    public func confirmResetPassword(for userName: String, with newPassword: String, confirmationCode: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    try await Amplify.Auth.confirmResetPassword(for: userName, with: newPassword, confirmationCode: confirmationCode)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    /**
     Calls Amplify.Auth.fetchAuthSession() method to get user authentication session details
     */
    func getCurrentUser() async throws -> AuthUser {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let user = try await Amplify.Auth.getCurrentUser()
                    continuation.resume(returning: user)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /**
     Calls Amplify.Auth.fetchAuthSession() to get current user's authentication session
     */
    func getCurrentAuthSession() async throws -> AuthSession? {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let session = try await Amplify.Auth.fetchAuthSession()
                    continuation.resume(returning: session)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /**
     Signs out user.
     */
    func signOut() async -> Bool {
        return await withCheckedContinuation { continuation in
            Task {
                do {
                    let signOutResult = await Amplify.Auth.signOut()
                    guard let result = signOutResult as? AWSCognitoSignOutResult else {
                        continuation.resume(returning: false)
                        return
                    }
                    continuation.resume(returning: result.signedOutLocally)
                }
            }
        }
    }
}

extension AuthProvider {
    /// A stable string representation used to persist the Hosted UI provider in UserDefaults.
    var authProviderName: String {
        switch self {
        case .apple:   return "apple"
        case .google:  return "google"
        default:       return "unknown"
        }
    }
}

extension AmplifyAuthenticationService {
    @MainActor
    private func presentationAnchor() -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? ASPresentationAnchor()
    }
}
