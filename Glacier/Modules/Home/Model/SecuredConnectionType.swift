//
//  SecuredConnectionType.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

enum SecuredConnectionType: String, CaseIterable, Hashable {
    case dns
    case vpn
    
    var label: String {
        switch self {
        case .dns: NSLocalizedString("DNS", comment: "Secured connection type DNS name")
        case .vpn: NSLocalizedString("VPN", comment: "Secured connection type VPN name")
        }
    }
    
    var title: String {
        switch self {
        case .dns: NSLocalizedString(
            "Standard",
            comment: "Secured connection type DNS title"
        )
        case .vpn: NSLocalizedString(
            "Extra Protection",
            comment: "Secured connection type VPN title"
        )
        }
    }
    
    var description: String {
        switch self {
        case .dns: NSLocalizedString(
            "Hides which sites you're visiting - faster connection, no ads, and enough privacy for everyday use.",
            comment: "Secured connection type DNS description"
        )
        case .vpn:
            NSLocalizedString(
                "Hides where you're going and everything you do along the way - ideal for public Wi-Fi, travel, and other untrusted networks, but can sometimes slow your connection or limit browsing.",
                comment: "Secured connection type VPN description"
            )
        }
    }
}
