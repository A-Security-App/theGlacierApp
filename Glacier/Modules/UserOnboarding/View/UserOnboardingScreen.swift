//
//  UserOnboardingScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 UserOnboardingScreen is a wrapper view for user onboarding screens.
 Based on `UserOnboardingCoordinator` currentScreen property, it sets the respective screen as active onboarding screen.
 */
struct UserOnboardingScreen: View {
   
    // MARK: - Private properties
    
    @StateObject private var userOnboardingCoordinator: UserOnboardingCoordinator
    
    // MARK: - Intializer
    
    init(rootCoordinator: any GlacierRootCoordinator) {
        self._userOnboardingCoordinator = StateObject(wrappedValue: UserOnboardingCoordinator(rootCoordinator: rootCoordinator))
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            if let screen = userOnboardingCoordinator.currentScreen {
                userOnboardingCoordinator.build(screen)
            }
        }
        .environmentObject(userOnboardingCoordinator)
    }
}

extension UserOnboardingScreen {
    static var shouldShowUserOnboarding: Bool {
        // When the process's UserDefaults cache was primed empty during a
        // pre-first-unlock background launch (e.g. the vpnHealth BGAppRefreshTask
        // firing after an overnight reboot), every read on the keys below
        // returns nil regardless of what's on disk. The Amplify self-heal in
        // GlacierApplicationDelegate+Extension.swift confirms a valid signed-in
        // session via the Keychain in that scenario — meaning the user is a
        // returning user whose on-disk onboarding state was previously set, not
        // a fresh sign-in. Treat the poisoned-cache reads as untrustworthy and
        // skip onboarding so the user lands on .main instead of being misrouted
        // to DNSSetupScreen.
        if GlacierApplicationDelegate.userDefaultsCachePoisoned {
            Log.auth.notice("[GlacierAuth] shouldShowUserOnboarding: returning false due to poisoned UserDefaults cache")
            return false
        }

        let didSkipPhoneNumberPurchase: Bool = UserDefaultsService.shared.get(for: \.didSkipPhoneNumberPurchaseDuringOnboarding) ?? false
        let didSkipPhoneSelection: Bool = UserDefaultsService.shared.get(for: \.didSkipPhoneNumberSelectionDuringOnboarding) ?? false
        let isUserOnboardingCompleted: Bool = UserDefaultsService.shared.get(for: \.isUserOnboardingCompleted) ?? false

        guard didSkipPhoneNumberPurchase || didSkipPhoneSelection else {
            return isUserOnboardingCompleted == false
        }
        return false
    }
}
