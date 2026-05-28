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
    /// Legacy iOS 16 widget button: glacierapp://vpn/toggle
    case vpnToggle
    /// Widget button — disconnect whatever is currently active: glacierapp://widget/disconnect
    case widgetDisconnect
    /// Widget button — reconnect to the last used type: glacierapp://widget/connect
    case widgetConnect

    /**
     It converts raw URLs into typed targets
     */
    static func from(url: URL) -> DeepLinkTarget? {
        // Widget action deep links — host "widget"
        if url.host == "widget" {
            if url.path == "/disconnect" { return .widgetDisconnect }
            if url.path == "/connect"    { return .widgetConnect }
        }

        // Legacy widget deep link — host "vpn", path "/toggle"
        if url.host == "vpn" && url.path == "/toggle" {
            return .vpnToggle
        }

        guard url.host == "console.theglacierapp.com" else { return nil }

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
    
    var value: String {
        switch self {
        case .openSecurityApp: return "/open-securityapp"
        case .resetSecurityApp: return "/reset-securityapp"
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
