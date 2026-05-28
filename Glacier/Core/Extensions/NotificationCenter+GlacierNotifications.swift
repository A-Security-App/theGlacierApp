//
//  NotificationCenter+GlacierNotifications.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 28/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 Defines custom notification names
 */
extension Notification.Name {
    
    // MARK: - User authentication notifications
    
    static let userAuthenticationVerified = Notification.Name("userAuthenticationVerified")
    static let userAccountConfirmationLinkClicked = Notification.Name("userAccountConfirmationLinkClicked")
    static let userAccountConfirmed = Notification.Name("userAccountConfirmed")
    static let resetPasswordLinkClicked = Notification.Name("resetPasswordLinkClicked")
    static let userSuccessfullyResetPassword = Notification.Name("userSuccessfullyResetPassword")
    
    // MARK: - User onboarding
    
    static let glacierPlanPurchaseVerificationFailed = Notification.Name("glacierPlanPurchaseVerificationFailed")
    static let glacierPlanPurchaseVerified = Notification.Name("glacierPlanPurchaseVerified")
    static let glacierPlanPurchaseSuccessful = Notification.Name("glacierPlanPurchaseSuccessful")
    /// Fired when an active base subscription transitions to inactive during a foreground
    /// subscription refresh. Observers should enforce the paywall and stop any running VPN.
    static let glacierBaseSubscriptionLapsed = Notification.Name("glacierBaseSubscriptionLapsed")
    
    static let phoneNumberPlanPurchaseVerificationFailed = Notification.Name("phoneNumberPlanPurchaseVerificationFailed")
    static let phoneNumberPlanPurchaseVerified = Notification.Name("phoneNumberPlanPurchaseVerified")
    static let phoneNumberPlanPurchaseSuccessful = Notification.Name("phoneNumberPlanPurchaseSuccessful")
    /// Fired by `applyBackendSubscription` after the reconciled `hasActivePhoneNumberSubscription`
    /// value is written to the account. Observers should re-read that flag and update their UI state.
    /// This bridges the gap between the backend subscription path and ViewModels that only learn
    /// about phone subscription changes through StoreKit purchase notifications.
    static let phoneSubscriptionStateDidChange = Notification.Name("phoneSubscriptionStateDidChange")
    
    // MARK: - Main screen
    
    static let hidePhoneNumberMenuView = Notification.Name("hidePhoneNumberMenuView")
    
    // MARK: - Home screen

    static let userSelectedConnectionType = Notification.Name("didSelectConnectionType")
    /// Fired when the iOS 16 widget deep link (glacierapp://vpn/toggle) is opened.
    /// HomeVM observes this and calls handleWidgetToggle() without a confirmation popup.
    static let widgetVPNDNSToggleRequested = Notification.Name("widgetVPNDNSToggleRequested")
    /// Fired by the widget Link (glacierapp://widget/disconnect) — disconnect DNS and VPN.
    static let widgetDisconnectRequested = Notification.Name("widgetDisconnectRequested")
    /// Fired by the widget Link (glacierapp://widget/connect) — reconnect to last used type.
    static let widgetConnectRequested = Notification.Name("widgetConnectRequested")
    static let twilioAccessTokenUpdated = Notification.Name("twilioAccessTokenUpdated")
    
    // MARK: - Phone screen
    
    static let newPhoneNumberAdded = Notification.Name("newPhoneNumberAdded")
    static let userPhoneNumberDetailsUpdated = Notification.Name("userPhoneNumberDetailsUpdated")
    static let startPhoneCall = Notification.Name("startPhoneCall")
    static let phoneCallEnded = Notification.Name("phoneCallEnded")
    
    // MARK: - Contacts screen
    
    static let didTapOnFloatingTabBarSearchButton = Notification.Name("didTapOnFloatingTabBarSearchButton")
}

/**
 Defines property names for custom notificationss
 */
struct GlacierNotificationProperties {
    
    // MARK: - User authentication properties
    
    static let userName = "userName"
    static let confirmationCode = "confirmationCode"
    static let isAuthSessionValid = "isAuthSessionValid"
    
    // MARK: - User onboarding properties
    
    static let activeGlacierPlanId = "activeGlacierPlanId"
    static let activePhoneNumberPlanId = "activePhoneNumberPlanId"
    
    // MARK: - Home screen
    
    static let connectionType = "connectionType"
    
    // MARK: - Phone screen
    
    static let phoneNumber = "phoneNumber"
    static let personName: String = "name"
    static let isIncomingCall: String = "isIncomingCall"
}
