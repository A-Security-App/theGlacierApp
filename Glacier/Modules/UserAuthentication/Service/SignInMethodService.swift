//
//  SignInMethodService.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Alamofire
import Amplify
import SAMKeychain

/**
 A social provider an account can be created with. The raw values are the
 provider names the backend reports.
 */
enum FederatedSignInProvider: String, CaseIterable {
    case google = "Google"
    case apple = "Apple"

    init?(_ authProvider: AuthProvider) {
        switch authProvider {
        case .google: self = .google
        case .apple: self = .apple
        default: return nil
        }
    }

    var authProvider: AuthProvider {
        switch self {
        case .google: .google
        case .apple: .apple
        }
    }

    /// A brand name, so it is never translated.
    var displayName: String { rawValue }

    var continueButtonTitle: String {
        switch self {
        case .google:
            NSLocalizedString("Continue with Google", comment: "User login screen Google auth button title")
        case .apple:
            NSLocalizedString("Continue with Apple", comment: "User login screen Apple auth button title")
        }
    }

    var buttonIcon: String {
        switch self {
        case .google: "google-logo"
        case .apple: "apple-logo"
        }
    }
}

/**
 What the backend says an email should sign in with.

 `.password` is also the answer for an address with no account and for a
 lookup that failed: the backend answers those identically on purpose (pentest
 finding F-08), and the app treats a failure the same way.
 */
enum SignInMethod: Equatable {
    case password
    case federated(FederatedSignInProvider)

    /// Parses the `POST /v1/auth/sign-in-method` body. Anything unexpected,
    /// including a provider this build doesn't know, reads as `.password` so the
    /// user keeps the normal error instead of a wrong redirect.
    init(responseData data: Data) {
        guard
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            body["action"] as? String == "FEDERATED_REDIRECT",
            let name = body["provider"] as? String,
            let provider = FederatedSignInProvider(rawValue: name)
        else {
            self = .password
            return
        }
        self = .federated(provider)
    }
}

/**
 Looks up how an email address signs in, before or after a password attempt.
 */
protocol SignInMethodLookup {
    func signInMethod(for email: String) async -> SignInMethod
}

/**
 Calls the console's public sign-in method endpoint. It is unauthenticated —
 the user isn't signed in yet — and rate-limited by the backend.

 Backend contract:
   POST {consoleBaseEndpoint}auth/sign-in-method
   { "email": "<address>" }
   → { "action": "PASSWORD" }
   → { "action": "FEDERATED_REDIRECT", "provider": "Google" | "Apple" }

 The backend holds every answer to a 400 ms minimum.
 */
final class ConsoleSignInMethodService: SignInMethodLookup {

    // MARK: - Private properties

    private static let path = "auth/sign-in-method"

