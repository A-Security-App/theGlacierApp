//
//  DeepLinkTarget.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 27/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 DeepLinkTarget enum defines target workflows for the deep links passed to the app
 */
enum DeepLinkTarget: Equatable {
    case openSecurityApp(userName: String, confirmationCode: String)
    case resetSecurityApp(confirmationCode: String)
    /// Regular-login email code. Carries only the code: it answers the pending
    /// Cognito custom-auth session that already knows the user, so no username is
    /// needed (or wanted) in the link.
    case loginSecurityApp(confirmationCode: String)

    /**
     Converts raw URLs into typed targets
     */
    ///
    /// No route changes protection. Any app or web page can open a custom-scheme URL, so
    /// VPN and Secure DNS are switched only from inside the app, behind its confirmation,
    /// or by VPNDNSToggleIntent, which requires an unlocked device.
    static func from(url: URL) -> DeepLinkTarget? {
        // Console links (email confirmation, password reset, login code) arrive as universal
        // links, which are always https. Only those are accepted, so codes can't arrive
        // through a custom scheme that any app can open.
        guard url.scheme?.lowercased() == "https", url.host == "console.theglacierapp.com" else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems

        switch url.path {
        case DeepLinkPath.openSecurityApp.value:
            guard let userName = queryItems?.first(where: { $0.name == DeepLinkProperties.userId.value })?.value,
                  let confirmationCode = queryItems?.first(where: { $0.name == DeepLinkProperties.code.value })?.value else {
                return nil
            }
            return .openSecurityApp(userName: userName, confirmationCode: confirmationCode)
        case DeepLinkPath.resetSecurityApp.value:
            guard let confirmationCode = queryItems?.first(where: { $0.name == DeepLinkProperties.code.value })?.value else {
                return nil
            }
            return .resetSecurityApp(confirmationCode: confirmationCode)
        case DeepLinkPath.loginSecurityApp.value:
            guard let confirmationCode = queryItems?.first(where: { $0.name == DeepLinkProperties.code.value })?.value else {
                return nil
            }
            return .loginSecurityApp(confirmationCode: confirmationCode)
        default:
            return nil
        }
    }
}

/**
 DeepLinkProperties defines various property names that are passed as query parameters
 */
enum DeepLinkPath: String {
    case openSecurityApp
    case resetSecurityApp
    case loginSecurityApp

    var value: String {
        switch self {
        case .openSecurityApp: return "/open-securityapp"
        case .resetSecurityApp: return "/reset-securityapp"
        case .loginSecurityApp: return "/login-securityapp"
        }
    }
}

/**
 DeepLinkProperties defines various property names that are passed as query parameters
 */
enum DeepLinkProperties: String {
    case email
    case userId
    case code
    
    var value: String {
        switch self {
        case .email: return "email"
        case .userId: return "userid"
        case .code: return "code"
        }
    }
}
