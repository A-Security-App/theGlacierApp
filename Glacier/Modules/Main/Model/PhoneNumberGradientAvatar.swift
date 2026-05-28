//
//  PhoneNumberGradientAvatar.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 26/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 PhoneNumberGradientAvatar defines set of gradient color patterns which are as avatars for user selected phone numbers.
 */
public enum PhoneNumberGradientAvatar: String, Identifiable, Codable {
    case blueGradient
    case megentaGradient
    case orangeGradient
    case greenGradient
    case pinkGradient
    
    public var colorStops: [Color] {
        switch self {
        case .blueGradient: return [.blue100, .blue20]
        case .megentaGradient: return [.megenta100, .megenta20]
        case .orangeGradient: return [.orange100, .orange20]
        case .greenGradient: return [.greenNeon100, .greenNeon20]
        case .pinkGradient: return [.pink100, .pink20]
        }
    }
    
    // It defines the oder of appearance for the gradient avatars
    public var orderNumber: Int {
        switch self {
        case .blueGradient: return 1
        case .megentaGradient: return 2
        case .orangeGradient: return 3
        case .greenGradient: return 4
        case .pinkGradient: return 5
        }
    }
    
    public var name: String { rawValue }
    public var id: Self { return self }
}
