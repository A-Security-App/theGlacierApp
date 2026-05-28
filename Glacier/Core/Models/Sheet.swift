//
//  Sheet.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 Sheet defines screen types that are presented as sheet view over the application root
 */
enum Sheet: Identifiable, Hashable {
    case userRegistration
    case userLogin
    case passwordReset
    case glacierPlanPurchase
    case phoneNumberPlanPurchase
    case phoneNumberSelection(Bool)
    case connectionTypeSelection
    case appearanceSettings
    case widgetSettings

    var id: Self {
        return self
    }
    
    var name: String {
        switch self {
        case .userRegistration: "userRegistration"
        case .userLogin: "userLogin"
        case .passwordReset: "passwordReset"
        case .glacierPlanPurchase: "glacierPlanPurchase"
        case .phoneNumberPlanPurchase: "phoneNumberPlanPurchase"
        case .phoneNumberSelection(_): "phoneNumberSelection"
        case .connectionTypeSelection: "connectionTypeSelection"
        case .appearanceSettings: "appearanceSettings"
        case .widgetSettings: "widgetSettings"
        }
    }
}
