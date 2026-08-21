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
    /// Fired when the login email's auto-fill button is tapped
    /// (console.theglacierapp.com/login-securityapp?code=…). Only the login
    /// screen, while parked on the code step, acts on it.
    static let loginCodeLinkClicked = Notification.Name("loginCodeLinkClicked")
    
    // MARK: - User onboarding
    
    static let glacierPlanPurchaseVerificationFailed = Notification.Name("glacierPlanPurchaseVerificationFailed")
    static let glacierPlanPurchaseVerified = Notification.Name("glacierPlanPurchaseVerified")
    static let glacierPlanPurchaseSuccessful = Notification.Name("glacierPlanPurchaseSuccessful")
    /// Fired when an active base subscription transitions to inactive during a foreground
    /// subscription refresh. Observers should enforce the paywall and stop any running VPN.
    static let glacierBaseSubscriptionLapsed = Notification.Name("glacierBaseSubscriptionLapsed")
    /// Fired by the base-subscription grace nag's "Renew now" button. The root screen presents a
    /// *dismissible* purchase paywall (unlike the non-dismissible lapse paywall) so the user can
    /// still back out and keep using the app while protection is preserved during the grace window.
    static let glacierPresentRenewPaywall = Notification.Name("glacierPresentRenewPaywall")
    
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
    /// `true` when the verdict is a placeholder posted so the splash can dismiss before
    /// the network answers (the launch watchdog and the not-configured / proxy guards).
    /// Consumers must not take irreversible action on a provisional verdict — no session
    /// expiry alert, no downgrade of an already-signed-in screen. Absent means authoritative.
    static let isAuthVerdictProvisional = "isAuthVerdictProvisional"
    /// `true` only for verdicts backed by real evidence that the user is signed out — a
    /// terminal session expiry or the first-launch reinstall detection. A verdict that
    /// cannot downgrade may correct the routing towards signed-in but must never pull the
    /// user off a screen already committed to as signed-in, so a network failure can never
    /// clobber a session established since the verdict was requested. Absent means `true`,
    /// preserving the behaviour of callers that predate this key.
    static let authVerdictCanDowngrade = "authVerdictCanDowngrade"
    /// `true` when the verdict comes from a confirmed terminal session expiry. Drives the
    /// "your session has expired" alert, which cannot key off `isUserLoggedIn` — that flag
    /// is cleared before the notification is posted.
    static let authSessionDidExpire = "authSessionDidExpire"
    
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
