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
import Alamofire
import Amplify

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

        // Attach the signed-in Glacier account's UUID (Cognito `sub`) as the App Store
        // appAccountToken so future App Store Server notifications about this subscription can be
        // mapped to the user. Resolving the token must never block the purchase: if no stable
        // UUID is available (session momentarily stale, federated identity, etc.), we purchase
        // without it — the backend link (linkAppleSubscription) still attributes the subscription
        // by its original transaction ID.
        var purchaseOptions: Set<Product.PurchaseOption> = []
        if let accountToken = await resolveAppAccountToken() {
            purchaseOptions.insert(.appAccountToken(accountToken))
        }
        let result = try await product.purchase(options: purchaseOptions)

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

        // Link the purchase to the signed-in Glacier account so the console/backend recognizes
        // this Apple subscription. Non-blocking on purpose: the transaction is already verified
        // and finished, so a link failure must never surface as a purchase error or strand the
        // transaction. Fired as an unstructured task calling the static linker so it completes
        // independently of this service instance's lifetime; any link that does not land here
        // (e.g. user not yet signed in) is retried by evaluateCurrentEntitlements on the next
        // refresh.
        Task.detached {
            await SKGlacierPlanPurchaseService.linkAppleSubscription(transaction)
        }
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

        // Link this verified Apple subscription to the signed-in Glacier account. Non-blocking on
        // purpose: this method runs on the interactive sign-in path (which holds a progress HUD
        // across the await in resolveSubscriptionStatus) as well as on background
        // launch/foreground/restore, and we must never make the user wait on this POST on a slow
        // network — a slow-connection hang here is a UX regression we have deliberately avoided.
        //
        // Awaiting buys nothing here: local access is already granted by StoreKit
        // (hasActiveSubscription is set true via .glacierPlanPurchaseVerified, and reconciliation
        // is appleBaseSubscribed || backendSubscribed, so the user is never sent to the paywall
        // regardless), and the link POST establishes the server-side linkage on its own — the
        // console reflects the user as paid once the POST lands, independent of when this app
        // next queries /mobile/status. Self-gates on auth: a no-op when the user isn't signed in
        // yet, and retried on the next entitlement refresh.
        //
        // Fired as an unstructured task calling the STATIC linker so the request completes even
        // though the enclosing SKGlacierPlanPurchaseService is a throwaway instance that
        // deallocates as soon as this method returns. (A prior `Task { [weak self] … }` captured
        // that transient instance weakly and dropped the link — the reliability bug this fixes.)
        Task.detached {
            await SKGlacierPlanPurchaseService.linkAppleSubscription(transaction)
        }

        return wasDefinitive
    }

    // MARK: - Apple subscription linking

    /// Request body for `POST apple/validate-receipt`.
    private struct AppleSubscriptionLinkRequest: Encodable {
        let transactionId: String
    }

    /// Links a verified StoreKit base-plan transaction to the signed-in Glacier account by
    /// sending its original transaction ID to the backend. This is intentionally non-throwing:
    /// linking is best-effort and must never break the purchase or entitlement-refresh flow.
    /// A missing endpoint or unavailable auth (user not signed in yet) is a no-op; the link is
    /// retried on the next entitlement refresh. Only base-plan transactions are sent here —
    /// phone-line add-ons are out of scope for this endpoint.
    ///
    /// `static` on purpose: this must run to completion independently of the calling service
    /// instance. Entitlement refresh creates throwaway `SKGlacierPlanPurchaseService()` instances
    /// (see resolveSubscriptionStatus / refreshBackendSubscription) that deallocate as soon as
    /// refreshEntitlements() returns. A previous `Task { [weak self] … }` captured that instance
    /// weakly and silently dropped the link when it deallocated — so existing-subscriber repairs
    /// never reached the backend. Being static (no `self`) plus an unstructured task decouples the
    /// request from instance lifetime while keeping it off the UI-gating path.
    private static func linkAppleSubscription(_ transaction: StoreKit.Transaction) async {
        guard let url = EndpointService.shared.appleSubscriptionValidationURL else {
            Log.general.error("[AppleSubLink] no validation URL configured — skipping link")
            return
        }

        guard let headers = await GlacierAPIHeaders.authHeaders() else {
            Log.general.info("[AppleSubLink] auth headers unavailable — deferring link to next refresh")
            return
        }

        let body = AppleSubscriptionLinkRequest(transactionId: String(transaction.originalID))

        await withCheckedContinuation { continuation in
            GlacierPinningConfiguration.pinnedSession
                .request(url,
                         method: .post,
                         parameters: body,
                         encoder: JSONParameterEncoder.default,
                         headers: headers,
                         requestModifier: { $0.timeoutInterval = 15 })
                .validate()
                .response { response in
                    let statusCode = response.response?.statusCode ?? 0
                    switch response.result {
                    case .success:
                        Log.general.info("[AppleSubLink] linked Apple subscription (status \(statusCode))")
                    case .failure(let error):
                        // Includes 4xx/5xx (validate() fails non-2xx) and transport errors.
                        // Left as best-effort: a locally-verified entitlement still grants access,
                        // and the link retries on the next refresh.
                        Log.general.notice("[AppleSubLink] link request failed (status \(statusCode)): \(error)")
                    }
                    continuation.resume()
                }
        }
    }

    /// Resolves the current Glacier account's stable UUID (Cognito `sub`) for use as the App Store
    /// `appAccountToken`. Returns `nil` — never blocks or throws into the purchase flow — when
    /// Amplify is not configured, no user is signed in, or the user id is not a UUID.
    private func resolveAppAccountToken() async -> UUID? {
        guard GlacierApplicationDelegate.shared?.amplifyIsConfigured == true else { return nil }

        // getCurrentUser() reads local Cognito state (no network round-trip), but bound it with a
        // short timeout anyway so the purchase sheet is never delayed on a bad connection. On
        // timeout, error, or a non-UUID id we return nil and purchase without the token — the
        // backend link still attributes the subscription by its original transaction ID.
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
