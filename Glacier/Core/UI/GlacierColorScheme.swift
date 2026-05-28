//
//  GlacierColorScheme.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 17/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import UIKit
import SwiftUI

/**
 GlacierColorScheme keeps track of the active dark/light color scheme.
 On initialization, it checks if user has selected dark mode in the settings screen and sets dark/light mode accordingly.
 After initialization, it gets a call from the `GlacierAppRootScreen` to update active color scheme as dark/light color scheme is changed at iOS system level.
 
 It gives higher priority to the user settings for dark mode over the iOS system level dark/light mode setting. If user selects dark mode in setting screen but it's light mode at iOS system level, the active scheme would be set to dark not light. If user disables dark mode in the settings screen, only then iOS system level of dark/light mode setting would be used for setting activeScheme.
 */
final class GlacierColorScheme: ObservableObject {
    
    // MARK: - Public properties
    
    @Published private(set) var activeScheme: ColorScheme = .light
    
    /**
     Returns Lottie JSON file name for Glacier logo animation
     */
    var glacierLogoAnimationFile: String {
        switch activeScheme {
        case .light: "glacier-black"
        case .dark: "glacier-white"
        }
    }
    
    // MARK: - Initializer
    
    init() {
        guard let colorScheme: String = UserDefaultsService.shared.get(for: \.userSelectedColorScheme),
              let userSelectedColorScheme = ColorSchemeType(rawValue: colorScheme) else {
            setScheme(userSelectedColorScheme: ColorSchemeType.system)
            return
        }
        setScheme(userSelectedColorScheme: userSelectedColorScheme)
    }
    
    // MARK: - Public methods
    
    /**
     This is called when user toggles on/off dark mode from the `Settings` screen.
     If user enables dark mode, we need to ignore system level light/dark mode setting. Else, we need to use system level color scheme.
     */
    func setScheme(userSelectedColorScheme: ColorSchemeType) {
        switch userSelectedColorScheme {
        case .system: activeScheme = UIScreen.main.traitCollection.userInterfaceStyle == .light ? .light : .dark
        case .light: activeScheme = .light
        case .dark: activeScheme = .dark
        }
    }
    
    /**
     This is called when the color scheme is updated by the iOS system itself.
     We have to ignore this sytem update, If user enabled dark mode from the `Settings` screen.
     */
    func setScheme(_ scheme: ColorScheme) {
        guard let colorScheme: String = UserDefaultsService.shared.get(for: \.userSelectedColorScheme),
              let userSelectedColorScheme = ColorSchemeType(rawValue: colorScheme) else {
            self.activeScheme = scheme
            return
        }
        
        switch userSelectedColorScheme {
        case .system: activeScheme = scheme
        case .light: activeScheme = .light
        case .dark: activeScheme = .dark
        }
    }
}
