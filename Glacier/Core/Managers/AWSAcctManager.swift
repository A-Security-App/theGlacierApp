//
//  AWSAcctManager.swift
//  Glacier
//
//  Created by andyfriedman on 11/27/24.
//  Copyright © 2024 Glacier. All rights reserved.
//
import Foundation
import Amplify
import AWSCognitoAuthPlugin
import AWSPluginsCore
import Alamofire
import JWTDecode
public protocol SecurityUpdateDel {
    func securityInfoUpdated(_ success:Bool)
}
open class AWSAcctManager: NSObject
{
    private static let shared = AWSAcctManager()
    private var secUpdateDelegate:SecurityUpdateDel?
    private var vpnOnly = false
    private var reauthNeeded = false
    // Guards the one-time forced logout on a terminal auth failure so that a burst
    // of failing fetchAuthSession calls (the app fires several in parallel) only
    // routes to the login screen once. Reset on a fresh sign-in.
    private var didHandleSessionExpiry = false
    private let sessionExpiryLock = NSLock()
    let workQueue = DispatchQueue(label: "AWS Queue", qos: .userInitiated)
    private var userName:String?
    private var bucketOrg:String?
    private var deviceId:String?
    private var coreRegionsList:[String]?
    private var wgProfiles:[URL] = []
    //private var glacierOrgInfo:GlacierOrg?
    private var latestVersions:LatestVersions?
    private var coreGroup:DispatchGroup?
    public let userData = UserData()
    private var unsubscribeToken:UnsubscribeToken?
    public class func sharedMgr() -> AWSAcctManager {
        return shared
    }
    override public init() {
        super.init()
        self.setupDownloadDirectory()
        unsubscribeToken = Amplify.Hub.listen(to: .auth) { payload in
            switch payload.eventName {
            case HubPayload.EventName.Auth.signedIn:
                Log.auth.notice("User signed in")
                self.userData.isSignedIn = true
                self.resetSessionExpiryGuard()
                self.endLogin()
                SubscriptionAccessCoordinator.shared.handleSubscriptionStatusChange(isSubscribed: GlacierAccountModel.getGlacierAccount()?.hasActivePhoneNumberSubscription ?? false)
                Task {
                    let success = await self.fetchCurrentAuthSession(maxAttempts: 5)
                    if success {
                        if let userAccount = GlacierAccountModel.getGlacierAccount(), userAccount.hasActivePhoneNumberSubscription {
                            TwilioBackendManager.sharedMgr().queryForNumbers()
                        }
                    } else {
                        Log.auth.warning("[AWSAcctManager] Unable to establish auth session after sign-in event")
                    }
                }
            case HubPayload.EventName.Auth.sessionExpired:
                Log.auth.notice("Session expired")
                // Amplify emits this event only when the session cannot be
                // refreshed — the refresh token is expired/revoked or the Cognito
                // user was deleted. It is never emitted for transient network or
                // service errors (those keep the session intact), so forcing a
                // clean logout here cannot prematurely sign out a recoverable
                // session.
                Task { await self.handleTerminalSessionExpiry() }
            case HubPayload.EventName.Auth.signedOut:
                Log.auth.notice("User signed out")
                SubscriptionAccessCoordinator.shared.handleSubscriptionStatusChange(isSubscribed: false)
                self.login()
            case HubPayload.EventName.Auth.userDeleted:
                Log.auth.notice("User deleted")
                // Update UI
            default:
                break
            }
        }
    }
    func login() {
        // no-op?
    }
    func updateUI(forSignInStatus : Bool) {
        DispatchQueue.main.async() {
            self.userData.isSignedIn = forSignInStatus
        }
    }
    func fetchCurrentAuthSession(maxAttempts: Int = 1, presentLoginOnFailure: Bool = true) async -> Bool {
        guard GlacierApplicationDelegate.shared?.amplifyIsConfigured == true else {
            return false
        }
        let attempts = max(maxAttempts, 1)
        var attemptIndex = 0
        var lastError: Error?
        var shouldTriggerLogin = false
        while attemptIndex < attempts {
            do {
                let session = try await Amplify.Auth.fetchAuthSession()
                Log.auth.info("Is user signed in - \(session.isSignedIn)")
                self.updateUI(forSignInStatus: session.isSignedIn)
                if session.isSignedIn {
                    // A session can report isSignedIn == true while every token
                    // accessor fails with a terminal auth error (e.g. the Cognito
                    // user was deleted or the refresh token was revoked). Detect
                    // that here so we don't report a false success and loop
                    // fetchAuthSession forever. Network/service errors are NOT
                    // terminal and fall through to the normal success/retry path.
                    if let cognitoSession = session as? AWSAuthCognitoSession,
                       case .failure(let tokenError) = cognitoSession.getCognitoTokens(),
                       Self.isTerminalAuthFailure(tokenError) {
                        Log.auth.notice("[AWSAcctManager] Session reports signed-in but tokens are terminally invalid: \(tokenError)")
                        await self.handleTerminalSessionExpiry()
                        return false
                    }
                    await self.fetchAttributes()
                    return true
                }
                if attemptIndex < attempts - 1 {
                    let delay = pow(2.0, Double(attemptIndex)) * 0.5
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attemptIndex += 1
                    continue
                }
                Log.auth.notice("Not signed in")
                shouldTriggerLogin = presentLoginOnFailure
                return false
            } catch {
                lastError = error
                if attemptIndex < attempts - 1 {
                    let delay = pow(2.0, Double(attemptIndex)) * 0.5
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attemptIndex += 1
                    continue
                }
                if let authError = error as? AuthError {
                    Log.auth.error("Fetch session failed with error \(authError)")
                } else {
                    Log.auth.error("Unexpected error: \(error)")
                }
                shouldTriggerLogin = presentLoginOnFailure
                // A throw here means a network/system error, not an auth failure (which
                // returns session.isSignedIn == false without throwing).  On the startup
                // path (presentLoginOnFailure: false) fall back to the cached login state,
                // the same strategy the 10-second watchdog uses.  This prevents a false
                // login screen when the WireGuard tunnel is still reconnecting after the
                // app was offloaded (e.g. cold-launched via a widget tap).
                if !presentLoginOnFailure {
                    return UserDefaultsService.shared.get(for: \.isUserLoggedIn) ?? false
                }
                break
            }
        }
        if let error = lastError {
            Log.auth.warning("[AWSAcctManager] fetchCurrentAuthSession ultimately failed: \(error)")
        }
        if shouldTriggerLogin {
            self.login()
        }
        return false
    }

