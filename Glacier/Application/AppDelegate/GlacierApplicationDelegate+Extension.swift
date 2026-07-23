//
//  GlacierApplicationDelegate+Extension.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 10/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//
import Foundation
import UserNotifications
import PushKit
import MBProgressHUD //ALF IOSM-498
import GRDB
import Amplify
import AWSCognitoAuthPlugin
import SwiftUI
import IOSSecuritySuite
public enum GlacierNotificationType {
    case connectionError
    case smsMessage
    case voicemail
}
extension GlacierNotificationType: RawRepresentable {
    public init?(rawValue: String) {
        if rawValue == kNotificationTypeConnectionError {
            self = .connectionError
        } else if rawValue == kNotificationTwilioType {
            self = .smsMessage
        } else if rawValue == kNotificationVoicemailType {
            self = .voicemail
        } else {
            return nil
        }
    }
    public var rawValue: String {
        switch self {
        case .connectionError:
            return kNotificationTypeConnectionError
        case .smsMessage:
            return kNotificationTwilioType
        case .voicemail:
            return kNotificationVoicemailType
        }
    }
    public typealias RawValue = String
}
public extension GlacierApplicationDelegate {
    // Guards the one-time posting of .userAuthenticationVerified at startup.
    // Static so it persists for the process lifetime (setupAmplify runs once per launch).
    // Internal (not private) so applicationWillEnterForeground in GlacierApplicationDelegate.swift
    // can check whether auth was deferred during a background launch.
    static var authVerificationPosted = false
    private static let authVerificationLock = NSLock()

