//
//  GlacierPlanPurchaseError.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 05/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

enum GlacierPlanPurchaseError: LocalizedError {
    case errorLoadingPlanDetails
    case failedVerification
    case pending
    case userCancelled
    case storeKitError(Error)

    var errorDescription: String? {
        switch self {
        case . errorLoadingPlanDetails:
            return nil
        case .failedVerification:
            return String("We couldn’t verify your purchase. Please try again.")
        case .pending:
            return String("Your purchase is pending. It may take a moment to complete.")
        case .userCancelled:
            return nil
        case .storeKitError(let error):
            let fallback = String("We couldn’t complete your request. Please try again later.")
            let description = error.localizedDescription
            return description.isEmpty ? fallback : description
        }
    }
}