    /// Returns true only for auth failures from which the session cannot recover —
    /// the refresh token was rejected (expired/revoked) or the Cognito user was
    /// deleted. Network and service errors (`.service`) are explicitly NOT terminal
    /// so a bad connection never triggers a logout; they are left to retry/refresh.
    private static func isTerminalAuthFailure(_ error: AuthError) -> Bool {
        switch error {
        case .sessionExpired, .notAuthorized:
            return true
        default:
            return false
        }
    }

    /// Forces a clean logout after a terminal auth failure and routes the user to
    /// the login screen. Guarded so the parallel burst of failing session fetches
    /// only triggers this once per signed-in session.
    private func handleTerminalSessionExpiry() async {
        sessionExpiryLock.lock()
        if didHandleSessionExpiry {
            sessionExpiryLock.unlock()
            return
        }
        didHandleSessionExpiry = true
        sessionExpiryLock.unlock()

        Log.auth.notice("[AWSAcctManager] Terminal session expiry — signing out and routing to login")

        // Sign out so Amplify clears the dead tokens from the keychain. Without
        // this the stale refresh token stays cached and every relaunch hits the
        // same NotAuthorizedException loop.
        _ = await Amplify.Auth.signOut()

        // Clear the cached logged-in flag, mirroring the manual sign-out in
        // SettingsViewModel. This is essential: the startup fallback in
        // tryFetchSession uses `signedIn = amplifySignedIn || cachedLoggedIn` so a
        // transient VPN/network failure never falsely logs the user out. But after
        // a genuine terminal expiry Amplify correctly reports "not signed in", and
        // if this flag were left true the fallback would override that and route
        // the user back to a logged-in-looking main screen with no valid session —
        // every authenticated call then fails silently (signedOut). Clearing it
        // here means the next launch sees cachedLoggedIn=false and routes cleanly
        // to the login screen. Only reached on a confirmed terminal failure, so it
        // does not regress the transient-failure protection.
        UserDefaultsService.shared.remove(for: \.isUserLoggedIn)

        // Route to the auth screen. Posting isAuthSessionValid=false makes
        // GlacierAppRootScreen show the "Your session has expired" alert (when the
        // user was logged in) and present the login screen. Posted directly rather
        // than via postAuthVerifiedOnce because that path is locked to fire once
        // per launch for the startup routing decision.
        await MainActor.run {
            self.updateUI(forSignInStatus: false)
            NotificationCenter.default.post(
                name: .userAuthenticationVerified,
                object: nil,
                userInfo: [GlacierNotificationProperties.isAuthSessionValid: false]
            )
        }
    }

