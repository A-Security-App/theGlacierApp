//
//  FloatingTab.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 23/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 FloatingTab defines data for the FloatingTabBarView
 */
enum FloatingTab: String, CaseIterable, Hashable {
    case home = "Home"
    case phone = "Phone"
    case contacts = "Contacts"
    case history = "History"
    
    var icon: String {
        switch self {
        case .home: return "home-tab-icon"
        case .phone: return "phone-tab-icon"
        case .contacts: return "contacts-tab-icon"
        case .history: return "history-tab-icon"
        }
    }
    
    var title: String {
        switch self {
        case .home: return NSLocalizedString("Home", comment: "Floating tab bar home tab title")
        case .phone: return NSLocalizedString("Phone", comment: "Floating tab bar phone tab title")
        case .contacts: return NSLocalizedString("Contacts", comment: "Floating tab bar contacts tab title")
        case .history: return NSLocalizedString("History", comment: "Floating tab bar history tab title")
        }
    }
}
