//
//  GlacierPlanPurchaseService.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 08/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import StoreKit

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
