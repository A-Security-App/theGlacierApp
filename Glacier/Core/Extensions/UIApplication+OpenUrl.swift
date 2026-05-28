//
//  UIApplication+DismissKeyboard.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 23/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import UIKit

extension UIApplication {
    
     /// Returns URL string for the iOS settings app root view
    static var settingsRootURL: String {
        "App-Prefs:"
    }
    
    /// Boolean flag that tells if its a debug or TestFlight build.
    static func isDebugOrTestFlight() -> Bool {
    #if DEBUG
        return true
    #else
        if let receiptURL = Bundle.main.appStoreReceiptURL {
            return receiptURL.lastPathComponent == "sandboxReceipt"
        }
        return true
    #endif
    }
    
    /// Opens the given URL string in the default browser.
    func openURL(_ urlString: String) {
        guard let url = URL(string: urlString), canOpenURL(url) else {
            return
        }
        open(url, options: [:], completionHandler: nil)
    }
}

extension UIApplication {
    
    /// Returns value of given type for the given Info.plist key.
    func getValue<T>(for key: String) -> T? {
        Bundle.main.object(forInfoDictionaryKey: key) as? T
    }
}

extension UIApplication {
    
    /// Call this method to dismiss active keyboard from anywhere.
    func dismissKeyboard() {
        sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil)
    }
}
