//
//  GlacierAppRootScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI
import Lottie
import WidgetKit

/**
 Persistent banner shown at the top of every screen while a phone call is active and
 the user has navigated away from PhoneCallScreen.  Tapping it returns the user to the call.
 */
private struct ActiveCallBannerView: View {

    @ObservedObject var callVM: PhoneCallVM
    var onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let bgColor: Color = colorScheme == .dark ? .grey70 : .grey30
        let textColor: Color = colorScheme == .dark ? .white : Color.black

        Button(action: onTap) {
            HStack {
                Spacer()
                GlacierLabel(
                    text: "Tap to Return to Call - \(callVM.callDurationLabel ?? "00:00")",
                    font: .bodyRegular,
                    customTextColor: .constant(textColor)
                )
                Spacer()
            }
            .frame(height: 57)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(bgColor.ignoresSafeArea(edges: .top))
    }
}

/**
 As name suggests GlacierAppRootScreen represents the root of the Glacier application.
 It provides root container for the entire application UI/UX (screens, views, user interaction, etc) and related functional flows.

 - Injects `GlacierAppRootCoordinator` instance to the environment so that it could be referenced from anywhere in the app for setting desired screen, presenting sheet views, popups, sliding views, etc.
 - Setup primary screen based on the application state
 */
struct GlacierAppRootScreen: View {

    /// After this date, TestFlight pilot participants see PilotEndedScreen instead of the
    /// subscription lapse paywall. Keyed on date rather than subscription state to avoid
    /// false positives from StoreKit timeouts or network errors at foreground transitions.
    private static let pilotEndDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 4
        components.day = 30
        components.hour = 0
        components.minute = 0
        components.second = 0
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    // MARK: - Private properties

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme

    @StateObject private var glacierAppCoordinator = GlacierAppRootCoordinator()

    @State private var isUserAuthenticationVerified = false
    @State private var isGlacierLogoAnimationComplete = false
    /// Longest the splash may stay up waiting for the authoritative verdict when the cached
    /// routing flags are known to be unreadable. Bounded on purpose: the launch path must
    /// never wait on the network without a deadline, so this expires and commits the cached
    /// guess (which the authoritative verdict can still correct) rather than hanging.
    private static let poisonedCacheSplashGrace: TimeInterval = 3
    /// Set to `true` when `.glacierBaseSubscriptionLapsed` fires while the user is on the main
    /// screen.  Presents a non-dismissible paywall cover until the subscription is restored.
    @State private var showSubscriptionLapsedPaywall = false
    /// Set to `true` when the base-subscription grace nag's "Renew now" button is tapped. Presents a
    /// *dismissible* paywall so the user can back out and keep using the app while protection is
    /// still preserved during the grace window.
    @State private var showGraceRenewPaywall = false
    /// Guards the one-time background subscription check so it only runs once per launch even if
    /// .userAuthenticationVerified is re-posted (e.g. by MainVM when no account record exists).
    @State private var subscriptionCheckStarted = false
    /// True while resolveSubscriptionStatus() is running.  Suppresses .glacierBaseSubscriptionLapsed
    /// notifications during this window — the authoritative result comes from resolveSubscriptionStatus()
    /// itself, and any lapse notification that arrives while it is in flight is based on stale or
    /// temporarily-reset state (e.g. the hasActiveSubscription = false reset at the start of the check).
    @State private var subscriptionCheckInFlight = false
    /// Set to `true` when a TestFlight pilot user's subscription expires.  Shows a non-dismissible
    /// "thank you" screen and blocks further app usage.  VPN is disabled and phone numbers are
    /// released before this flag is set.
    @State private var showPilotEndedScreen = false

    // MARK: - UI/UX

