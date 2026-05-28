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
                self.login()
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
                    if GlacierAccountModel.getGlacierAccount() == nil {
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
