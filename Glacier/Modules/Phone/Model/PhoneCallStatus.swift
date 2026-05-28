//
//  PhoneCallStatus.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 02/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 PhoneCallStatus defines all possible states for a Twilio call
 */
enum PhoneCallStatus {
    case connecting
    case ringing
    case connected
    case ended

    var label: String {
        switch self {
        case .connecting: return NSLocalizedString("Connecting", comment: "Phone call screen connecting status")
        case .ringing: return NSLocalizedString("Ringing...", comment: "Phone call screen ringing status")
        case .connected: return NSLocalizedString("Connected", comment: "Phone call screen connected status")
        case .ended: return NSLocalizedString("Ended", comment: "Phone call screen ended status")
        }
    }
}
