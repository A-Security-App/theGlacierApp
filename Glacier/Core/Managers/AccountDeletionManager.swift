//
//  AccountDeletionManager.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import Alamofire

/**
 Why the user is deleting their account, sent with the delete request so the backend can
 record it (console#571). The raw values are the backend's codes and must not change. The
 cases are in the console's order, without `duplicate_account`: the survey shows eight reasons
 in four rows of two, and a second account can go in the feedback box.
 */
enum AccountDeletionReason: String, CaseIterable, Identifiable {
    case tooExpensive = "too_expensive"
    case vpnCompatibility = "vpn_compatibility"
    case phoneNumberIssues = "phone_number_issues"
    case buggyOrHardToUse = "buggy_or_hard_to_use"
    case notUsedEnough = "not_used_enough"
    case shortTermNeed = "short_term_need"
    case slowOrBatteryDrain = "slow_or_battery_drain"
    case other = "other"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tooExpensive:
            NSLocalizedString("It costs too much", comment: "Account deletion reason")
        case .vpnCompatibility:
            NSLocalizedString("Sites or apps don't work with the VPN", comment: "Account deletion reason")
        case .phoneNumberIssues:
            NSLocalizedString("Problems with calls on my Glacier number", comment: "Account deletion reason")
        case .buggyOrHardToUse:
            NSLocalizedString("The app is buggy or hard to use", comment: "Account deletion reason")
        case .notUsedEnough:
            NSLocalizedString("I don't use it enough", comment: "Account deletion reason")
        case .shortTermNeed:
            NSLocalizedString("I only needed it for a short time", comment: "Account deletion reason")
        case .slowOrBatteryDrain:
            NSLocalizedString("It slows my internet or drains my battery", comment: "Account deletion reason")
        case .other:
            NSLocalizedString("Other", comment: "Account deletion reason")
        }
    }
}

/// The user's answer to "why are you leaving?". `nil` everywhere it's used means they skipped it.
struct AccountDeletionFeedback {
    /// The backend rejects `details` longer than this (after trimming).
    static let maxDetailsLength = 500

    let reason: AccountDeletionReason
    let details: String?

    /// The request body. Blank details are left out rather than sent empty.
    var parameters: [String: String] {
        var parameters = ["reason": reason.rawValue]
        let trimmed = details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            parameters["details"] = String(trimmed.prefix(Self.maxDetailsLength))
        }
        return parameters
    }
}

/**
 AccountDeletionManager deletes the signed-in user's Glacier account through the
 backend. Unlike a direct `Amplify.Auth.deleteUser()` call — which only removes
 the Cognito user — the backend endpoint deletes the Cognito user *and* performs
 the associated server-side cleanup (subscription, phone numbers, VPN/DNS
 provisioning, etc.).

 Backend contract:
   DELETE {consoleBaseEndpoint}/user
   Authorization: Bearer <Cognito access token>
   Body (optional): { "reason": "<AccountDeletionReason>", "details": "<up to 500 chars>" }

 With no body the delete behaves exactly as it always has. With a body the backend also
 records why the user left. A `400` means it rejected the answer and deleted nothing.
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

    /// Deletes the signed-in user's account on the backend, sending `feedback` with it when given.
    /// Returns `true` only when the backend confirms deletion, so callers can
    /// keep local state intact and let the user retry on failure.
    func deleteAccount(feedback: AccountDeletionFeedback? = nil) async -> Bool {
        guard !SecurityCenter.isProxyDetected else { return false }
        guard let url = EndpointService.shared.endpointURL(path: Self.userPath) else {
            Log.auth.error("AccountDeletionManager: could not build user URL.")
            return false
        }
        guard let headers = await GlacierAPIHeaders.authHeaders() else {
            Log.auth.error("AccountDeletionManager: missing auth headers; cannot delete account.")
            return false
        }

        let result = await sendDelete(url: url, headers: headers, parameters: feedback?.parameters)
        // A 400 on a request that carried an answer means the backend didn't accept the answer
        // and deleted nothing. The answer must never be what stops a deletion, so retry once
        // without it — that's the same request the app has always sent.
        if result == .rejectedFeedback, feedback != nil {
            Log.auth.notice("AccountDeletionManager: backend rejected the deletion reason; retrying without it.")
            return await sendDelete(url: url, headers: headers, parameters: nil) == .deleted
        }
        return result == .deleted
    }

    // MARK: - Private methods

    private enum DeleteResult {
        case deleted, rejectedFeedback, failed
    }

    private func sendDelete(url: URL, headers: HTTPHeaders, parameters: [String: String]?) async -> DeleteResult {
        await withCheckedContinuation { continuation in
            self.sessionManager.request(
                url,
                method: .delete,
                parameters: parameters,
                encoder: JSONParameterEncoder.default,
                headers: headers
            )
            .validate()
            .responseData(queue: self.internalQueue) { response in
                switch response.result {
                case .success:
                    continuation.resume(returning: .deleted)
                case .failure(let error):
                    Log.auth.error("AccountDeletionManager: failed to delete account: \(error)")
                    let rejectedFeedback = parameters != nil && response.response?.statusCode == 400
                    continuation.resume(returning: rejectedFeedback ? .rejectedFeedback : .failed)
                }
            }
        }
    }
}
