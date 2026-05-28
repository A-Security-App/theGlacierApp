//
//  PasswordResetScreens.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 29/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 PasswordResetScreens defines screen types for password reset workflows.
 */
enum PasswordResetScreens: Identifiable, Hashable {
    case passwordReset
    case newPasswordInput(userName: String, confirmationCode: String)
    
    var id: String { "\(self.hashValue)" }
}
