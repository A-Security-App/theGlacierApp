//
//  DeviceSecuritySetting.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 DeviceSecuritySetting represents iOS security settings like passcode, face id, etc and its
 real tme enabled/disabled state.
 */
struct DeviceSecuritySetting: Identifiable, Hashable {
    let id: String = UUID().uuidString
    let type: DeviceSecuritySettingType
    var isEnabled: Bool
}

/**
 DeviceSecuritySettingType defines security related iPhone settings that are required
 to make iPhone secured.
 */
enum DeviceSecuritySettingType: CaseIterable, Hashable {
    
    static var allCases: [DeviceSecuritySettingType] = [
        .screenLock,
        .bioMetrics,
        .glacierAndiOSVersionUpdated
    ]
    
    case screenLock
    case bioMetrics
    case glacierAndiOSVersionUpdated
    
    var title: String {
        switch self {
        case .screenLock: return NSLocalizedString(
            "Screen Lock",
            comment: "Device security settings screen lock"
        )
        case .bioMetrics: return NSLocalizedString(
            "Biometrics",
            comment: "Device security settings screen biometrics"
        )
        case .glacierAndiOSVersionUpdated: return NSLocalizedString(
            "Glacier & iOS Version",
            comment: "Device security settings screen glacier & iOS version"
        )
        }
    }
    
    var actionButtonTitle: String {
        switch self {
        case .screenLock, .bioMetrics:
            return NSLocalizedString(
                "Enable",
                comment: "Device security settings screen enable button title"
            )
        case .glacierAndiOSVersionUpdated:
            return NSLocalizedString(
                "Update",
                comment: "Device security settings screen update button title"
            )
        }
    }
    
    var popupTitle: String {
        switch self {
        case .screenLock: return NSLocalizedString(
            "Enable Screen Lock",
            comment: "Device security settings screen enable screen lock title"
        )
        case .bioMetrics: return NSLocalizedString(
            "Enable Biometrics",
            comment: "Device security settings screen enable biometrics title"
        )
        case .glacierAndiOSVersionUpdated: return NSLocalizedString(
            "Update Glacier iOS",
            comment: "Device security settings screen update glacier version title"
        )
        }
    }
    
    var popupDescription: String {
        switch self {
        case .screenLock: return NSLocalizedString(
            "Open Settings \n→ Display & Brightness \n→ Auto-Lock",
            comment: "Device security settings screen enable screen lock description"
        )
        case .bioMetrics: return NSLocalizedString(
            "Open Settings \n→ Select Face ID & Passcode",
            comment: "Device security settings screen enable biometrics description"
        )
        case .glacierAndiOSVersionUpdated: return NSLocalizedString(
            "Open the App Store \n→ Go to Account \n→ Scroll down to see “Updates” \n→ Find Glacier \n→ Tap “Update”",
            comment: "Device security settings screen update glacier version description"
        )
        }
    }
}
