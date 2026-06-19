//
//  GlacierPhoneNumberSubscriptionPlan.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 GlacierPhoneNumberSubscriptionPlan defines available phone number plans for purchase.
 It also returns reference of the user purchased phone number plan.
 */
enum GlacierPhoneNumberSubscriptionPlan: String, CaseIterable {
    case oneNumber = "com.glacier.secapp.addon.number1"
    case twoNumbers = "com.glacier.secapp.addon.number2"
    case fiveNumbers = "com.glacier.secapp.addon.number5"
    
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
}
