//
//  SKGlacierPhoneNumberPlanPurchaseService.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 07/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI
import StoreKit

/**
 SKGlacierPhoneNumberPlanPurchaseService connects to Apple StoreKit framework and provides APIs for,
 - Getting list of available phone number plans
 - Purchasing a phone number plan
 - Restoring previous purchase
 */
final class SKGlacierPhoneNumberPlanPurchaseService: GlacierPlanPurchaseService {

    // MARK: - Private properties
    
    private let productIdentifiers: Set<String>
    private var transactionListenerTask: Task<Void, Never>?

    // MARK: - Init / Deinit

    init() {
        productIdentifiers = Set(GlacierPhoneNumberSubscriptionPlan.allCases.map(\.rawValue))
        startTransactionListener()
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Public methods

    func loadAvailablePlans() async throws -> [Product] {
        let productIDs = Array(productIdentifiers)
        do {
            return try await withThrowingTaskGroup(of: [Product].self) { group in
                group.addTask {
                    let products = try await Product.products(for: productIDs)
                    return products.sorted {
                        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw GlacierPlanPurchaseError.errorLoadingPlanDetails
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            throw GlacierPlanPurchaseError.errorLoadingPlanDetails
        }
    }

    func purchasePlan(_ product: Product) async throws {
        let result = try await product.purchase()

        switch result {
        case .success(let verificationResult):
            let transaction = try verify(verificationResult)
            try await handleVerifiedTransaction(transaction)

        case .pending:
            throw GlacierPlanPurchaseError.pending

        case .userCancelled:
            throw GlacierPlanPurchaseError.userCancelled

        @unknown default:
            throw GlacierPlanPurchaseError.storeKitError(StoreKitError.unknown)
        }
    }

    func restorePurchase() async throws {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            throw GlacierPlanPurchaseError.storeKitError(error)
        }
    }

    @discardableResult
    func refreshEntitlements() async -> Bool {
        return await evaluateCurrentEntitlements()
    }

    // MARK: - Private methods

    private func startTransactionListener() {
        guard transactionListenerTask == nil else { return }

        transactionListenerTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            for await verificationResult in Transaction.updates {
                do {
                    let transaction = try self.verify(verificationResult)
                    try await self.handleVerifiedTransaction(transaction)
                } catch {
                    Log.general.error("Transaction update failed: \(error)")
                }
            }
        }
    }

    private func handleVerifiedTransaction(_ transaction: StoreKit.Transaction) async throws {
        guard productIdentifiers.contains(transaction.productID) else {
            await transaction.finish()
            return
        }

        // Guard against expired subscription transactions (same rationale as SKGlacierPlanPurchaseService).
        if let expirationDate = transaction.expirationDate, expirationDate < Date() {
            await transaction.finish()
            throw GlacierPlanPurchaseError.failedVerification
        }

        // Ignore superseded (revoked) transactions. When a subscription is upgraded within the
        // group (e.g. number1 -> number5), StoreKit refunds and revokes the previous subscription
        // and re-delivers that revoked transaction through Transaction.updates. Posting it would
        // clobber the just-stored higher tier back down to the old one — the exact cause of the
        // UI showing "Upgrade to add phone lines" after a successful upgrade. A revoked
        // transaction never reflects the currently-active entitlement, so drop it silently.
        if transaction.revocationDate != nil {
            await transaction.finish()
            return
        }

        // Highest-rank-wins guard. This per-transaction path (direct purchase + the background
        // Transaction.updates listener) must only ever confirm or RAISE the stored tier, never
        // lower it: individual transactions can arrive out of order or stale, and a lower-tier
        // event here would clobber a higher active plan. Authoritative lowering (e.g. a downgrade
        // that took effect at renewal) is handled exclusively by evaluateCurrentEntitlements(),
        // which inspects the full current-entitlement set and picks the max rank.
        let incomingRank = GlacierPhoneNumberSubscriptionPlan(rawValue: transaction.productID)?.rank ?? 0
        let storedRank = GlacierPhoneNumberSubscriptionPlan.activePlan?.rank ?? 0
        if incomingRank < storedRank {
            await transaction.finish()
            return
        }

        // Post success directly using the verified transaction we already have.
        // Calling evaluateCurrentEntitlements() here caused a race condition:
        // Transaction.currentEntitlements can lag on a first-ever purchase, returning
        // nil and triggering a false "purchase could not be completed" error even
        // though the purchase succeeded at the StoreKit level.
        //
        // Post on the main actor (same rationale as SKGlacierPlanPurchaseService).
        let productID = transaction.productID
        await MainActor.run {
            NotificationCenter.default.post(
                name: .phoneNumberPlanPurchaseVerified,
                object: nil,
                userInfo: [GlacierNotificationProperties.activePhoneNumberPlanId: productID]
            )
        }
        await transaction.finish()
    }

    private func verify(_ result: VerificationResult<StoreKit.Transaction>) throws -> StoreKit.Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified(_, _):
            throw GlacierPlanPurchaseError.failedVerification
        }
    }

    @MainActor
    private func evaluateCurrentEntitlements() async -> Bool {
        let identifiers = productIdentifiers  // Set<String> is Sendable

        // Same timeout pattern as SKGlacierPlanPurchaseService: run off the main actor
        // and race against 5 seconds.  This service is more susceptible than the base-plan
        // service because it must collect ALL matching transactions before returning the
        // highest-ranked one — it cannot exit early — so the sequence must fully terminate.
        // Returns (transaction, wasDefinitive) so callers can distinguish a timeout from
        // a confirmed empty result.
        let storeKitTask = Task.detached(priority: .userInitiated) { () -> StoreKit.Transaction? in
            var activeTransactions: [StoreKit.Transaction] = []
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result else { continue }
                if identifiers.contains(transaction.productID) {
                    activeTransactions.append(transaction)
                }
            }
            guard !activeTransactions.isEmpty else { return nil }
            return activeTransactions.max { lhs, rhs in
                let lhsRank = GlacierPhoneNumberSubscriptionPlan(rawValue: lhs.productID)?.rank ?? 0
                let rhsRank = GlacierPhoneNumberSubscriptionPlan(rawValue: rhs.productID)?.rank ?? 0
                return lhsRank < rhsRank
            }
        }

        let (activeTransaction, wasDefinitive) = await withTaskGroup(of: (StoreKit.Transaction?, Bool).self) { group in
            group.addTask { (await storeKitTask.value, true) }   // StoreKit finished — authoritative
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5-second timeout
                return (nil, false)                                 // Timeout — not authoritative
            }
            let result = await group.next()!
            group.cancelAll()
            storeKitTask.cancel()
            return result
        }

        guard let transaction = activeTransaction else {
            NotificationCenter.default.post(
                name: .phoneNumberPlanPurchaseVerificationFailed,
                object: nil,
                userInfo: nil
            )
            return wasDefinitive
        }

        NotificationCenter.default.post(
            name: .phoneNumberPlanPurchaseVerified,
            object: nil,
            userInfo: [
                GlacierNotificationProperties.activePhoneNumberPlanId: transaction.productID
            ]
        )
        return wasDefinitive
    }

    private func planRank(_ productId: String) -> Int {
        GlacierPhoneNumberSubscriptionPlan(rawValue: productId)?.rank ?? 0
    }
}
