//
//  PhoneCallAudioRoute.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 02/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation


/**
 PhoneCallAudioRoute defines available audio routes which users can select for audio output
 */
enum PhoneCallAudioRoute {
    case speaker
    case microphone
    case bluetooth
    
    var label: String {
        switch self {
        case .speaker: return "Speaker"
        case .microphone: return "Microphone"
        case .bluetooth: return "Bluetooth"
        }
    }
    
    var icon: String {
        switch self {
        case .speaker: return "speaker-icon"
        case .microphone: return "phone-icon"
        case .bluetooth: return "bluetooth-icon"
        }
    }
}
