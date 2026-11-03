//
//  AppleSubscriptionOwnershipMonitor.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 AppleSubscriptionOwnershipMonitor tracks whether the Apple subscription on this device belongs to a
 different Glacier account than the one signed in.

 StoreKit entitlements follow the Apple ID, not the Glacier login. Someone who signed up with one
 email (or Sign in with Apple) and later signs in with another still sees the subscription in
 `Transaction.currentEntitlements`, so the app lets them in. The backend refuses to link it, because
 the purchase is already claimed, and every entitlement-gated call (DNS, VPN, phone) is refused. The
 user ends up in an app that looks paid and does nothing.

 The backend reports this from `POST apple/validate-receipt` as a `409` with
 `code: "apple_receipt_ownership_conflict"`. That endpoint returns no other 409, so a bare 409 from
 a backend that predates the code counts too.

 This is its own state, not a lapse. The lapse paywall's Restore re-posts the same receipt and
 conflicts again, and Buy invites a duplicate purchase on an Apple ID that already holds the plan.
 `GlacierAppRootScreen` shows `SubscriptionOwnershipConflictScreen` while `isConflicted` is set.

 The owning account is never identified, here or by the backend: telling one account that another
 exists and holds the purchase is cross-account data.
 */
@MainActor
final class AppleSubscriptionOwnershipMonitor: ObservableObject {

    // MARK: - Public properties

    static let shared = AppleSubscriptionOwnershipMonitor()

    /// The backend code on the receipt-link 409 for an ownership conflict.
    nonisolated static let conflictCode = "apple_receipt_ownership_conflict"

    /// `true` while the signed-in Glacier account is known not to own this device's Apple subscription.
    @Published private(set) var isConflicted = false

    // MARK: - Private properties

    /// The Glacier account (Cognito `sub`) the conflict was reported for, so a different account
    /// signing in on this device never inherits it.
    private var conflictedAccountId: UUID?

    // MARK: - Initializer

    private init() {}

    // MARK: - Public methods

    /// The backend refused to link this device's Apple subscription to `accountId`.
    func reportConflict(accountId: UUID?) {
        Log.general.notice("[AppleSubLink] Apple subscription is owned by another Glacier account — showing ownership conflict")
        conflictedAccountId = accountId
        isConflicted = true
    }

    /// The backend linked this device's Apple subscription to `accountId`, so it owns it.
    func reportLinked(accountId: UUID?) {
        guard isConflicted, conflictedAccountId == nil || conflictedAccountId == accountId else { return }
        Log.general.notice("[AppleSubLink] Apple subscription linked — clearing ownership conflict")
        clear()
    }

    /// Drops any conflict, e.g. on sign-out. The next link attempt for whoever signs in decides again.
    func clear() {
        conflictedAccountId = nil
        isConflicted = false
    }

    /// Whether a receipt-link response is the backend's ownership conflict.
    nonisolated static func isOwnershipConflict(statusCode: Int, body: Data?) -> Bool {
        guard statusCode == 409 else { return false }
        // Absent or unreadable code: the endpoint's only 409 is the ownership conflict.
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let code = json["code"] as? String else { return true }
        return code == conflictCode
    }
}
