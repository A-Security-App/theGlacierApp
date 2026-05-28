//
//  SlidingCard.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 02/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 SlidingCard provides data/state for swiping cards.
 */
enum SlidingCard: Int, CaseIterable, Identifiable {
    case privacy, protection, anonymity
    
    var id: Int { self.rawValue }
    
    var title: String {
        switch self {
        case .privacy: return NSLocalizedString("Browse privately, ad-free.", comment: "Slideing card privacy title")
        case .protection: return NSLocalizedString("Know you’re protected.", comment: "Slideing card protection title")
        case .anonymity: return NSLocalizedString("Make calls anonymously.", comment: "Slideing card anonymity title")
        }
    }
    
    var subtitle: String {
        switch self {
        case .privacy: return NSLocalizedString("VPN and DNS protection for safer browsing—from anywhere.", comment: "Slideing card privacy subtitle")
        case .protection: return NSLocalizedString("Get alerts and recommendations to ensure your device is secure.", comment: "Slideing card protection description")
        case .anonymity: return NSLocalizedString("Conversations will never point back to you.", comment: "Slideing card anonymity description")
        }
    }
    
    var lottieAnimationName: String? {
        switch self {
        case .privacy: return "glacier-DNS-VPN"
        case .protection: return nil
        case .anonymity: return "glacier-ringing"
        }
    }
    
    var graphicsName: String? {
        switch self {
        case .protection: return "glacier-alerts"
        case .privacy, .anonymity: return nil
        }
    }
    
    var mediaName: String {
        switch self {
        case .privacy: return "browse-privately"
        case .protection: return "know-you-are-protected"
        case .anonymity: return "anonimity"
        }
    }
    
    var isVideo: Bool {
        return self != .anonymity
    }
    
    var horizontalPadding: CGFloat {
        switch self {
        case .privacy: return 15
        case .protection: return 16
        case .anonymity: return 14
        }
    }
}
