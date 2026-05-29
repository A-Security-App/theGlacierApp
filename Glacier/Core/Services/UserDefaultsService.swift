//
//  UserDefaultsService.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 17/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 LocalStorageService protocol defines requirements for concrete types that provide read/write services with UserDefaults API.
 */
protocol LocalStorageService {
    func set<Value: Codable>(_ value: Value, for keyPath: KeyPath<UserDefaultsService.LocalStorageKeys, String>)
    func get<Value: Codable>(for keyPath: KeyPath<UserDefaultsService.LocalStorageKeys, String>) -> Value?
    func remove(for keyPath: KeyPath<UserDefaultsService.LocalStorageKeys, String>)
}

/**
 `UserDefaultsService` helps save and get data from user device storage via UserDefaults API.
 */
final class UserDefaultsService: LocalStorageService {
    
    /**
     LocalStorageKeys defines keys for saving/loading data from the user defaults
     */
    struct LocalStorageKeys {
        // User authentication module
        var userEmail: String { "userEmail" }
        var userPassword: String { "userPassword" }
        var isUserAccountCreated: String { "isUserAccountCreated" }
        var isUserAccountConfirmed: String { "isUserAccountConfirmed" }
        var isUserLoggedIn: String { "isUserLoggedIn" }
        /// Stores the Amplify AuthProvider used for the current session (e.g. "apple", "google").
        /// Nil/absent means the user signed in with email/password (not Hosted UI).
        var hostedUIProvider: String { "hostedUIProvider" }
        
        // User onboarding module
        var isUserSubscribedToGlacierPlan: String { "isUserSubscribedToGlacierPlan" }
        var activeGlacierSubscriptionPlanId: String { "activeGlacierSubscriptionPlanId" }
        /// Set to `true` the first time a base-plan subscription is confirmed active.
        /// Used by the TestFlight override so expired subscriptions are treated as permanent
        /// for non-allow-listed testers. Remove when removing the TestFlight override.
        var hasEverSubscribedToGlacierPlan: String { "hasEverSubscribedToGlacierPlan" }
        
        var didSkipPhoneNumberPurchaseDuringOnboarding: String { "didSkipPhoneNumberPurchaseDuringOnboarding" }
        var activePhoneNumberSubscriptionPlanId: String { "activePhoneNumberSubscriptionPlanId" }
        /// Set to `true` the first time a phone-number subscription is confirmed active.
        /// Used by the TestFlight override so expired subscriptions are treated as permanent
        /// for non-allow-listed testers. Remove when removing the TestFlight override.
        var hasEverSubscribedToPhoneNumberPlan: String { "hasEverSubscribedToPhoneNumberPlan" }
        
        var didSkipPhoneNumberSelectionDuringOnboarding: String { "didSkipPhoneNumberSelectionDuringOnboarding" }
        /// Set to `true` when the user completes DNS setup during onboarding (taps "Open Settings").
        /// Consumed once at the end of onboarding to enable DNS if VPN was not also set up.
        var didCompleteDNSSetupDuringOnboarding: String { "didCompleteDNSSetupDuringOnboarding" }
        
        var isUserOnboardingCompleted: String { "isUserOnboardingCompleted" }
        var inProgressUserOnboardingScreen: String { "inProgressUserOnboardingScreen" }
        /// Set to `true` once the user completes (or skips) the post-onboarding VPN mini-setup
        /// (CellularSetupScreen + WifiSetupScreen). Prevents re-showing the flow.
        var hasCompletedVPNFirstTimeSetup: String { "hasCompletedVPNFirstTimeSetup" }
        
        // Main module
        var activePhoneNumber: String { "activePhoneNumber" }
        
        // Phone module
        var phoneNumberGradientAvatarDictionary: String { "phoneNumberGradientAvatarDictionary" }
        
        // Settings module
        var userSelectedColorScheme: String { "userSelectedColorScheme" }
        var trustedNetworks: String { "trustedNetworks" }
        var vpnActivationOverWiFiPolicy: String { "vpnActivationOverWiFiPolicy" }
        /// Whether the weekly "time to reboot" reminder is enabled. Absent = on by default.
        var isRebootReminderEnabled: String { "isRebootReminderEnabled" }
        
        // User permissions
        var pushNotificationsPermission: String { "pushNotificationsPermission" }
        var contactsPermission: String { "contactsPermission" }
        var userLocationPermission: String { "userLocationPermission" }
        
        var cachedDeviceToken: String { "CachedDeviceToken" }
        var cachedBindingDate: String { "CachedBindingDate" }
    }
    
    // MARK: - Public properties
    
    static var shared = UserDefaultsService()
    
    // MARK: - Private properties
    
    private let defaults: UserDefaults
    private let keys = LocalStorageKeys()

    // MARK: - Initializer
    
    private init() {
        self.defaults = .standard
    }

    // MARK: - Public methods
    
    func set<Value: Codable>(_ value: Value, for keyPath: KeyPath<LocalStorageKeys, String>) {
        let key = keys[keyPath: keyPath]

        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
        } catch {
            Log.general.error("Failed to encode value for key '\(key)': \(error)")
        }
    }

    func get<Value: Codable>(for keyPath: KeyPath<LocalStorageKeys, String>) -> Value? {
        let key = keys[keyPath: keyPath]
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            Log.general.error("Failed to decode value for key '\(key)': \(error)")
            return nil
        }
    }

    func remove(for keyPath: KeyPath<LocalStorageKeys, String>) {
        let key = keys[keyPath: keyPath]
        defaults.removeObject(forKey: key)
    }
}
