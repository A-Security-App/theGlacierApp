//
//  GlacierApplicationDelegate+InAppPurchase.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 06/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

extension GlacierApplicationDelegate {

    // Set to true the first time StoreKit confirms each subscription type this session.
    // The VerificationFailed handlers below only act when the flag is set, which means
    // a transient StoreKit failure at startup (e.g. VPN blocking storeaccountd before
    // it can respond) is never mis-interpreted as a subscription expiry.
    private static var subscriptionVerifiedThisSession = false
    private static var phoneNumberSubscriptionVerifiedThisSession = false

    // Set to true when a purchase completes this session; cleared by the first
    // refreshBackendSubscription() call that follows. Prevents the foreground
    // StoreKit re-check (which can lag right after a fresh purchase) from
    // incorrectly firing .glacierBaseSubscriptionLapsed immediately after purchase.
    static var subscriptionJustPurchased = false
    static var phoneNumberSubscriptionJustPurchased = false

    /**
     It calls `SKGlacierPlanPurchaseService.refreshEntitlements()` to checks, if there are any pending in app purchase transaction.
     If one is found, it attempts to verify the same so that user purchase is successful.
     */
    func refreshGlacierPlanSubscription() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onGlacierPlanPurchaseVerified(_:)),
            name: .glacierPlanPurchaseVerified,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onGlacierPlanPurchaseVerificationFailed),
            name: .glacierPlanPurchaseVerificationFailed,
            object: nil
        )
        
        Task {
            do {
                let glacierPlanPurchaseService = SKGlacierPlanPurchaseService()
                await glacierPlanPurchaseService.refreshEntitlements()
            }
        }
    }
    
    /**
     It calls `SKGlacierPhoneNumberPlanPurchaseService.refreshEntitlements()` to checks, if there are any pending phone
     number purchase transaction. If one is found, it attempts to verify the same so that user purchase is successful.
     */
    func refreshGlacierPhoneNumberPlanSubscription() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPhoneNumberPlanPurchaseVerified(_:)),
            name: .phoneNumberPlanPurchaseVerified,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPhoneNumberPlanPurchaseVerificationFailed),
            name: .phoneNumberPlanPurchaseVerificationFailed,
            object: nil
        )
        
        Task {
            do {
                let phoneNumberPlanPurchaseService = SKGlacierPhoneNumberPlanPurchaseService()
                await phoneNumberPlanPurchaseService.refreshEntitlements()
            }
        }
    }
    
    @MainActor
    @objc private func onGlacierPlanPurchaseVerificationFailed() {
        // Only treat as a lapse if StoreKit already confirmed the subscription earlier
        // this session. Without this guard, a transient StoreKit failure at startup
        // (e.g. VPN routing all traffic through a blocked tunnel) would see
        // hasActiveSubscription=true (carried over from the previous session) and
        // falsely post .glacierBaseSubscriptionLapsed, showing the paywall to a
        // still-subscribed user.
        guard Self.subscriptionVerifiedThisSession else { return }
        guard let account = GlacierAccountModel.getGlacierAccount(),
              account.hasActiveSubscription else { return }

        account.hasActiveSubscription = false
        NotificationCenter.default.post(name: .glacierBaseSubscriptionLapsed, object: nil)
    }

    @MainActor
    @objc private func onGlacierPlanPurchaseVerified(_ notification: Notification) {
        Self.subscriptionVerifiedThisSession = true
        Self.subscriptionJustPurchased = true
        guard let userInfo = notification.userInfo,
              let planId = userInfo[GlacierNotificationProperties.activeGlacierPlanId] as? String else {
            return
        }

        // Let's save active glacier base plan id for future references
        UserDefaultsService.shared.set(planId, for: \.activeGlacierSubscriptionPlanId)

        // Persist "has ever subscribed" immediately so the TestFlight override fires on
        // the very next cold launch — even if the sandbox subscription expires before then.
        // (applyBackendSubscription also sets this flag, but it runs at startup before the
        // purchase, so without this line the flag is never set in the purchase session.)
        UserDefaultsService.shared.set(true, for: \.hasEverSubscribedToGlacierPlan)

        // Let's update subscription status for user account
        if let account = GlacierAccountModel.getGlacierAccount() {
            account.hasActiveSubscription = true
        }
    }
    
    @MainActor
    @objc private func onPhoneNumberPlanPurchaseVerificationFailed() {
        // Same guard as the base plan handler: only clear the stored plan ID if
        // StoreKit confirmed the phone subscription earlier this session. Prevents
        // a startup StoreKit failure from discarding a valid cached plan ID.
        guard Self.phoneNumberSubscriptionVerifiedThisSession else { return }
        UserDefaultsService.shared.remove(for: \.activePhoneNumberSubscriptionPlanId)
    }

    @MainActor
    @objc private func onPhoneNumberPlanPurchaseVerified(_ notification: Notification) {
        Self.phoneNumberSubscriptionVerifiedThisSession = true
        Self.phoneNumberSubscriptionJustPurchased = true
        guard let userInfo = notification.userInfo,
              let planId = userInfo[GlacierNotificationProperties.activePhoneNumberPlanId] as? String else {
            return
        }

        // Let's save active phone number plan id for future references
        UserDefaultsService.shared.set(planId, for: \.activePhoneNumberSubscriptionPlanId)

        // Persist "has ever subscribed to phone" immediately (same rationale as the base plan above).
        UserDefaultsService.shared.set(true, for: \.hasEverSubscribedToPhoneNumberPlan)

        // Let's update phone number subscription status for user account
        if let account = GlacierAccountModel.getGlacierAccount() {
            account.hasActivePhoneNumberSubscription = true
        }
    }
}
