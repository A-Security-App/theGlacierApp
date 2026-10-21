//
//  GlacierPhoneNumberSubscriptionPlan.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import StoreKit

/**
 GlacierPhoneNumberSubscriptionPlan defines available phone number plans for purchase.
 It also returns reference of the user purchased phone number plan.
 */
enum GlacierPhoneNumberSubscriptionPlan: String, CaseIterable {
    case oneNumber = "com.glacier.secure.addon.number1"
    case twoNumbers = "com.glacier.secure.addon.number2"
    case fiveNumbers = "com.glacier.secure.addon.number5"
    
    var maxPhoneNumbers: Int {
        switch self {
        case .oneNumber: 1
        case .twoNumbers: 2
        case .fiveNumbers: 5
        }
    }
    
    // Rank tells which subscription to set as active when user has multiple subscriptions due to plan upgrade.
    var rank: Int {
        switch self {
        case .oneNumber: return 1
        case .twoNumbers: return 2
        case .fiveNumbers: return 5
        }
    }
}

extension GlacierPhoneNumberSubscriptionPlan {
    static var activePlan: GlacierPhoneNumberSubscriptionPlan? {
        guard let activePlanId: String = UserDefaultsService.shared.get(for: \.activePhoneNumberSubscriptionPlanId),
              let plan = GlacierPhoneNumberSubscriptionPlan(rawValue: activePlanId) else {
            return nil
        }
        return plan
    }

    /// Returns the plan whose `maxPhoneNumbers` matches `count`, or `nil` for 0 or unrecognized values.
    static func plan(forLineCount count: Int) -> GlacierPhoneNumberSubscriptionPlan? {
        allCases.first { $0.maxPhoneNumbers == count }
    }

    /// What StoreKit on this device says about the phone-line add-on.
    enum AppleEntitlement {
        /// The App Store account signed in on this device holds an active add-on.
        case active
        /// StoreKit answered, and that account holds none.
        case notHeld
        /// StoreKit didn't answer within the timeout.
        case unknown
    }

    /// Asks StoreKit directly whether this device's App Store account holds an active phone-line
    /// add-on. Unlike `GlacierAccountModel.hasActivePhoneNumberSubscription`, which merges Apple
    /// and backend grants, this answers only for Apple.
    ///
    /// `Transaction.currentEntitlements` is answered on the device, but it can be slow, so it's
    /// raced against `timeout` (the purchase service allows 5 seconds; a tap can't wait that
    /// long) and reports `.unknown` if StoreKit hasn't finished.
    static func appleEntitlement(timeout: TimeInterval = 1.5) async -> AppleEntitlement {
        let identifiers = Set(allCases.map(\.rawValue))
        let storeKitTask = Task.detached(priority: .userInitiated) { () -> AppleEntitlement in
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result else { continue }
                if identifiers.contains(transaction.productID) {
                    return .active
                }
            }
            return .notHeld
        }

        return await withTaskGroup(of: AppleEntitlement.self) { group in
            group.addTask { await storeKitTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .unknown
            }
            let result = await group.next() ?? .unknown
            group.cancelAll()
            storeKitTask.cancel()
            return result
        }
    }

    /// How recently an Apple add-on must have ended to count as this account's lapse rather than
    /// some other subscription. The backend keeps Apple lines for 3 days past expiry; this matches
    /// `SKGlacierPlanPurchaseService.didAccountSubscriptionEndRecently`'s window.
    static let recentAppleExpiryWindow: TimeInterval = 4 * 24 * 60 * 60

    /**
     Expiry of the most recent phone-line add-on that this device's Apple Account bought for this
     Glacier account, running or ended; `nil` when it bought none. Reads `Transaction.all`, which
     has no timeout of its own, so callers race it.

     A purchase counts when it carries this account's `appAccountToken`, or carries none: the
     add-on purchase proceeds without the token when it can't be resolved in time, so untokened
     add-ons are this account's as far as this device can tell.
     */
    static func latestAppleExpiry(accountToken: UUID?) async -> Date? {
        let identifiers = Set(allCases.map(\.rawValue))
        var latest: Date?
        for await result in Transaction.all {
            guard case .verified(let transaction) = result,
                  identifiers.contains(transaction.productID),
                  !transaction.isUpgraded,
                  transaction.appAccountToken == nil || transaction.appAccountToken == accountToken,
                  let expiration = transaction.expirationDate else { continue }
            if expiration > (latest ?? .distantPast) { latest = expiration }
        }
        return latest
    }

    /**
     Whether this device's Apple Account had an add-on for this Glacier account that ended
     recently. `nil` when it can't tell (StoreKit didn't answer within `timeout`).

     Tells apart the two reasons StoreKit may not hold lines the backend says Apple bills: they
     ended on this Apple Account and the backend's 3-day grace still counts them (`true`), or a
     different Apple Account bought them (`false`).
     */
    static func appleLinesEndedRecently(timeout: TimeInterval = 1.5) async -> Bool? {
        let historyTask = Task.detached(priority: .userInitiated) { () -> Bool in
            let accountToken = await SKGlacierPhoneNumberPlanPurchaseService().resolveAppAccountToken()
            guard let expiry = await latestAppleExpiry(accountToken: accountToken) else { return false }
            let now = Date()
            return expiry <= now && now.timeIntervalSince(expiry) <= recentAppleExpiryWindow
        }

        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await historyTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            historyTask.cancel()
            return result
        }
    }
}

/**
 A phone-line plan the App Store has scheduled to replace the current one at renewal.

 Apple applies a move to a smaller plan at the end of the period already paid for, so until
 `startsOn` the account keeps the plan in `Transaction.currentEntitlements` and only the renewal
 info names the new one. Without this, a downgrade looks like it did nothing.
 */
struct ScheduledPhonePlanChange: Equatable {
    let plan: GlacierPhoneNumberSubscriptionPlan
    let startsOn: Date
}

extension GlacierPhoneNumberSubscriptionPlan {
    /**
     The plan `transaction`'s subscription renews into, when that's a different phone-line plan and
     it will renew at all; `nil` otherwise. `transaction` should be the add-on's current entitlement.
     */
    static func scheduledChange(for transaction: StoreKit.Transaction) async -> ScheduledPhonePlanChange? {
        guard GlacierPhoneNumberSubscriptionPlan(rawValue: transaction.productID) != nil,
              let expiration = transaction.expirationDate,
              let status = await transaction.subscriptionStatus,
              case .verified(let renewal) = status.renewalInfo,
              renewal.willAutoRenew,
              let next = renewal.autoRenewPreference,
              next != transaction.productID,
              let plan = GlacierPhoneNumberSubscriptionPlan(rawValue: next) else { return nil }
        return ScheduledPhonePlanChange(plan: plan, startsOn: expiration)
    }

    /**
     The scheduled change for the add-on this device's Apple Account holds now, or `nil` when none
     is scheduled or it holds no add-on. Enumerates `Transaction.currentEntitlements` with no
     timeout of its own: callers must not block UI on it.
     */
    static func scheduledAppleChange() async -> ScheduledPhonePlanChange? {
        var current: StoreKit.Transaction?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil,
                  let plan = GlacierPhoneNumberSubscriptionPlan(rawValue: transaction.productID),
                  plan.rank > (current.flatMap { GlacierPhoneNumberSubscriptionPlan(rawValue: $0.productID) }?.rank ?? 0)
            else { continue }
            current = transaction
        }
        guard let current else { return nil }
        return await scheduledChange(for: current)
    }
}
