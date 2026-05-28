//
//  PhoneNumberMenuCoordinator.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 01/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 PhoneNumberMenuCoordinator defines APIs that confirming types can call to work with
 phone number menu popup showing over the main screen. Any view, view model or other types
 can confirm to this protocol and use predefined APIs like `hidePhoneNumberMenu()`.
 */
protocol PhoneNumberMenuCoordinator {
    func hidePhoneNumberMenu()
}

extension PhoneNumberMenuCoordinator {
    func hidePhoneNumberMenu() {
        NotificationCenter.default.post(
            name: .hidePhoneNumberMenuView,
            object: nil
        )
    }
}
