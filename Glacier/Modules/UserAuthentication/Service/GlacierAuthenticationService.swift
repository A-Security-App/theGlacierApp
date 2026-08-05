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

    func signIn(with email: String, password: String, flow: GlacierSignInFlow) async throws -> AuthSignInResult?
    func signIn(with provider: AuthProvider) async throws -> AuthSignInResult?
    func confirmSignIn(challengeResponse: String) async throws -> AuthSignInResult?

    func resetPassword(for userName: String) async throws -> AuthResetPasswordResult?
    func confirmResetPassword(for userName: String, with newPassword: String, confirmationCode: String) async throws -> Bool

    func getCurrentUser() async throws -> AuthUser
    func getCurrentAuthSession() async throws -> AuthSession?

    func signOut() async -> Bool
}

/**
 Which Cognito auth flow a password sign-in asks for.

 The Glacier user pool has no native MFA turned on — that setting is pool-wide
 and would also catch flows that must not be challenged. Instead the pool runs
 three custom auth challenge triggers, and `CUSTOM_WITH_SRP` is what routes a
 sign-in through them so the `web-login-challenge` Lambda emails a code.
 */
enum GlacierSignInFlow {

    /// SRP, then the custom challenge that emails a six-digit code.
    case emailCodeChallenge

    /// SRP alone. No code is emailed.
    case passwordOnly

    var authFlowType: AuthFlowType {
        switch self {
        case .emailCodeChallenge: .customWithSRP
        case .passwordOnly: .userSRP
        }
    }
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

     `flow` decides whether Cognito runs the custom challenge that emails a
     six-digit code. Login asks for `.emailCodeChallenge`. The automatic sign-in
     that follows account confirmation asks for `.passwordOnly`, so confirming a
     brand new account does not immediately mail a second code.
     */
    func signIn(
        with email: String,
        password: String,
        flow: GlacierSignInFlow
    ) async throws -> AuthSignInResult? {
        do {
            return try await amplifySignIn(email: email, password: password, flow: flow)
        } catch {
            // A shipped build cannot be pulled back the way a server deploy can,
            // so it must not hard-depend on ALLOW_CUSTOM_AUTH being present on
            // the Cognito app client. Without that flag Cognito rejects the
            // request outright and the user cannot log in at all. For that one
            // error, and only that one, fall back to plain SRP so sign-in still
            // works — and log it, because the account got no code and the app
            // client still needs the flag before this build's 2FA does anything.
            // Debug-only: the message itself carries no PII, but there is no
            // reason to persist it in the unified log of a release build.
            guard flow == .emailCodeChallenge, Self.isCustomAuthUnavailable(error) else {
                throw error
            }
            #if DEBUG
            Log.auth.error("[GlacierAuth] Cognito app client does not allow custom auth; signed in without an email code: \(String(describing: error), privacy: .public)")
            #endif
            return try await amplifySignIn(email: email, password: password, flow: .passwordOnly)
        }
    }

    private func amplifySignIn(
        email: String,
        password: String,
        flow: GlacierSignInFlow
    ) async throws -> AuthSignInResult {
        try await signInClearingStaleSession {
            try await Amplify.Auth.signIn(
                username: email,
                password: password,
                options: .init(
                    pluginOptions: AWSAuthSignInOptions(authFlowType: flow.authFlowType)
                )
            )
        }
    }

    /**
     Answers the emailed six-digit code for a sign-in that is parked on the
     custom challenge.
     */
    func confirmSignIn(challengeResponse: String) async throws -> AuthSignInResult? {
        try await Amplify.Auth.confirmSignIn(challengeResponse: challengeResponse)
    }

    /**
     Cognito answers a `CUSTOM_WITH_SRP` request from an app client that lacks
     `ALLOW_CUSTOM_AUTH` with `InvalidParameterException`, which Amplify surfaces
     as `.invalidParameter`. The observed message is `CUSTOM_AUTH is not enabled
     for the client` — Cognito's stable phrasing for a disabled flow is
     `<FLOW> is not enabled for the client`, so that substring is what we match
     (an earlier `"auth flow"` guess never matched the real text, and the missing
     fallback locked users out). We only reach here for `.emailCodeChallenge`, so
     "not enabled for the client" can only mean custom auth. The `"auth flow"`
     variant is kept as a belt-and-braces alternative. Because `.invalidParameter`
     also covers unrelated bad requests, the message has to match too; anything
     else is rethrown and reaches the user exactly as it does now.

     Not `private` so `UserLoginEmailCodeTests` can pin the message match and stop
     this from silently regressing again.
     */
    static func isCustomAuthUnavailable(_ error: Error) -> Bool {
        let underlying = (error as? AuthError)?.underlyingError as? AWSCognitoAuthError
        let cognitoError = underlying ?? error as? AWSCognitoAuthError
        guard cognitoError == .invalidParameter else { return false }
        let description = String(describing: error).lowercased()
        return description.contains("not enabled for the client")
            || description.contains("auth flow")
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
                    let result = try await self.signInClearingStaleSession {
                        try await Amplify.Auth.signInWithWebUI(
                            for: provider,
                            presentationAnchor: self.presentationAnchor(),
                            options: .init(pluginOptions: AWSAuthWebUISignInOptions(preferPrivateSession: true))
                        )
                    }

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
     Runs an Amplify sign-in, transparently recovering from the `.invalidState`
     error Amplify throws when a residual Cognito session from a previous account
     or login is still present on the device ("There is already a user in the
     signedIn state. SignOut the user first before calling signIn").

     Such a session can linger for reasons the app-launch reinstall check in
     `tryFetchSession` doesn't cover (an untrustworthy first launch, a not-first
     launch, or a device that still holds prior local user state), and it then
     causes a manual Login / Sign-in-with-provider tap to throw.

     On that specific error — and only that error — it signs the stale session
     out and retries the sign-in exactly once. Every other error is rethrown
     unchanged, and the common no-stale-session case takes the fast path with no
     extra work. This is only ever reached because the user is actively signing
     in, so it can never sign out a user who has a valid session and shouldn't be
     seeing the login screen at all — that routing happens elsewhere.
     */
    private func signInClearingStaleSession(
        _ attempt: () async throws -> AuthSignInResult
    ) async throws -> AuthSignInResult {
        do {
            return try await attempt()
        } catch let error as AuthError {
            guard case .invalidState = error else { throw error }
            Log.auth.notice("[GlacierAuth] signIn hit .invalidState (residual session on device) — signing out stale session and retrying sign-in once.")
            _ = await Amplify.Auth.signOut()
            return try await attempt()
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
