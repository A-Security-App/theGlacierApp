//
//  GlacierPlanPurchaseService.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 08/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import StoreKit
import Amplify

/**
 GlacierPlanPurchaseService defines requirements for services that provide APIs for Glacier plan purchase and restore related workflows.
 */
protocol GlacierPlanPurchaseService {
    func loadAvailablePlans() async throws -> [Product]
    func purchasePlan(_ product: Product) async throws
    func restorePurchase() async throws
    /// Checks the current StoreKit entitlements and posts the appropriate notification.
    /// Returns `true` when StoreKit gave a definitive (non-timeout) answer, `false` when
    /// the 5-second timeout fired before the transaction sequence completed.  Callers that
    /// take destructive action on a "not subscribed" result should only do so when this
    /// returns `true`.
    @discardableResult
    func refreshEntitlements() async -> Bool
}

/// Shared by every plan-purchase service so the base plan and the phone add-on
/// attribute their App Store transactions the same way.
extension GlacierPlanPurchaseService {

    /// Resolves the current Glacier account's stable UUID (Cognito `sub`) for use as the App Store
    /// `appAccountToken`. Returns `nil` — never blocks or throws into the purchase flow — when
    /// Amplify is not configured, no user is signed in, or the user id is not a UUID.
    func resolveAppAccountToken() async -> UUID? {
        guard GlacierApplicationDelegate.shared?.amplifyIsConfigured == true else { return nil }

        // getCurrentUser() reads local Cognito state (no network round-trip), but bound it with a
        // short timeout anyway so the purchase sheet is never delayed on a bad connection. On
        // timeout, error, or a non-UUID id we return nil and purchase without the token. The
        // base plan can still be attributed afterwards by its original transaction ID, because
        // it POSTs one to apple/validate-receipt; the phone add-on has no such link, so an
        // untokened add-on purchase stays unattributed until a reconcile pass picks it up.
        return await withTaskGroup(of: UUID?.self) { group in
            group.addTask {
                do {
                    let user = try await Amplify.Auth.getCurrentUser()
                    return UUID(uuidString: user.userId)
                } catch {
                    Log.general.info("[AppleSubLink] no signed-in user for appAccountToken — purchasing without it")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