    var body: some View {
        ZStack {

            GlacierBackground()
                .ignoresSafeArea()

            // Main screen content - Home, Phone, Contact, History, overlays, popups, etc
            // The active call banner sits above the NavigationStack in a VStack so the
            // nav bar physically starts below the banner rather than behind it.
            VStack(spacing: 0) {
                if let callVM = glacierAppCoordinator.activeCallVM,
                   !glacierAppCoordinator.isViewingPhoneCallScreen {
                    ActiveCallBannerView(
                        callVM: callVM,
                        onTap: { glacierAppCoordinator.returnToActiveCall() }
                    )
                }

                NavigationStack(path: $glacierAppCoordinator.path) {
                    if let screen = glacierAppCoordinator.currentScreen {
                        glacierAppCoordinator.build(screen)
                            .navigationDestination(for: GlacierScreen.self) { screen in
                                glacierAppCoordinator.build(screen)
                            }
                            .sheet(item: $glacierAppCoordinator.sheet) { sheet in
                                glacierAppCoordinator.build(sheet)
                                    .environmentObject(glacierColorScheme)
                            }
                    }
                }
            }
            .opacity(isGlacierLogoAnimationComplete && isUserAuthenticationVerified ? 1 : 0)
            .animation(.easeIn(duration: 0.3), value: (isGlacierLogoAnimationComplete && isUserAuthenticationVerified))

            // Glacier animated logo
            LottieView(animation: .named(glacierColorScheme.glacierLogoAnimationFile))
                .playing(loopMode: .playOnce)
                .animationDidFinish { didComplete in
                    self.isGlacierLogoAnimationComplete = true
                    // If auth has not yet resolved (network slow or VPN hung), set the initial
                    // screen from cached UserDefaults state so the splash dismisses immediately
                    // when the animation finishes rather than waiting on any network call.
                    // The .userAuthenticationVerified handler will correct the screen and run
                    // the subscription check once auth finishes in the background.
                    guard !self.isUserAuthenticationVerified else { return }
                    let cachedLoggedIn = UserDefaultsService.shared.get(for: \.isUserLoggedIn) ?? false
                    Log.auth.notice("[GlacierAuth] splash fast-path: cachedLoggedIn=\(cachedLoggedIn ? 1 : 0) (auth not yet resolved)")
                    // A cached `false` read during a poisoned-cache launch is not evidence of
                    // anything — every UserDefaults read in this process can return empty
                    // regardless of what is on disk. Rather than guess "logged out" and show a
                    // login screen to someone who is signed in, hold the splash briefly for the
                    // authoritative verdict. Strictly bounded so a stalled network cannot hang
                    // the launch: when the grace expires we commit the guess anyway.
                    if !cachedLoggedIn, GlacierApplicationDelegate.userDefaultsCachePoisoned {
                        Log.auth.notice("[GlacierAuth] splash fast-path: cache poisoned and cachedLoggedIn=0 — holding splash briefly for the authoritative verdict")
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.poisonedCacheSplashGrace) {
                            guard !self.isUserAuthenticationVerified else { return }
                            Log.auth.notice("[GlacierAuth] splash fast-path: grace expired — routing to userAuthentication on the cached guess")
                            self.setScreen(.userAuthentication)
                            self.isUserAuthenticationVerified = true
                        }
                        return
                    }
                    if cachedLoggedIn {
                        let needsOnboarding = UserOnboardingScreen.shouldShowUserOnboarding
                        // Benefit of the doubt on subscription — resolveSubscriptionStatus()
                        // will set the authoritative value once auth resolves.
                        GlacierAccountModel.getGlacierAccount()?.hasActiveSubscription = true
                        self.setScreen(needsOnboarding ? .userOnboarding : .main)
                    } else {
                        Log.auth.notice("[GlacierAuth] splash fast-path routing to userAuthentication — isUserLoggedIn=\(cachedLoggedIn ? 1 : 0)")
                        self.setScreen(.userAuthentication)
                    }
                    self.isUserAuthenticationVerified = true
                }
                .frame(width: 100, height: 100)
                .opacity(isGlacierLogoAnimationComplete && isUserAuthenticationVerified ? 0 : 1)
                .animation(.easeIn(duration: 0.3), value: (isGlacierLogoAnimationComplete && isUserAuthenticationVerified))
        }
        .environmentObject(glacierAppCoordinator)
        .onChange(of: colorScheme) { newScheme in
            glacierColorScheme.setScheme(newScheme)
        }
        .onReceive(NotificationCenter.default.publisher(for: .userAuthenticationVerified)) { notification in
            Task { @MainActor in
                let receivedValid = (notification.userInfo?[GlacierNotificationProperties.isAuthSessionValid] as? Bool) ?? false
                Log.auth.notice("[GlacierAuth] userAuthenticationVerified received: isAuthSessionValid=\(receivedValid ? 1 : 0), isUserAuthenticationVerified(current)=\(self.isUserAuthenticationVerified ? 1 : 0), subscriptionCheckStarted=\(self.subscriptionCheckStarted ? 1 : 0)")
                // Pilot-ended gate runs before any network calls or auth checks so that
                // deleting Cognito users doesn't route pilot participants to the login screen.
                // All required data is local (UserDefaults + date) — no auth session needed.
                /*if UIApplication.isDebugOrTestFlight(),
                   UserDefaultsService.shared.get(for: \.hasEverSubscribedToGlacierPlan) == true,
                   Date() >= Self.pilotEndDate {
                    isUserAuthenticationVerified = true
                    WireGuardManager.shared().turnOffCore()
                    WireGuardManager.shared().removeAllTunnels()
                    self.clearWidgetVPNStatus()
                    self.releaseAllPhoneNumbers()
                    CallManager.sharedCallManager().unregisterWithTwilio()
                    showPilotEndedScreen = true
                    return
                }*/

                let userInfo = notification.userInfo
                // A provisional verdict is a cached guess posted so the splash can dismiss
                // before the network answers. It may route, but it must not take irreversible
                // action — no session-expiry alert.
                let isProvisional = (userInfo?[GlacierNotificationProperties.isAuthVerdictProvisional] as? Bool) ?? false
                // Absent means `true`, preserving the behaviour of posters that predate the key.
                let canDowngrade = (userInfo?[GlacierNotificationProperties.authVerdictCanDowngrade] as? Bool) ?? true
                let didSessionExpire = (userInfo?[GlacierNotificationProperties.authSessionDidExpire] as? Bool) ?? false

                // Auth validity is known from the notification — no network call needed.
                // Route to the auth screen immediately if the session is invalid.
                guard let userInfo = userInfo,
                      let isAuthSessionValid = userInfo[GlacierNotificationProperties.isAuthSessionValid] as? Bool,
                      isAuthSessionValid else {

                    // Monotonic routing: a verdict without evidence of a signed-out user may
                    // never pull the app off a screen already committed to as signed-in. This
                    // is what stops a session fetch that was hung on a bad network from
                    // signing out a user who logged in manually while it was stalled.
                    let isOnSignedInScreen = glacierAppCoordinator.currentScreen == .main
                        || glacierAppCoordinator.currentScreen == .userOnboarding
                    if !canDowngrade, isOnSignedInScreen {
                        Log.auth.notice("[GlacierAuth] ignoring invalid verdict — already on a signed-in screen and this verdict cannot downgrade")
                        isUserAuthenticationVerified = true
                        return
                    }

                    let isUserAccountCreated = UserDefaultsService.shared.get(for: \.isUserAccountCreated) ?? false
                    let isUserAccountConfirmed = UserDefaultsService.shared.get(for: \.isUserAccountConfirmed) ?? false
                    let isUserLoggedIn = UserDefaultsService.shared.get(for: \.isUserLoggedIn) ?? false

                    if isUserAccountCreated, !isUserAccountConfirmed {
                        self.setScreen(.userAccountConfirmation)
                    } else {
                        // Show the expiry alert only for a confirmed terminal expiry. Keying it
                        // off isUserLoggedIn alone had it exactly backwards: the terminal-expiry
                        // path clears that flag before posting, so the alert never appeared for a
                        // real expiry and appeared only for false positives. isUserLoggedIn is
                        // still honoured for legacy posters that carry no reason.
                        if didSessionExpire || (!isProvisional && canDowngrade && isUserLoggedIn) {
                            self.presentAuthSessionExpirationAlert()
                        }
                        self.setScreen(.userAuthentication)
                    }
                    isUserAuthenticationVerified = true
                    return
                }

                let account = GlacierAccountModel.getGlacierAccount()
                let needsOnboarding = UserOnboardingScreen.shouldShowUserOnboarding

                // Correct a false-positive login screen unconditionally — before the
                // subscriptionCheckStarted guard below, which would otherwise swallow this
                // notification on a second delivery (e.g. foreground re-run after a
                // background launch that deferred posting).  Correcting .userAuthentication →
                // .main when auth is confirmed valid is always safe and intentional; the
                // redundant-render concern only applies when already on .main.
                if glacierAppCoordinator.currentScreen == .userAuthentication {
                    // Never re-route out from under an in-progress sign-in — the user could be
                    // parked on the emailed-code step, or signing into a different account.
                    // Their own success path navigates; this correction is only for a login
                    // screen nobody asked for.
                    if GlacierApplicationDelegate.isSignInInFlight {
                        Log.auth.notice("[GlacierAuth] valid verdict while a sign-in is in flight — leaving the login screen alone")
                    } else {
                        if !needsOnboarding {
                            account?.hasActiveSubscription = true
                        }
                        self.setScreen(needsOnboarding ? .userOnboarding : .main)
                        isUserAuthenticationVerified = true
                    }
                }
                // NOTE: do not set isUserAuthenticationVerified here. Below, it doubles as the
                // "a screen has already been navigated to" sentinel — setting it before that
                // check skips the only setScreen on this path and reveals an empty root with
                // currentScreen still nil. A held splash is brought down by that same block,
                // which navigates first and then sets the flag.

                // The subscription check is expensive (StoreKit + 15-second backend timeout).
                // Guard it so that if MainVM re-posts this notification (e.g. no account record),
                // the re-entry falls through to the auth-invalid path above and we do not run a
                // second concurrent resolveSubscriptionStatus().
                guard !subscriptionCheckStarted else { return }
                subscriptionCheckStarted = true

                // Navigate to the initial screen immediately using cached subscription state.
                // The splash dismisses now; the subscription check runs in the background below.
                // Skip setScreen if PATH A (splash callback) already navigated — calling it
                // again with the same value triggers objectWillChange on the coordinator,
                // causing a redundant SwiftUI re-render and a new MainVM that could race
                // against the resolveSubscriptionStatus() reset below.
                if !needsOnboarding {
                    // Give benefit of the doubt before navigating so that MainViewModel does not
                    // see hasActiveSubscription=false at init time. resolveSubscriptionStatus()
                    // will reset this to the authoritative value once the background check completes.
                    account?.hasActiveSubscription = true
                }
                if !isUserAuthenticationVerified {
                    self.setScreen(needsOnboarding ? .userOnboarding : .main)
                }
                isUserAuthenticationVerified = true

                // Yield to the main run loop so SwiftUI renders the new screen and MainViewModel
                // initialises with the benefit-of-doubt subscription state before
                // resolveSubscriptionStatus() resets hasActiveSubscription to false.
                await Task.yield()

                // Suppress lapse notifications while the authoritative check is in flight.
                // Any .glacierBaseSubscriptionLapsed that arrives during this window is based
                // on the hasActiveSubscription = false reset inside resolveSubscriptionStatus()
                // — it is not a confirmed lapse. The result of resolveSubscriptionStatus()
                // itself is the authoritative decision.
                subscriptionCheckInFlight = true
                let hadLiveBackendResponse = await GlacierApplicationDelegate.appDelegate.resolveSubscriptionStatus()
                subscriptionCheckInFlight = false

                let updatedAccount = GlacierAccountModel.getGlacierAccount()
                let hasSubscription = updatedAccount?.hasActiveSubscription == true

                if !hasSubscription {
                    // Route the launch reading through the base-subscription grace handler. It never
                    // *starts* a grace window at cold start (there is no reliable in-session
                    // "was subscribed" signal here) — it only continues one that a prior foreground
                    // opened, and otherwise enforces. `hadLiveBackendResponse` here is already the
                    // combined confirmed flag (live backend AND definitive StoreKit) returned by
                    // resolveSubscriptionStatus().
                    switch BaseSubscriptionLifecycleHandler.shared.launchDecision(isConfirmedReading: hadLiveBackendResponse) {
                    case .grace:
                        // An active grace window is open — preserve protection (VPN/DoT keep running).
                        updatedAccount?.hasActiveSubscription = true
                    case .enforce:
                        // Confirmed lapse, no grace owed. The handler already disabled DoT + cleared
                        // widget status; stop the VPN and show the non-dismissible paywall.
                        WireGuardManager.shared().turnOffCore()
                        showSubscriptionLapsedPaywall = true
                    case .inconclusive:
                        // Network unavailable (e.g. WireGuard tunnel mid-reconnect) — cannot
                        // distinguish a genuine lapse from a transient outage. Give benefit of the
                        // doubt so refreshBackendSubscription() sees wasSubscribed=true on the next
                        // foreground and can detect a genuine lapse if one exists.
                        updatedAccount?.hasActiveSubscription = true
                    }
                }
            }
        }
        // When the base subscription lapses mid-session, cover the current screen with
        // a non-dismissible paywall.  Guards:
        //  1. isUserAuthenticationVerified — only when past the splash/login flow.
        //  2. !subscriptionCheckInFlight — suppress notifications that arrive while
        //     resolveSubscriptionStatus() is running; those are based on the temporary
        //     hasActiveSubscription = false reset, not a confirmed lapse.
        .onReceive(NotificationCenter.default.publisher(for: .glacierBaseSubscriptionLapsed)) { _ in
            guard isUserAuthenticationVerified, !subscriptionCheckInFlight else { return }
            /*if UIApplication.isDebugOrTestFlight(),
               UserDefaultsService.shared.get(for: \.hasEverSubscribedToGlacierPlan) == true,
               Date() >= Self.pilotEndDate {
                // Pilot has ended — remove VPN profile, burn numbers, unregister from Twilio,
                // sign out, and show pilot-ended screen.
                WireGuardManager.shared().turnOffCore()
                WireGuardManager.shared().removeAllTunnels()
                self.clearWidgetVPNStatus()
                self.releaseAllPhoneNumbers()
                CallManager.sharedCallManager().unregisterWithTwilio()
                showPilotEndedScreen = true
            } else {*/
                WireGuardManager.shared().turnOffCore()
                showSubscriptionLapsedPaywall = true
            //}
        }
        // Present a dismissible renew paywall when the grace nag's "Renew now" is tapped.
        .onReceive(NotificationCenter.default.publisher(for: .glacierPresentRenewPaywall)) { _ in
            guard isUserAuthenticationVerified else { return }
            showGraceRenewPaywall = true
        }
        // Dismiss the lapse paywall once the user successfully restores their subscription.
        // We are always on .main when the lapse paywall is shown (navigated there immediately
        // at startup before the background subscription check), so no screen transition needed.
        // Also clear any base-subscription grace window and re-enable DoT if enforcement had
        // disabled it, so restoring returns the user to their prior protection.
        .onReceive(NotificationCenter.default.publisher(for: .glacierPlanPurchaseSuccessful)) { _ in
            showSubscriptionLapsedPaywall = false
            showGraceRenewPaywall = false
            BaseSubscriptionLifecycleHandler.shared.handleSubscriptionRestored()
        }
        .fullScreenCover(isPresented: $showSubscriptionLapsedPaywall) {
            let viewModel = GlacierPlanPurchaseVM(
                rootCoodinator: glacierAppCoordinator,
                service: SKGlacierPlanPurchaseService()
            )
            GlacierPlanPurchaseScreen(viewModel: viewModel, isLapsePaywall: true)
        }
        .fullScreenCover(isPresented: $showGraceRenewPaywall) {
            let viewModel = GlacierPlanPurchaseVM(
                rootCoodinator: glacierAppCoordinator,
                service: SKGlacierPlanPurchaseService()
            )
            // Dismissible (isLapsePaywall: false) — the user is still within the grace window and
            // protection is intact, so they may close this and continue using the app. isGraceRenewal
            // keeps it from recording onboarding progress (which would re-enter purchase on next login).
            GlacierPlanPurchaseScreen(viewModel: viewModel, isLapsePaywall: false, isGraceRenewal: true)
        }
        // Keep the grace nag from popping up over a renew/lapse paywall (e.g. when
        // applicationDidBecomeActive fires as the StoreKit purchase sheet dismisses mid-renewal).
        .onChange(of: showGraceRenewPaywall) { _ in
            BaseSubscriptionLifecycleHandler.shared.setPaywallPresented(showGraceRenewPaywall || showSubscriptionLapsedPaywall)
        }
        .onChange(of: showSubscriptionLapsedPaywall) { _ in
            BaseSubscriptionLifecycleHandler.shared.setPaywallPresented(showGraceRenewPaywall || showSubscriptionLapsedPaywall)
        }
        //.fullScreenCover(isPresented: $showPilotEndedScreen) {
        //    PilotEndedScreen()
        //}
    }

    // MARK: - Private methods

    private func setScreen(_ screen: GlacierScreen) {
        withAnimation(.easeInOut(duration: 0.2)) {
            glacierAppCoordinator.setScreen(screen)
        }
    }

    /// Clears the shared App Group VPN status key so the widget stops showing the VPN
    /// as active after the pilot subscription ends.
    private func clearWidgetVPNStatus() {
        UserDefaults(suiteName: kGlacierGroup)?.removeObject(forKey: kActiveConnectionTypeKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Calls `TwilioBackendManager.releaseNumber` for every phone number currently known to
    /// the app.  This makes the backend `/release` call so the number is freed server-side
    /// ("burned").  Called just before showing the pilot-ended screen.
    private func releaseAllPhoneNumbers() {
        let numbers = TwilioBackendManager.sharedMgr()
            .getExistingAccounts()
            .compactMap { $0.grdbRecord?.phoneNumber }
        for number in numbers {
            TwilioBackendManager.sharedMgr().releaseNumber(number)
        }
    }

    private func presentAuthSessionExpirationAlert() {
        let configuration = PopupConfiguration(
            title: nil,
            description: NSLocalizedString(
                "Your session has expired. Please sign in again to continue.",
                comment: "Root screen auth session expiration alert"
            ),
            buttons: [
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Ok", comment: "Ok button title"),
                    onTap: {
                        self.glacierAppCoordinator.dismissPopup()
                    }
                )
            ]
        )
        glacierAppCoordinator.presentPopup(with: configuration)
    }
}
