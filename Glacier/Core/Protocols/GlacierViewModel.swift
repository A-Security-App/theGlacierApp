//
//  GlacierViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 21/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import UIKit
import Foundation

/**
 GlacierViewModel defines common requirements for the view models
 */
protocol GlacierViewModel: AnyObject {
    func openTermsOfUseURL()
    func openPrivacyPolicyURL()
}

/**
 Defining common functionality that may be needed by different view models
 */
extension GlacierViewModel {
    func openTermsOfUseURL() {
        let tosUrl: String? = UIApplication.shared.getValue(for: "TermsOfUseURL")
        guard let url = tosUrl else {
            return
        }
        UIApplication.shared.openURL(url)
    }
    
    func openPrivacyPolicyURL() {
        let privacyPolicyUrl: String? = UIApplication.shared.getValue(for: "PrivacyPolicyURL")
        guard let url = privacyPolicyUrl else {
            return
        }
        UIApplication.shared.openURL(url)
    }
}
