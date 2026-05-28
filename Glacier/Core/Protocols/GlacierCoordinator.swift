//
//  GlacierCoordinator.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 GlacierCoordinator defines common requirements for concrete screen coordinators that manages screen navigation/presentation flows.
 */
protocol GlacierCoordinator: AnyObject {
    
    /**
     Screen associated type represents enumerations (Ex: GlacierScreen, Sheet, etc) with defined screens for presentation and navigation.
     */
    associatedtype Screen
    
    /**
     Path is used to push new screens over the current screen and to dismiss the same.
     `currentScreen` property represents the currently showing screen and the newly presented screen is referred to as `presentedScreen`
     */
    var path: NavigationPath { get set }
    
    /**
     It respresents the screen currently being shown.
     */
    var currentScreen: Screen? { get }
    
    /**
     It represents the screen that is presented over the currentScreen.
     */
    var presentedScreen: Screen? { get }

    /**
     This is called to replace the currently showing screen with new screen.
     For example: replacing user authentication screen with user onboarding screen, replacing user onboarding screen with home screen.
     */
    func setScreen(_ screen:  Screen)
    
    /**
     This is called to bring in new screen over the current screen.
     For example: Bringing in settings screen over the home screen.
     */
    func presentScreen(_ screen: Screen)
    
    /**
     This is called to dismiss the presented screen over the current screen.
     For example: Dismissing the settings screen, displaying over the home screen.
     */
    func dismissPresentedScreen()
}
