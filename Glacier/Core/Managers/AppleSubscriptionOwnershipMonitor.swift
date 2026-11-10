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

 A conflict only matters when the signed-in account has no plan of its own. An account paid on the
 website or covered by a family plan works fine whatever Apple subscription the device's Apple ID
 holds. So the cover needs the backend to have said this account is NOT subscribed; subscribed, or
 no answer yet, keeps it down. Before this, a long-time website subscriber whose iPhone Apple ID held
 someone else's Glacier subscription was locked out of a working account, and "Switch Account" led
 them into a brand-new one. Waiting for an answer rather than assuming "not subscribed" also keeps
 the cover from flashing up on a fresh sign-in before `/subscription` has replied.

 The sandbox can't produce a real conflict (the backend lets sandbox transactions move between
 accounts), so Debug-configuration builds can fake one; see `isConflictForcedForTesting`.

 The owning account is never identified, here or by the backend: telling one account that another
 exists and holds the purchase is cross-account data.
 */
@MainActor
final class AppleSubscriptionOwnershipMonitor: ObservableObject {

    // MARK: - Public properties

    static let shared = AppleSubscriptionOwnershipMonitor()

    /// The backend code on the receipt-link 409 for an ownership conflict.
    nonisolated static let conflictCode = "apple_receipt_ownership_conflict"

    /// `true` while the signed-in Glacier account is known not to own this device's Apple subscription
    /// and the backend has said it has no plan of its own — the only case where nothing works for it.
    @Published private(set) var isConflicted = false

    #if GLACIER_TEST_SWITCHES
    /// Debug configuration only (the app target defines `GLACIER_TEST_SWITCHES` there; it does not
    /// define `DEBUG`): launch with `-GlacierForceAppleOwnershipConflict` to make the receipt link
    /// answer as if the backend returned the ownership-conflict 409, without sending the request.
    /// Release builds (and so every App Store and TestFlight archive) don't contain this.
    nonisolated static var isConflictForcedForTesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-GlacierForceAppleOwnershipConflict")
    }
    #endif

    // MARK: - Private properties

    /// The Glacier account (Cognito `sub`) the conflict was reported for, so a different account
    /// signing in on this device never inherits it.
    private var conflictedAccountId: UUID?

    /// The backend refused to link this device's Apple subscription to the signed-in account.
    private var hasLinkConflict = false

    /// What the backend last said about the signed-in account's own subscription (website, family
    /// plan, or another Apple purchase already linked to it). `nil` until it has answered.
    private var isEntitledOnBackend: Bool?

    // MARK: - Initializer

    /// Internal rather than private so tests can use their own instance; the app uses `shared`.
    init() {}

    // MARK: - Public methods

    /// The backend refused to link this device's Apple subscription to `accountId`.
    /// - Parameter entitledOnBackend: the last backend subscription status saved for this account,
    ///   or `nil` if the backend hasn't answered for it on this device yet.
    func reportConflict(accountId: UUID?, entitledOnBackend: Bool?) {
        conflictedAccountId = accountId
        hasLinkConflict = true
        // The saved status is written before any live answer reaches `reportBackendEntitlement`, so
        // it is never older than what this instance holds, and it belongs to `accountId`.
        isEntitledOnBackend = entitledOnBackend
        switch entitledOnBackend {
        case true?:
            Log.general.notice("[AppleSubLink] Apple subscription is owned by another Glacier account, but this account is subscribed on the backend — not showing ownership conflict")
        case false?:
            Log.general.notice("[AppleSubLink] Apple subscription is owned by another Glacier account — showing ownership conflict")
        case nil:
            Log.general.notice("[AppleSubLink] Apple subscription is owned by another Glacier account — waiting for the backend subscription status before showing ownership conflict")
        }
        updateIsConflicted()
    }

    /// The backend linked this device's Apple subscription to `accountId`, so it owns it.
    func reportLinked(accountId: UUID?) {
        guard hasLinkConflict, conflictedAccountId == nil || conflictedAccountId == accountId else { return }
        Log.general.notice("[AppleSubLink] Apple subscription linked — clearing ownership conflict")
        clear()
    }

    /// A live backend subscription status for the signed-in account. Subscribed keeps the cover down
    /// (or lifts it); not subscribed puts it up if the link conflict stands.
    func reportBackendEntitlement(_ entitled: Bool) {
        guard entitled != isEntitledOnBackend else { return }
        isEntitledOnBackend = entitled
        if hasLinkConflict {
            Log.general.notice("[AppleSubLink] backend subscribed=\(entitled) — ownership conflict \(entitled ? "lifted" : "applies")")
        }
        updateIsConflicted()
    }

    /// Drops any conflict, e.g. on sign-out. The next link attempt for whoever signs in decides again.
    func clear() {
        conflictedAccountId = nil
        hasLinkConflict = false
        isEntitledOnBackend = nil
        updateIsConflicted()
    }

    // MARK: - Private methods

    private func updateIsConflicted() {
        let conflicted = hasLinkConflict && isEntitledOnBackend == false
        if isConflicted != conflicted {
            isConflicted = conflicted
        }
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
