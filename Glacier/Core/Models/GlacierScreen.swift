//
//  GlacierScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 GlacierScreen defines screens that are presented at the application root level
 */
enum GlacierScreen: Identifiable, Hashable {

    case userAuthentication
    case userAccountConfirmation
    case userOnboarding
    case main
    case settings
    case vpnSettings
    case wifiSettings
    case cellularSetup
    case wifiSetup
    case enableCellular(EnableCellularVM)
    case enableVPN(EnableVPNVM)
    case managePhoneNumbers
    case phoneCall(PhoneCallVM)
    case voicemailDetails(VoicemailRecord)

    var id: String {
        switch self {
        case .userAuthentication: return "userAuthentication"
        case .userAccountConfirmation: return "userAccountConfirmation"
        case .userOnboarding: return "userOnboarding"
        case .main: return "main"
        case .settings: return "settings"
        case .vpnSettings: return "vpnSettings"
        case .wifiSettings: return "wifiSettings"
        case .cellularSetup: return "cellularSetup"
        case .wifiSetup: return "wifiSetup"
        case .enableCellular(let viewModel):
            return "enableCellular_\(ObjectIdentifier(viewModel))"
        case .enableVPN(let viewModel):
            return "enableVPN_\(ObjectIdentifier(viewModel))"
        case .managePhoneNumbers: return "managePhoneNumbers"
        case .phoneCall(let viewModel):
            return "phoneCall_\(ObjectIdentifier(viewModel))"
        case .voicemailDetails(let voiceMail):
            return "voicemailDetails_\(ObjectIdentifier(voiceMail))"
        }
    }

    var name: String {
        switch self {
        case .userAuthentication: return "userAuthentication"
        case .userAccountConfirmation: return "userAccountConfirmation"
        case .userOnboarding: return "userOnboarding"
        case .main: return "main"
        case .settings: return "settings"
        case .vpnSettings: return "vpnSettings"
        case .wifiSettings: return "wifiSettings"
        case .cellularSetup: return "cellularSetup"
        case .wifiSetup: return "wifiSetup"
        case .enableCellular(_): return "enableCellular"
        case .enableVPN(_): return "enableVPN"
        case .managePhoneNumbers: return "managePhoneNumbers"
        case .phoneCall(_): return "phoneCall"
        case .voicemailDetails(_): return "voicemailDetails"
        }
    }

    static func == (lhs: GlacierScreen, rhs: GlacierScreen) -> Bool {
        lhs.id == rhs.id
    }
}