    private let sessionManager: Alamofire.Session = {
        // The answer only improves an error message, so a slow network must
        // not hold up the sign-in behind it.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        return Alamofire.Session(
            configuration: configuration,
            serverTrustManager: GlacierPinningConfiguration.makeServerTrustManager()
        )
    }()
    private let internalQueue = DispatchQueue(label: "sign-in-method-queue", qos: .userInitiated)

    // MARK: - Public methods

    func signInMethod(for email: String) async -> SignInMethod {
        guard !SecurityCenter.isProxyDetected else { return .password }
        guard let url = EndpointService.shared.endpointURL(path: Self.path) else {
            Log.auth.error("ConsoleSignInMethodService: could not build sign-in method URL.")
            return .password
        }
        let parameters = ["email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]

        return await withCheckedContinuation { continuation in
            self.sessionManager.request(
                url,
                method: .post,
                parameters: parameters,
                encoder: JSONParameterEncoder.default
            )
            .validate()
            .responseData(queue: self.internalQueue) { response in
                switch response.result {
                case .success(let data):
                    continuation.resume(returning: SignInMethod(responseData: data))
                case .failure(let error):
                    Log.auth.error("ConsoleSignInMethodService: lookup failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: .password)
                }
            }
        }
    }
}

/**
 Remembers which social provider this device last signed in with, so the login
 screen can remind the user. It lives in the Keychain rather than
 UserDefaults so the hint survives a reinstall, which is when people most often
 forget how they signed up. Only the provider name is stored — never the email.
 */
enum LastSignInProviderStore {

    private static let service = "com.theglacierapp.Glacier.lastSignInProvider"
    private static let account = "provider"

    static var provider: FederatedSignInProvider? {
        SAMKeychain.password(forService: service, account: account)
            .flatMap(FederatedSignInProvider.init(rawValue:))
    }

    static func record(_ provider: FederatedSignInProvider) {
        SAMKeychain.setPassword(provider.rawValue, forService: service, account: account)
    }

    static func clear() {
        SAMKeychain.deletePassword(forService: service, account: account)
    }
}

/// The title and text of an alert about how an account signs in. Each one has
/// its own short title rather than a generic "Error".
struct AuthAlertContent: Equatable {
    let title: String
    let message: String
}

/**
 Reads a sign-up that the `pre-signup-link` Lambda turned down.

 The Lambda refuses a password sign-up for an email that already uses Google or
 Apple, and a Google or Apple sign-in for an email whose password account isn't
 verified yet. Cognito passes its reason on as
 `PreSignUp failed with error <reason>`:

 - on email sign-up, inside an `AWSCognitoAuthError.lambda`;
 - on Google or Apple, only as text in the Hosted UI redirect's
   `error_description`, which can arrive with `+` for spaces. There is no error
   code to go on, so Cognito's fixed prefix is what identifies it.
 */
enum PreSignUpRejection {

    private static let prefix = "PreSignUp failed with error"

    /// The Lambda's own reason, or nil if the error didn't come from it.
    static func reason(from error: Error) -> String? {
        let description: String
        if let authError = error as? AuthError {
            description = authError.errorDescription
        } else {
            description = String(describing: error)
        }
        let text = description.replacingOccurrences(of: "+", with: " ")
        guard let range = text.range(of: prefix) else { return nil }
        let reason = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }

    /// What to tell someone whose Google or Apple sign-in the Lambda refused.
    /// The unverified-account case gets a translated message; anything else
    /// shows the Lambda's reason as written, which beats a generic failure.
    static func federatedSignInAlert(for error: Error, provider: FederatedSignInProvider) -> AuthAlertContent? {
        guard let reason = reason(from: error) else { return nil }
        if reason.localizedCaseInsensitiveContains("Verify your existing account") {
            return AuthAlertContent(
                title: NSLocalizedString(
                    "Verify your account",
                    comment: "Alert title: Google or Apple sign-in refused because a password account with the same email is unverified"
                ),
                message: String(
                    format: NSLocalizedString(
                        "This email already has a Glacier account that isn't verified yet. Log in with your email and password to finish verifying it, then try %@ again.",
                        comment: "Google or Apple sign-in refused because a password account with the same email is unverified. %@ is the provider name."
                    ),
                    provider.displayName
                )
            )
        }
        return AuthAlertContent(
            title: NSLocalizedString(
                "Couldn't sign in",
                comment: "Alert title: Google or Apple sign-in refused by the backend for another reason"
            ),
            message: reason
        )
    }

    /// Email sign-up refused because the email already uses a provider.
    static func existingProviderAlert(for provider: FederatedSignInProvider) -> AuthAlertContent {
        AuthAlertContent(
            title: NSLocalizedString(
                "Account already exists",
                comment: "Alert title: email sign-up refused because the email already uses Google or Apple"
            ),
            message: existingProviderMessage(for: provider)
        )
    }

    /// Email sign-up refused for any other reason the Lambda gives.
    static var signUpRefusedTitle: String {
        NSLocalizedString(
            "Couldn't create account",
            comment: "Alert title: email sign-up refused by the backend"
        )
    }

    /// Email sign-up refused because the email already uses a provider.
    static func existingProviderMessage(for provider: FederatedSignInProvider) -> String {
        String(
            format: NSLocalizedString(
                "An account with this email already uses %1$@. Continue with %1$@ instead.",
                comment: "User registration screen email sign-up refused because the email already uses Google or Apple. %1$@ is the provider name."
            ),
            provider.displayName
        )
    }
}
