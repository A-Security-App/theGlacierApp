//
//  SKGlacierPlanPurchaseService.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 04/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI
import StoreKit

/**
 SKGlacierPlanPurchaseService connects to Apple StoreKit framework and provides APIs for,
 - Getting list of available Glacier plans
 - Purchasing a plan
 - Restoring previous purchase
 */
final class SKGlacierPlanPurchaseService: GlacierPlanPurchaseService {

    // MARK: - Private properties
    
    private let productIdentifiers: Set<String>
    private var transactionListenerTask: Task<Void, Never>?

    // MARK: - Init / Deinit

    init() {
        productIdentifiers = Set(GlacierSubscriptionPlan.allCases.map(\.rawValue))
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
        await finishExpiredUnfinishedTransactions()
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

    // Finish any unfinished transactions whose subscription has already expired.
    // In sandbox, when renewal cycles are exhausted, StoreKit's product.purchase()
    // finds these stale transactions via TransactionQuery and hangs trying to validate
    // them against Apple's servers rather than returning immediately. Clearing them
    // first lets purchase() start from a clean slate and present a fresh payment sheet.
    private func finishExpiredUnfinishedTransactions() async {
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result else { continue }
            guard let expirationDate = transaction.expirationDate,
                  expirationDate < Date() else { continue }
            await transaction.finish()
        }
    }

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

        // Guard against StoreKit returning an already-expired subscription transaction.
        // This can happen in sandbox when renewal cycles are exhausted: product.purchase()
        // returns an old unfinished transaction (no payment sheet) rather than creating a
        // new subscription. The JWS signature is valid so verify() passes, but the
        // subscription period has already ended. Finishing and throwing here surfaces an
        // error alert rather than silently treating the expired transaction as a success.
        if let expirationDate = transaction.expirationDate, expirationDate < Date() {
            await transaction.finish()
            throw GlacierPlanPurchaseError.failedVerification
        }

        // Post success directly using the verified transaction we already have.
        // Calling evaluateCurrentEntitlements() here caused a race condition:
        // Transaction.currentEntitlements can lag on a first-ever purchase, returning
        // nil and triggering a false "purchase could not be completed" error even
        // though the purchase succeeded at the StoreKit level.
        //
        // Post on the main actor so that @objc NotificationCenter observers (which
        // are called synchronously on the posting thread) run on the main thread.
        // This prevents "Publishing changes from background threads" warnings from
        // any @Published properties touched inside the notification handler chain.
        let productID = transaction.productID
        await MainActor.run {
            NotificationCenter.default.post(
                name: .glacierPlanPurchaseVerified,
                object: nil,
                userInfo: [GlacierNotificationProperties.activeGlacierPlanId: productID]
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

    /// Returns `true` when StoreKit gave a definitive answer (sequence ended naturally),
    /// `false` when the 5-second timeout fired before StoreKit could respond.
    @MainActor
    private func evaluateCurrentEntitlements() async -> Bool {
        let identifiers = productIdentifiers  // Set<String> is Sendable

        // Run Transaction.currentEntitlements off the main actor (keeps StoreKit's
        // XPC calls to storeaccountd off the main thread) and race it against a
        // 5-second timeout.  The sequence has no built-in timeout: if Apple's servers
        // are slow or storeaccountd stalls (observed even with working internet), the
        // for-await hangs indefinitely, freezing the splash screen.
        //
        // The task group returns a (transaction, definitive) tuple so callers can
        // distinguish "StoreKit confirmed no entitlement" from "timeout fired before
        // StoreKit responded" — the latter must not be treated as a confirmed lapse.
        let storeKitTask = Task.detached(priority: .userInitiated) { () -> StoreKit.Transaction? in
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result,
                      identifiers.contains(transaction.productID) else { continue }
                return transaction
            }
            return nil
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
                name: .glacierPlanPurchaseVerificationFailed,
                object: nil,
                userInfo: nil
            )
            return wasDefinitive
        }

        NotificationCenter.default.post(
            name: .glacierPlanPurchaseVerified,
            object: nil,
            userInfo: [
                GlacierNotificationProperties.activeGlacierPlanId: transaction.productID
            ]
        )
        return wasDefinitive
    }
}
