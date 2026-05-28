//
//  String+CommonStrings.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 29/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 This extension defines common strings used across different modules
 */
extension String {

    static var errorText: String {
        NSLocalizedString("Error", comment: "Error text")
    }

    static var successText: String {
        NSLocalizedString("Success", comment: "Success text")
    }
    
    static var okText: String {
        NSLocalizedString("Ok", comment: "Ok text")
    }
    
    static var cancelText: String {
        NSLocalizedString("Cancel", comment: "Cancel text")
    }
    
    static var tryAginText: String {
        NSLocalizedString("Please try again.", comment: "Try again text")
    }
    
    //No Wi-Fi Connection
    static var wifiText: String {
        NSLocalizedString("No Wi-Fi Connection", comment: "No Wi-Fi Connection text")
    }
}
