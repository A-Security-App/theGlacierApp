//
//  ColorSchemeType.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 03/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

enum ColorSchemeType: String, Hashable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    var title: String {
        switch self {
        case .system: NSLocalizedString("Device Settings", comment: "Color appearance system title")
        case .light: NSLocalizedString("Light", comment: "Color appearance light title")
        case .dark: NSLocalizedString("Dark", comment: "Color appearance dark title")
        }
    }
    
    var description: String {
        switch self {
        case .system: NSLocalizedString("Use your device’s default mode.", comment: "Color appearance system description")
        case .light: NSLocalizedString("Always use light mode.", comment: "Color appearance light description")
        case .dark: NSLocalizedString("Always use dark mode.", comment: "Color appearance dark description")
        }
    }
}
