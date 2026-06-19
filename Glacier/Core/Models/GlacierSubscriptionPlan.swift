//
//  GlacierSubscriptionPlan.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 GlacierSubscriptionPlan defines available glacier plans for purchase.
 It also returns reference of the user purchased glacier plan.
 */
enum GlacierSubscriptionPlan: String, CaseIterable {
    case yearly = "com.glacier.secapp.sub.yearly"
    case monthly = "com.glacier.secapp.sub.monthly"
}

extension GlacierSubscriptionPlan {
    static var activePlan: GlacierSubscriptionPlan? {
        guard let activePlanId: String = UserDefaultsService.shared.get(for: \.activeGlacierSubscriptionPlanId),
              let plan = GlacierSubscriptionPlan(rawValue: activePlanId) else {
            return nil
        }
        return plan
    }
}
