//
//  HistoryScreenTab.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 01/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 HistoryScreenTab defines data/state for history screen tabs
 */
enum HistoryScreenTab: Identifiable {
    case callHistory
    case voicemail
    
    var title: String {
        switch self {
        case .callHistory: NSLocalizedString("Call history", comment: "History screen call history title")
        case .voicemail: NSLocalizedString("Voicemail", comment: "History screen voicemail title")
        }
    }
    
    var id: Self { return self }
}
