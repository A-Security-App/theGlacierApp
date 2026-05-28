//
//  GlacierApp.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 10/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierApp is the main entry point for the application. It takes care of app level configuration and bootstraps the application.
 - Sets `GlacierAppRootScreen` as the app root screen that enacapsulates the entire UI/UX and related workflows of the application.
 - Sets `GlacierApplicationDelegate` as the app delegate that helps in managing application lifecycle events and setting up core modules.
 */
@main
struct GlacierApp: App {
    
    // MARK: - Configuration
    
    @UIApplicationDelegateAdaptor(GlacierApplicationDelegate.self) var delegate: GlacierApplicationDelegate
    
    // MARK: - Private properties

    @Environment(\.scenePhase) private var scenePhase
    @State private var previousScenePhase: ScenePhase = .active

    @StateObject private var glacierColorScheme = GlacierColorScheme()

    private let deepLinkService = DeepLinkService.shared
    
    // MARK: - UI/UX
    
    var body: some Scene {
        WindowGroup {
            GlacierAppRootScreen()
                .environmentObject(glacierColorScheme)
                .onOpenURL { url in
                    deepLinkService.handle(url: url)
                }
                .onReceive(deepLinkService.linkPublisher) { target in
                    handleRouting(for: target)
                }
                .onChange(of: scenePhase) { newPhase in
                    defer { previousScenePhase = newPhase }
                    switch newPhase {
                    case .inactive:
                        if previousScenePhase == .active {
                            delegate.applicationWillResignActive(UIApplication.shared)
                        } else if previousScenePhase == .background {
                            delegate.applicationWillEnterForeground(UIApplication.shared)
                        }
                    case .background:
                        delegate.applicationDidEnterBackground(UIApplication.shared)
                    case .active:
                        if previousScenePhase == .inactive {
                            delegate.applicationDidBecomeActive(UIApplication.shared)
                        }
                    @unknown default:
                        break
                    }
                }
        }
    }
    
    // MARK: - Private methods
    
    private func handleRouting(for target: DeepLinkTarget) {
        switch target {
        case .openSecurityApp(let userName, let confirmationCode):
            NotificationCenter.default.post(
                name: .userAccountConfirmationLinkClicked,
                object: nil,
                userInfo: [
                    GlacierNotificationProperties.userName: userName,
                    GlacierNotificationProperties.confirmationCode: confirmationCode
                ]
            )
        case .resetSecurityApp(let confirmationCode):
            NotificationCenter.default.post(
                name: .resetPasswordLinkClicked,
                object: nil,
                userInfo: [
                    GlacierNotificationProperties.confirmationCode: confirmationCode
                ]
            )
        case .vpnToggle:
            // Legacy iOS 16 widget button — HomeVM observes this and calls handleWidgetToggle()
            NotificationCenter.default.post(name: .widgetVPNDNSToggleRequested, object: nil)
        case .widgetDisconnect:
            NotificationCenter.default.post(name: .widgetDisconnectRequested, object: nil)
        case .widgetConnect:
            NotificationCenter.default.post(name: .widgetConnectRequested, object: nil)
        }
    }
}
