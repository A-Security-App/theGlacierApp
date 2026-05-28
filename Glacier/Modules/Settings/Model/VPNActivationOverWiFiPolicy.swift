//
//  VPNActivationOverWiFiPolicy.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 21/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 VPNActivationOverWiFiPolicy defines options for,
 - Activating VPN connection on all networks
 - Deactivating VPN connection on trusted networks
 
 These options are presented in UI so that users could set desired policy for VPN activation over wifi networkds.
 */
enum VPNActivationOverWiFiPolicy: String, CaseIterable, Hashable {
    
    case activeOnAllNetworks
    case offOnTrustedNetworks
    
    var title: String {
        switch self {
        case .activeOnAllNetworks: NSLocalizedString(
            "Active on all networks",
            comment: "VPN active on all wifi networks title"
        )
        case .offOnTrustedNetworks: NSLocalizedString(
            "Off on trusted networks",
            comment: "VPN inactive on trusted wifi networks title"
        )
        }
    }
    
    var description: String {
        switch self {
        case .activeOnAllNetworks: NSLocalizedString(
            "VPN stays on, no matter which Wi-Fi you join.",
            comment: "VPN active on all wifi networks description"
        )
        case .offOnTrustedNetworks: NSLocalizedString(
            "VPN turns off when you're connected to a network you trust.",
            comment: "VPN inactive on trusted wifi networks description"
        )
        }
    }
}
