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
    
    /// Appended to every "select Glacier in iOS Settings" popup. A Settings app already running
    /// in the background keeps showing the DNS list it loaded earlier, so a profile we just saved
    /// isn't listed until Settings is relaunched.
    static var dnsSettingsReopenTip: String {
        NSLocalizedString("Don't see Glacier? Swipe Settings closed and open it again.", comment: "Tip under the select-Glacier-DNS-in-Settings steps")
    }

    //No Wi-Fi Connection
    static var wifiText: String {
        NSLocalizedString("No Wi-Fi Connection", comment: "No Wi-Fi Connection text")
    }
}
