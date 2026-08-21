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
import AWSPluginsCore
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
    // Guards the one-time posting of an *authoritative* .userAuthenticationVerified at
    // startup. Static so it persists for the process lifetime (setupAmplify runs once per
    // launch). Internal (not private) so applicationWillEnterForeground in
    // GlacierApplicationDelegate.swift can check whether auth was deferred during a
    // background launch.
    static var authVerificationPosted = false
    /// Guards the one-time posting of a *provisional* verdict — the launch watchdog and the
    /// not-configured / proxy guards, which answer from cache so the splash can dismiss
    /// without waiting on the network. Tracked separately from `authVerificationPosted` so a
    /// guess never consumes the slot reserved for the real answer: before this split, a
    /// watchdog firing during a stalled Cognito lookup locked the login screen in for the
    /// whole launch and the correct result that arrived moments later was discarded.
    static var provisionalVerdictPosted = false
    /// `true` while a `tryFetchSession()` is running. Because a provisional post no longer
    /// sets `authVerificationPosted`, `applicationWillEnterForeground` would otherwise start
    /// a fresh session fetch on every foreground until an authoritative verdict lands —
    /// stacking overlapping Cognito calls on exactly the bad networks where the first one is
    /// still hung.
    static var authFetchInFlight = false
    /// `true` while a sign-in request is actually on the wire. Set by
    /// `AmplifyAuthenticationService` around every Amplify sign-in / confirm-sign-in call. A
    /// late authoritative verdict must not re-route the app out from under a submit. Written
    /// from the sign-in task and read on the main actor, so access is lock-guarded.
    static var isSignInInFlight: Bool {
        get { signInFlightLock.withLock { _isSignInInFlight } }
        set { signInFlightLock.withLock { _isSignInInFlight = newValue } }
    }
    private static var _isSignInInFlight = false
    private static let signInFlightLock = NSLock()
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
            self.postAuthVerified(signedIn: cached, authoritative: false)
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
        // Only one session fetch at a time. applicationWillEnterForeground re-runs this
        // until an authoritative verdict is posted, so without this guard a user
        // backgrounding and foregrounding on a stalled network would stack overlapping
        // Cognito calls.
        Self.authVerificationLock.lock()
        if Self.authFetchInFlight {
            Self.authVerificationLock.unlock()
            Log.auth.debug("[GlacierAuth] tryFetchSession skipped — a session fetch is already in flight")
            return
        }
        Self.authFetchInFlight = true
        Self.authVerificationLock.unlock()
        defer {
            Self.authVerificationLock.lock()
            Self.authFetchInFlight = false
            Self.authVerificationLock.unlock()
        }

        // presentLoginOnFailure: false — navigation is driven exclusively by the
        // .userAuthenticationVerified notification via postAuthVerified, not by
        // AWSAcctManager.login(). Safe today (login() is a no-op) and future-proofs
        // against login() being re-enabled while the watchdog is still pending.
        //
        // Guard Amplify configuration: if configureAmplifyIfNeeded() caught a non-
        // alreadyConfigured error, amplifyIsConfigured stays false. Calling
        // Amplify.Auth.fetchAuthSession() without a configured Auth category triggers
        // Amplify's Fatal.preconditionFailure — the crash seen in build 134.
        guard amplifyIsConfigured else {
            postAuthVerified(
                signedIn: UserDefaultsService.shared.get(for: \.isUserLoggedIn) ?? false,
                authoritative: false
            )
            return
        }
        guard !SecurityCenter.isProxyDetected else {
            postAuthVerified(
                signedIn: UserDefaultsService.shared.get(for: \.isUserLoggedIn) ?? false,
                authoritative: false
            )
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

        // Seed the DoT hostname-label digest once, using the same trustworthy-launch snapshot the
        // reinstall detection below relies on. An existing user hostname is unchanged; a fresh
        // install / reinstall is seeded from a random UUID so no device identifier feeds the label.
        // Guarded by cacheTrustworthy so an existing user is never misread as new; done before
        // fetchCurrentAuthSession, which can create a GlacierAccount row and mask an empty container.
        if cacheTrustworthy {
            DnsOverTlsController.shared.seedDeviceLabelHashIfNeeded(isExistingUser: hadPriorUserState)
        }

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
                postAuthVerified(signedIn: false, authoritative: true, canDowngrade: true)
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
        // canDowngrade: false — `signedIn` here is `amplifySignedIn || cachedLoggedIn`, so a
        // `false` can be produced purely by a failed network call. It may correct the routing
        // towards signed-in, but it must never sign out a user who has, for example, logged in
        // manually while this fetch was hung.
        postAuthVerified(signedIn: signedIn, authoritative: true, canDowngrade: false)

        // Runs after the verdict is posted so it can never delay routing.
        await migrateOffIdentityPoolCredentialsIfNeeded(signedIn: signedIn)
    }

    /// Converts credentials minted by a build that still declared the Cognito identity pool
    /// into the `userPoolOnly` shape the current configuration expects.
    ///
    /// Amplify keys the refresh path off the *stored* credential shape, not the current
    /// configuration. A device holding `userPoolAndIdentityPool` credentials whose user pool
    /// tokens are still mid-life takes the "just refresh the AWS credentials" branch, which
    /// now hits `FetchSessionError.noIdentityPool` — and because the resulting error state
    /// feeds back into the same branch, every authenticated call fails until the tokens
    /// expire on their own, across relaunches. A forced refresh takes the token-refresh
    /// branch regardless of token validity, which rewrites the stored credentials and ends
    /// the window immediately.
    ///
    /// Runs at most once per install, and only commits the flag when the session comes back
    /// with usable tokens — a refresh that fails on a bad network is simply retried on the
    /// next launch.
    private func migrateOffIdentityPoolCredentialsIfNeeded(signedIn: Bool) async {
        guard UserDefaultsService.shared.get(for: \.didMigrateOffIdentityPoolCredentials) != true,
              amplifyIsConfigured else {
            return
        }
        guard signedIn else {
            // No session to migrate. Any future sign-in mints user-pool-only credentials
            // because the identity pool is no longer configured.
            UserDefaultsService.shared.set(true, for: \.didMigrateOffIdentityPoolCredentials)
            return
        }
        do {
            let session = try await Amplify.Auth.fetchAuthSession(options: .forceRefresh())
            guard session.isSignedIn else {
                UserDefaultsService.shared.set(true, for: \.didMigrateOffIdentityPoolCredentials)
                return
            }
            // A session can return successfully while every token accessor fails — that is
            // exactly the broken state this migration exists to clear — so confirm the tokens
            // resolved before recording it as done.
            if let cognitoSession = session as? AWSAuthCognitoSession,
               case .failure(let error) = cognitoSession.getCognitoTokens() {
                Log.auth.notice("[GlacierAuth] identity-pool credential migration: forced refresh returned no usable tokens (\(error)) — retrying next launch")
                return
            }
            UserDefaultsService.shared.set(true, for: \.didMigrateOffIdentityPoolCredentials)
            Log.auth.notice("[GlacierAuth] identity-pool credential migration: stored credentials rewritten as user-pool-only")
        } catch {
            Log.auth.notice("[GlacierAuth] identity-pool credential migration: forced refresh failed (\(error)) — retrying next launch")
        }
    }
    /// Posts the auth routing verdict.
    ///
    /// - Parameters:
    ///   - authoritative: `true` for a verdict derived from an actual session check,
    ///     `false` for a cached placeholder posted so the splash can dismiss without waiting
    ///     on the network. One of each may be posted per launch: the placeholder dismisses
    ///     the splash, the authoritative verdict corrects it if the guess was wrong. An
    ///     authoritative verdict is never suppressed by a preceding placeholder.
    ///   - canDowngrade: whether this verdict is allowed to route an already-signed-in
    ///     screen back to login. Only pass `true` with real evidence the user is signed
    ///     out; a verdict that merely failed to reach the network must not be able to
    ///     discard a session established since it was requested.
    private func postAuthVerified(signedIn: Bool, authoritative: Bool, canDowngrade: Bool = false) {
        Self.authVerificationLock.lock()
        defer { Self.authVerificationLock.unlock() }
        guard !Self.authVerificationPosted else {
            Log.auth.debug("[GlacierAuth] postAuthVerified suppressed (signedIn=\(signedIn ? 1 : 0), authoritative=\(authoritative ? 1 : 0)) — authoritative verdict already posted this launch")
            return
        }
        if !authoritative, Self.provisionalVerdictPosted {
            Log.auth.debug("[GlacierAuth] postAuthVerified suppressed duplicate provisional verdict (signedIn=\(signedIn ? 1 : 0))")
            return
        }
        // Don't commit the auth routing decision during a background launch (e.g. the
        // vpnHealth BGAppRefreshTask).  The screen would be set before the user opens
        // the app and can't be corrected, because consuming the lock here would prevent
        // applicationWillEnterForeground from re-running tryFetchSession().
        // Returning without setting authVerificationPosted leaves the lock open so the
        // foreground path gets a fresh, authoritative result.
        guard UIApplication.shared.applicationState != .background else {
            Log.auth.debug("[GlacierAuth] postAuthVerified deferred — app is in background (signedIn=\(signedIn ? 1 : 0))")
            return
        }
        if authoritative {
            Self.authVerificationPosted = true
        } else {
            Self.provisionalVerdictPosted = true
        }
        Log.auth.notice("[GlacierAuth] postAuthVerified posting signedIn=\(signedIn ? 1 : 0) authoritative=\(authoritative ? 1 : 0) canDowngrade=\(canDowngrade ? 1 : 0)")
        NotificationCenter.default.post(
            name: .userAuthenticationVerified,
            object: nil,
            userInfo: [
                GlacierNotificationProperties.isAuthSessionValid: signedIn,
                GlacierNotificationProperties.isAuthVerdictProvisional: !authoritative,
                GlacierNotificationProperties.authVerdictCanDowngrade: canDowngrade
            ]
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
