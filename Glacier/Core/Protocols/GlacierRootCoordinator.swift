//
//  GlacierRootCoordinator.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 `GlacierRootCoordinator` is an extension to the `GlacierCoordinator` and defines the common requirements for
 concrete coordinators that manages screen presentation/navigation over the root screen.
 
 Global screens like these are presented and managed by GlacierRootCoordinator,
 - Popups
 - Sheet
 - Full screen cover
 - Progress indicator
 */
protocol GlacierRootCoordinator: GlacierCoordinator {
    
    /**
     Type of sheet to present over the current screen.
     */
    var sheet: Sheet? { get set }
    
    /**
     It removes all of the presented screen to show the root screen.
     */
    func presentRootScreen()
    
    /**
     It presents given sheet type as the sheet view over the current screen
     */
    func presentSheet(_ sheet: Sheet)
    
    /**
     It dismisses the presented sheet view
     */
    func dismissSheet()
    
    /**
     It presents the popup view (alerts, confirmation, input field, etc) over the current screen
     */
    func presentPopup(with configuration: PopupConfiguration)
    
    /**
     It dismisses the presented popup view
     */
    func dismissPopup()
    
    /**
     It displays the progress indicator over the curren screen
     */
    func presentProgressIndicator()
    
    /**
     It hides the presented progress indicator
     */
    func dismissProgressIndicator()
}