    /// Set to `true` when the self-heal branch below writes `isUserLoggedIn` back
    /// because Amplify (Keychain-backed) confirmed a valid session while the
    /// UserDefaults read returned absent. That state is only reachable when the
    /// process's `cfprefsd` cache was primed empty during a background launch
    /// before first user authentication after device boot — i.e. the entire
    /// UserDefaults plist read empty and the in-process cache is now stale for
    /// every key, not just `isUserLoggedIn`. Callers (notably
    /// `UserOnboardingScreen.shouldShowUserOnboarding`) treat any UserDefaults
    /// read taken during this process lifetime as untrustworthy when this flag
    /// is set. Process-scoped because the next launch starts with a fresh cache.
    static var userDefaultsCachePoisoned = false
    func setupAmplify() {
        // GCD watchdog: guarantees the splash screen is never permanently stuck.
        // Uses DispatchQueue (not Swift concurrency) so it fires even when the Swift
        // cooperative thread pool is saturated by VPN-routed Amplify/Cognito hangs.
        // Covers the entire chain: configureAmplify + fetchAuthSession + fetchAttributes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self = self else { return }
            let cached = UserDefaultsService.shared.get(for: \.isUserLoggedIn) ?? false
            self.postAuthVerifiedOnce(signedIn: cached)
        }
        if UIApplication.shared.isProtectedDataAvailable {
            Task {
                await configureAmplifyIfNeeded()
                await tryFetchSession()
            }
        } else {
            // Launching before first user authentication after device boot. Every
            // UserDefaults read taken from now until this process exits is at risk
            // of returning a stale empty value even after the device unlocks —
            // cfprefsd's cache is per-process and there is no public API to force
            // a reload once it has been primed empty. Mark the flag here at launch
            // (rather than relying on the self-heal in tryFetchSession to detect
            // it later) so consumers that run before the user opens the app — most
            // importantly the vpnHealth BGAppRefreshTask — also see it.
            Self.userDefaultsCachePoisoned = true
            Log.auth.notice("[GlacierAuth] setupAmplify: launched while protectedData unavailable — marking cache poisoned")
            NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil,
                queue: .main
            ) { _ in
                SecurityCenter.isProxyDetected = IOSSecuritySuite.amIProxied()
                Task {
                    await self.configureAmplifyIfNeeded()
                    await self.tryFetchSession()
                }
            }
        }
    }
    func tryFetchSession() async {
        // presentLoginOnFailure: false — navigation is driven exclusively by the
        // .userAuthenticationVerified notification via postAuthVerifiedOnce, not by
        // AWSAcctManager.login(). Safe today (login() is a no-op) and future-proofs
        // against login() being re-enabled while the watchdog is still pending.
        //
        // Guard Amplify configuration: if configureAmplifyIfNeeded() caught a non-
        // alreadyConfigured error, amplifyIsConfigured stays false. Calling
        // Amplify.Auth.fetchAuthSession() without a configured Auth category triggers
        // Amplify's Fatal.preconditionFailure — the crash seen in build 134.
        guard amplifyIsConfigured else {
            postAuthVerifiedOnce(signedIn: UserDefaultsService.shared.get(for: \.isUserLoggedIn) ?? false)
            return
        }
        guard !SecurityCenter.isProxyDetected else {
            postAuthVerifiedOnce(signedIn: UserDefaultsService.shared.get(for: \.isUserLoggedIn) ?? false)
            return
        }
        // Snapshot local-install state BEFORE fetchCurrentAuthSession, which can
        // create a GlacierAccount row from the session token (via fetchAttributes)
        // and thereby mask a genuinely-empty container from the reinstall check below.
        let cacheTrustworthy = UIApplication.shared.isProtectedDataAvailable && !Self.userDefaultsCachePoisoned
        let hasCompletedFirstLaunch = UserDefaultsService.shared.get(for: \.hasCompletedFirstLaunch) ?? false
        let hadPriorUserState = (UserDefaultsService.shared.get(for: \.isUserLoggedIn) ?? false)
            || (UserDefaultsService.shared.get(for: \.isUserOnboardingCompleted) ?? false)
            || (GlacierAccountModel.getGlacierAccount() != nil)

        let amplifySignedIn = await AWSAcctManager.sharedMgr().fetchCurrentAuthSession(presentLoginOnFailure: false)

        // First-launch-after-(re)install detection.
        // iOS preserves the Keychain across an uninstall but wipes UserDefaults and
        // the app container, so a Cognito session left by a previous install (e.g. a
        // prior TestFlight build) makes fetchAuthSession report signed-in on a fresh
        // App Store install. The router then skips login and strands the user on the
        // (non-dismissible) lapse paywall. If Amplify reports signed-in on this
        // install's first trustworthy launch while the local container shows no prior
        // user state at all, this is that reinstall: clear the stale Keychain session
        // and route to login instead.
        //
        // Guards:
        //  - cacheTrustworthy: an absent UserDefaults read is only meaningful when
        //    protected data is available and cfprefsd's per-process cache wasn't
        //    primed empty (the reboot-before-first-unlock case). Otherwise skip — the
        //    launch is retried authoritatively from applicationWillEnterForeground.
        //  - hadPriorUserState: distinguishes a reinstall (empty container) from a
        //    normal app update of a logged-in user (UserDefaults/account survive), so
        //    an update never signs anyone out.
        //  - hasCompletedFirstLaunch: makes the detection fire at most once per install.
        if cacheTrustworthy && !hasCompletedFirstLaunch {
            if amplifySignedIn && !hadPriorUserState {
                Log.auth.notice("[GlacierAuth] tryFetchSession: signed-in Keychain session with an empty container on first launch — treating as reinstall, clearing stale session and routing to login.")
                _ = await Amplify.Auth.signOut()
                AWSAcctManager.sharedMgr().updateUI(forSignInStatus: false)
                UserDefaultsService.shared.remove(for: \.isUserLoggedIn)
                UserDefaultsService.shared.set(true, for: \.hasCompletedFirstLaunch)
                postAuthVerifiedOnce(signedIn: false)
                return
            }
            // Trustworthy launch with either no session or a legitimate existing
            // install — record it so the detection never fires on a later launch.
            UserDefaultsService.shared.set(true, for: \.hasCompletedFirstLaunch)
        }

        let cachedLoggedIn = UserDefaultsService.shared.get(for: \.isUserLoggedIn) ?? false
        // A fast `false` from Amplify during a VPN reconnect (partial tunnel, degraded
        // Cognito response) must not override a cached logged-in state.  A genuine
        // sign-out always clears isUserLoggedIn first, so if the cache says true the
        // user should be trusted even when Amplify momentarily disagrees.
        let signedIn = amplifySignedIn || cachedLoggedIn
        if !amplifySignedIn && cachedLoggedIn {
            Log.auth.notice("[Auth] Amplify returned false but cached isUserLoggedIn=true — treating as signed in (likely VPN reconnect).")
        }
        // Write back to UserDefaults whenever Amplify confirms the session is valid.
        // This self-heals the absent-key scenario: if UserDefaults was cleared (e.g.
        // after a device reboot before first unlock) while Keychain tokens survived,
        // the cache is now accurate for the next launch without requiring a full
        // Amplify round-trip.
        if amplifySignedIn && !cachedLoggedIn {
            UserDefaultsService.shared.set(true, for: \.isUserLoggedIn)
            Self.userDefaultsCachePoisoned = true
            // Probe the routing-decision flags. If they all read absent here, the
            // cache poisoning is confirmed and the splash routing must not trust
            // them. Logged once at notice level so the next sysdiagnose captures
            // the state — these reads themselves are returning the (likely stale)
            // empty values, so the probe is observational only.
            let probeOnboardingCompleted = UserDefaultsService.shared.get(for: \.isUserOnboardingCompleted) ?? false
            let probeSkipPhonePurchase = UserDefaultsService.shared.get(for: \.didSkipPhoneNumberPurchaseDuringOnboarding) ?? false
            let probeSkipPhoneSelection = UserDefaultsService.shared.get(for: \.didSkipPhoneNumberSelectionDuringOnboarding) ?? false
            Log.auth.notice("[GlacierAuth] tryFetchSession: Amplify confirmed valid but isUserLoggedIn was absent — marking cache poisoned. onboardingCompleted=\(probeOnboardingCompleted ? 1 : 0) skipPurchase=\(probeSkipPhonePurchase ? 1 : 0) skipSelection=\(probeSkipPhoneSelection ? 1 : 0)")
        }
        postAuthVerifiedOnce(signedIn: signedIn)
    }
    private func postAuthVerifiedOnce(signedIn: Bool) {
        Self.authVerificationLock.lock()
        defer { Self.authVerificationLock.unlock() }
        guard !Self.authVerificationPosted else {
            Log.auth.debug("[GlacierAuth] postAuthVerifiedOnce suppressed duplicate (signedIn=\(signedIn ? 1 : 0)) — already posted this launch")
            return
        }
        // Don't commit the auth routing decision during a background launch (e.g. the
        // vpnHealth BGAppRefreshTask).  The screen would be set before the user opens
        // the app and can't be corrected, because consuming the lock here would prevent
        // applicationWillEnterForeground from re-running tryFetchSession().
        // Returning without setting authVerificationPosted leaves the lock open so the
        // foreground path gets a fresh, authoritative result.
        guard UIApplication.shared.applicationState != .background else {
            Log.auth.debug("[GlacierAuth] postAuthVerifiedOnce deferred — app is in background (signedIn=\(signedIn ? 1 : 0))")
            return
        }
        Self.authVerificationPosted = true
        Log.auth.notice("[GlacierAuth] postAuthVerifiedOnce posting signedIn=\(signedIn ? 1 : 0)")
        NotificationCenter.default.post(
            name: .userAuthenticationVerified,
            object: nil,
            userInfo: [GlacierNotificationProperties.isAuthSessionValid: signedIn]
        )
    }
    func configureAmplifyIfNeeded() async {
        guard !self.amplifyIsConfigured else { return }

        // If a configuration task is already in flight, await it instead of
        // starting a second one. Multiple callers (direct path + protectedData
        // notification) can otherwise race on Amplify's internal plugin
        // dictionary and corrupt it (data race crash in AuthCategory.add).
        if amplifyConfigurationTask == nil {
            amplifyConfigurationTask = Task.detached(priority: .userInitiated) {
                // Amplify.add() and Amplify.configure() are synchronous. Called
                // directly from an async context on the @MainActor they would run
                // without ever suspending — blocking the main thread for however
                // long the AWS/Cognito plug-in spends doing its setup work.
                //
                // When the Glacier VPN is "on" but the device has no real network
                // (e.g. airplane mode), iOS system daemons that Cognito's plug-in
                // calls into (nehelper, trustd, securityd) can stall waiting for
                // the tunnel to reconnect.  That stall propagates back to the main
                // thread and prevents the GCD watchdog timer in setupAmplify() from
                // ever firing, which is exactly why the splash screen hangs.
                //
                // Task.detached breaks the main-actor isolation and runs the
                // synchronous work on the cooperative thread pool.  The main thread
                // stays free, so the watchdog always fires within its 10-second
                // budget regardless of how long Amplify.configure() takes.
                do {
                    try Amplify.add(plugin: AWSCognitoAuthPlugin())
                    try Amplify.configure()
                    return true
                } catch {
                    // Amplify throws ConfigurationError.amplifyAlreadyConfigured if
                    // configured more than once. Treat as success so authHeaders()
                    // can proceed normally instead of permanently returning nil.
                    if case .amplifyAlreadyConfigured = error as? ConfigurationError {
                        Log.auth.info("Amplify was already configured.")
                        return true
                    }
                    Log.auth.error("Failed to initialize Amplify: \(error)")
                    return false
                }
            }
        }

        let configured = await amplifyConfigurationTask!.value
        if configured {
            self.amplifyIsConfigured = true
            #if DEBUG
            Amplify.Logging.logLevel = .verbose
            #else
            Amplify.Logging.logLevel = .error
            #endif
            Log.auth.notice("Amplify configured successfully.")
        }
    }
    /// gets the last user interaction date, or current date if app is activate
    static func getLastInteractionDate(_ block: @escaping (_ lastInteractionDate: Date?)->(), completionQueue: DispatchQueue? = nil) {
        DispatchQueue.main.async {
            var date: Date? = nil
            if UIApplication.shared.applicationState == .active {
                date = Date()
            } else {
                date = self.lastInteractionDate
            }
            if let completionQueue = completionQueue {
                completionQueue.async {
                    block(date)
                }
            } else {
                block(date)
            }
        }
    }
    static func setLastInteractionDate(_ date: Date) {
        DispatchQueue.main.async {
            self.lastInteractionDate = date
        }
    }
    func getLatestSecurityInfo() -> SecurityInfoUtil? { //IOSM#110
        return self.securityCenter.getSecurityInfo()
    }
    func setVersionIssue(_ versionIssue:Bool) {
        self.securityCenter.setVersionIssue(versionIssue)
    }
    func getIgnoreCompromisedAlert() -> Bool { //IOSM#58 (next 2)
        return self.securityCenter.shouldIgnoreCompromisedAlert()
    }
    func setIgnoreCompromisedAlert(_ ignore:Bool) {
        self.securityCenter.setIgnoreCompromisedAlert(ignore)
    }
    func needsSecurityAlert() -> Bool {
        return self.securityCenter.getCurrentCompromisedStatus() && self.securityCenter.shouldIgnoreCompromisedAlert() == false
    }
    func needsSecurityAwareness() -> Bool {
        return self.securityCenter.getCurrentCompromisedStatus() || self.securityCenter.devicePasscodeEnabled() == false
    }
    func checkSecurity() {
        self.securityCenter.doSettingsSecurityChecks()
    }
    /// @warn only access this from main queue
    private static var lastInteractionDate: Date? = nil
}
