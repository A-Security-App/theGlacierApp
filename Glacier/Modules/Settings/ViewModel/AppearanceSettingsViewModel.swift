//
//  AppearanceSettingsViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 03/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 AppearanceSettingsViewModel defines requirements for AppearanceSettingsScreen view models
 */
protocol AppearanceSettingsViewModel: AnyObject {
    var schemes: [ColorSchemeType] { get }
    var selectedScheme: ColorSchemeType { get set }
    var glacierColorScheme: GlacierColorScheme? { get set }
}

/**
 AppearanceSettingsVM defines data/state and business logic for AppearanceSettingsScreen
 */
final class AppearanceSettingsVM: AppearanceSettingsViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var schemes: [ColorSchemeType] = [.system, .light, .dark]
    @Published var selectedScheme: ColorSchemeType {
        didSet {
            UserDefaultsService.shared.set(selectedScheme.rawValue, for: \.userSelectedColorScheme)
            glacierColorScheme?.setScheme(userSelectedColorScheme: selectedScheme)
        }
    }
    
    var glacierColorScheme: GlacierColorScheme?
    
    // MARK: - Initializer
    
    init() {
        guard let colorScheme: String = UserDefaultsService.shared.get(for: \.userSelectedColorScheme),
              let userSelectedColorScheme = ColorSchemeType(rawValue: colorScheme) else {
            selectedScheme = .system
            return
        }
        selectedScheme = userSelectedColorScheme
    }
}
