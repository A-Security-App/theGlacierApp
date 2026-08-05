//
//  AccountDeletionManager.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Alamofire

/**
 AccountDeletionManager deletes the signed-in user's Glacier account through the
 backend. Unlike a direct `Amplify.Auth.deleteUser()` call — which only removes
 the Cognito user — the backend endpoint deletes the Cognito user *and* performs
 the associated server-side cleanup (subscription, phone numbers, VPN/DNS
 provisioning, etc.).

 Backend contract:
   DELETE {consoleBaseEndpoint}/user
   Authorization: Bearer <Cognito access token>
 */
final class AccountDeletionManager {

    // MARK: - Public properties

    static let shared = AccountDeletionManager()

    // MARK: - Private properties

    /// Path (relative to the console base endpoint) for the user resource.
    private static let userPath = "user"

    private let sessionManager = Alamofire.Session(
        configuration: URLSessionConfiguration.ephemeral,
        serverTrustManager: GlacierPinningConfiguration.makeServerTrustManager()
    )
    private let internalQueue = DispatchQueue(label: "account-deletion-queue", qos: .userInitiated)

    // MARK: - Initializer

    private init() {}

    // MARK: - Public methods

    /// Deletes the signed-in user's account on the backend.
    /// Returns `true` only when the backend confirms deletion, so callers can
    /// keep local state intact and let the user retry on failure.
    func deleteAccount() async -> Bool {
        guard !SecurityCenter.isProxyDetected else { return false }
        guard let url = EndpointService.shared.endpointURL(path: Self.userPath) else {
            Log.auth.error("AccountDeletionManager: could not build user URL.")
            return false
        }
        guard let headers = await GlacierAPIHeaders.authHeaders() else {
            Log.auth.error("AccountDeletionManager: missing auth headers; cannot delete account.")
            return false
        }
        return await withCheckedContinuation { continuation in
            self.sessionManager.request(url, method: .delete, headers: headers)
                .validate()
                .responseData(queue: self.internalQueue) { response in
                    switch response.result {
                    case .success:
                        continuation.resume(returning: true)
                    case .failure(let error):
                        Log.auth.error("AccountDeletionManager: failed to delete account: \(error)")
                        continuation.resume(returning: false)
                    }
                }
        }
    }
}
