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
    /// Set to `true` when `.glacierBaseSubscriptionLapsed` fires while the user is on the main
    /// screen.  Presents a non-dismissible paywall cover until the subscription is restored.
    @State private var showSubscriptionLapsedPaywall = false
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

                // Auth validity is known from the notification — no network call needed.
                // Route to the auth screen immediately if the session is invalid.
                guard let userInfo = notification.userInfo,
                      let isAuthSessionValid = userInfo[GlacierNotificationProperties.isAuthSessionValid] as? Bool,
                      isAuthSessionValid else {

                    let isUserAccountCreated = UserDefaultsService.shared.get(for: \.isUserAccountCreated) ?? false
                    let isUserAccountConfirmed = UserDefaultsService.shared.get(for: \.isUserAccountConfirmed) ?? false
                    let isUserLoggedIn = UserDefaultsService.shared.get(for: \.isUserLoggedIn) ?? false

                    if isUserAccountCreated, !isUserAccountConfirmed {
                        self.setScreen(.userAccountConfirmation)
                    } else {
                        if isUserLoggedIn {
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
                    if !needsOnboarding {
                        account?.hasActiveSubscription = true
                    }
                    self.setScreen(needsOnboarding ? .userOnboarding : .main)
                    isUserAuthenticationVerified = true
                }

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

                if !hasSubscription && hadLiveBackendResponse {
                    // Lapse confirmed by a live backend response — stop VPN and show paywall.
                    WireGuardManager.shared().turnOffCore()
                    showSubscriptionLapsedPaywall = true
                } else if !hasSubscription {
                    // Network unavailable (e.g. WireGuard tunnel mid-reconnect) — cannot
                    // distinguish a genuine lapse from a transient outage. Give benefit of the
                    // doubt so refreshBackendSubscription() sees wasSubscribed=true on the next
                    // foreground and can detect a genuine lapse if one exists.
                    updatedAccount?.hasActiveSubscription = true
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
        // Dismiss the lapse paywall once the user successfully restores their subscription.
        // We are always on .main when the lapse paywall is shown (navigated there immediately
        // at startup before the background subscription check), so no screen transition needed.
        .onReceive(NotificationCenter.default.publisher(for: .glacierPlanPurchaseSuccessful)) { _ in
            showSubscriptionLapsedPaywall = false
        }
        .fullScreenCover(isPresented: $showSubscriptionLapsedPaywall) {
            let viewModel = GlacierPlanPurchaseVM(
                rootCoodinator: glacierAppCoordinator,
                service: SKGlacierPlanPurchaseService()
            )
            GlacierPlanPurchaseScreen(viewModel: viewModel, isLapsePaywall: true)
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
