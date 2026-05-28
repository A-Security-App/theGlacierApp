//
//  OnboardingScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 `OnboardingScreen` defines different screens for the user onboarding flow.
 */
enum OnboardingScreen: String, Identifiable {
    case userOnboardingHome
    case dnsSetup
    case vpnSetup
    case trustedNetworksSetup
    case phoneNumberPlanPurchaseHome
    case userPermissions
    case phoneNumberSelectionHome
    
    var id: Self { return self }
    var name: String { return rawValue }
}
