//
//  UserAuthenticationError.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 31/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 UserAuthenticationError defines user authentication related errors
 */
enum UserAuthenticationError: Error {
    case authenticationFailure
    case authenticationCancelled
    case general(String)
    
    var description: String {
        switch self {
        case .authenticationFailure:
            NSLocalizedString("Authentication failed. Please try again.", comment: "User authentication failure error message")
        case .authenticationCancelled:
            NSLocalizedString("Authentication cancelled. Please try again.", comment: "User authentication cancellation error message")
        case .general(let errorDescription):
            errorDescription
        }
    }
}
