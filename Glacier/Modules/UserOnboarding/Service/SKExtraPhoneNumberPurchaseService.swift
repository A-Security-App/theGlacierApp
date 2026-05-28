//
//  SKExtraPhoneNumberPurchaseService.swift
//  Glacier
//
//  Handles the one-time $2.99 consumable purchase that lets a user add a phone number
//  after exhausting the free-slot allocation included in their subscription plan.
//
//  This service does NOT conform to GlacierPlanPurchaseService because consumable
//  transactions have no persistent entitlement — there is nothing to restore or
//  re-evaluate on launch.
//

import Foundation
import StoreKit

final class SKExtraPhoneNumberPurchaseService {

    // MARK: - Public methods

    /// Fetches the consumable product from the App Store.
    /// - Throws: `GlacierPlanPurchaseError.errorLoadingPlanDetails` if the product
    ///   cannot be loaded (e.g. product not configured in App Store Connect yet).
    func loadProduct() async throws -> Product {
        let products = try await Product.products(for: [GlacierExtraPhoneNumberProduct.productIdentifier])
        guard let product = products.first else {
            throw GlacierPlanPurchaseError.errorLoadingPlanDetails
        }
        return product
    }

    /// Initiates the consumable StoreKit purchase and verifies the transaction.
    ///
    /// On success the transaction is immediately finished so the App Store does not
    /// re-deliver it. The caller is responsible for granting the purchased content
    /// (i.e. calling `TwilioBackendManager.purchaseNumber`).
    ///
    /// - Throws: `GlacierPlanPurchaseError.userCancelled` if the user dismisses the
    ///   payment sheet, or other `GlacierPlanPurchaseError` values on failure.
    func purchaseExtraNumber() async throws {
        let product = try await loadProduct()
        let result = try await product.purchase()

        switch result {
        case .success(let verificationResult):
            let transaction = try verify(verificationResult)
            await transaction.finish()

        case .pending:
            throw GlacierPlanPurchaseError.pending

        case .userCancelled:
            throw GlacierPlanPurchaseError.userCancelled

        @unknown default:
            throw GlacierPlanPurchaseError.storeKitError(StoreKitError.unknown)
        }
    }

    // MARK: - Private helpers

    private func verify(_ result: VerificationResult<StoreKit.Transaction>) throws -> StoreKit.Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified:
            throw GlacierPlanPurchaseError.failedVerification
        }
    }
}