    /// Re-arms the terminal-session-expiry guard after a fresh sign-in so a later
    /// expiry within the same app launch is handled again.
    private func resetSessionExpiryGuard() {
        sessionExpiryLock.lock()
        didHandleSessionExpiry = false
        sessionExpiryLock.unlock()
    }

    func fetchAttributes() async {
        do {
            let session = try await Amplify.Auth.fetchAuthSession() as? AWSAuthCognitoSession
            if let accessToken = try session?.getCognitoTokens().get().accessToken, let idToken = try session?.getCognitoTokens().get().idToken {
                let jwt: JWT?
                do {
                    jwt = try decode(jwt: idToken)
                } catch {
                    Log.auth.error("Failed to decode Cognito id token: \(error)")
                    jwt = nil
                }
                if let jwt, let email = jwt.claim(name: "email").string {
                    if let existingAccount = GlacierAccountModel.getGlacierAccount() {
                        // Self-heal a stale record left over from a previous user
                        // (e.g. if logout cleanup didn't fully run). If the
                        // persisted username doesn't match the signed-in email,
                        // update it so Settings reflects the current user.
                        if existingAccount.username != email {
                            existingAccount.username = email
                            existingAccount.loginDate = Date()
                            existingAccount.saveAccount()
                            TwilioBackendManager.sharedMgr().identity = email
                        }
                    } else {
                        let account = GlacierAccountModel(username: email)
                        account.loginDate = Date()
                        account.saveAccount()
                        TwilioBackendManager.sharedMgr().identity = email
                    }
                    if let exp = jwt.expiresAt {
                        Log.auth.debug("Token expires at: \(exp)")
                    }
                }
                /*if let jwt = try? decode(jwt: token) {
                    if let exp = jwt.expiresAt {
                        print("Token expires at: \(exp)")
                    }
                }*/
                TwilioBackendManager.sharedMgr().setAccessToken(accessToken)
                SubscriptionAccessCoordinator.shared.handleSubscriptionStatusChange(isSubscribed: GlacierAccountModel.getGlacierAccount()?.hasActivePhoneNumberSubscription ?? false)
                SubscriptionAccessCoordinator.shared.accessTokenDidUpdate()
                //do stuff
            }
            /*let attributes = try await Amplify.Auth.fetchUserAttributes()
            if let emailAttr = attributes.first(where: { $0.key.rawValue == "email" }) {
                print("User email is: \(emailAttr.value)")
            } else {
                print("Email attribute not found")
            }*/
            //self.endLogin()
            //print("User attributes - \(attributes)")
        } catch let error as AuthError{
            Log.auth.error("Fetching user attributes failed with error \(error)")
            self.endLogin()
        } catch {
            Log.auth.error("Unexpected error: \(error)")
            self.endLogin()
        }
    }
    /// Decode JWT payload into [String:Any]
    /*private func decode(jwtToken jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count == 3 else { return nil }
        let payloadSegment = String(segments[1])
        guard let payloadData = base64UrlDecode(payloadSegment) else { return nil }
        let json = try? JSONSerialization.jsonObject(with: payloadData, options: [])
        return json as? [String: Any]
    }
    /// Decode a base64url string (part of JWT) into Data
    private func base64UrlDecode(_ base64Url: String) -> Data? {
        var base64 = base64Url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - base64.count % 4
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }
        return Data(base64Encoded: base64)
    }*/
    func queryProfileInfo() {
        //WireGuardManager.shared().queryForProfiles()
    }
    /*func getGlacierEnablements() -> GlacierOrg? {
        return self.glacierOrgInfo
    }*/
    func getLatestVersions() -> LatestVersions? {
        return self.latestVersions
    }
    
    func endLogin() {
//        DispatchQueue.main.async {
//            GlacierAppDelegate.appDelegate.summaryViewController.endAuthLogin()
//        }
    }
    private func setupDownloadDirectory() {
        do {
            let downloadsURL = URL(fileURLWithPath: NSTemporaryDirectory(),
                                 isDirectory: true).appending(path: "download")
            try FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        } catch {
            Log.auth.warning("Creating 'download' directory failed: \(error)")
        }
    }
    public func teardownCognito() {
        Task {
            //let options = AuthSignOutRequest.Options()
            let _ = await Amplify.Auth.signOut()
        }
    }
    func getJsonObject(_ jsonString: String) -> Dictionary<String,Any>? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        let parsed: Any?
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: .allowFragments)
        } catch {
            Log.auth.error("Failed to parse JSON string: \(error)")
            return nil
        }
        if let json = parsed as? Dictionary<String,Any> {
            Log.auth.debug("getJsonObject: \(json)")
            return json
        }
        return nil
    }
}
public final class UserData: ObservableObject {
    @Published var isSignedIn : Bool = false
}
