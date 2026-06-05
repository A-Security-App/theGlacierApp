//
//  GlacierApplicationDelegate.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 10/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Amplify
import AWSCognitoAuthPlugin
import BackgroundTasks
import Foundation
import GRDB
import MBProgressHUD
import NetworkExtension
import PushKit
import WidgetKit
import SAMKeychain
import SwiftUI
import IOSSecuritySuite
import UserNotifications

/**
 `GlacierApplicationDelegate` helps in managing Glacier app lifecycle events and setting up core modules.
 */
public class GlacierApplicationDelegate: UIResponder, UIApplicationDelegate {
    /// Set at launch so callers can reach the delegate without relying on
    /// UIApplication.shared.delegate, which returns SwiftUI's internal wrapper
    /// instead of this class when @UIApplicationDelegateAdaptor is used.
    public private(set) static weak var shared: GlacierApplicationDelegate?

    public private(set) var securityCenter: SecurityCenter = SecurityCenter()

    public var amplifyIsConfigured = false
    var amplifyConfigurationTask: Task<Bool, Never>?
    public var handledCallIDs = Set<String>()

    private var enteringForeground = false
    /// `true` only when `applicationWillEnterForeground` has fired and
    /// `applicationDidBecomeActive` has not yet reset it.  Used to distinguish
    /// a background→foreground transition (will fires first) from a cold launch
    /// (only didBecomeActive fires, will does not).
    private var didReceiveWillEnterForeground = false
    private var domainAddress: String?
    private var voipRegistry: PKPushRegistry?

    private var hud: MBProgressHUD?

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GlacierApplicationDelegate.shared = self
        SAMKeychain.setAccessibilityType(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)

        // Synchronous proxy check before any network-dependent setup
        SecurityCenter.isProxyDetected = IOSSecuritySuite.amIProxied()

        amplifyIsConfigured = false
        setupAmplify()

        refreshGlacierPlanSubscription()
        refreshGlacierPhoneNumberPlanSubscription()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(whenDatabaseReady(_:)),
            name: DBManager.didSetupDatabase,
            object: nil
        )
        
        DBManager.sharedDB()

        handledCallIDs = []
        enteringForeground = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProxyStateDidChange(_:)),
            name: SecurityCenter.proxyStateDidChange,
            object: nil
        )

        checkSecurity()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryStateDidChange(_:)),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryStateDidChange(nil)

        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.theglacierapp.Glacier.task.vpnHealth", using: nil) { [weak self] task in
            self?.beginVPNHealthCheck(task)
        }

        UNUserNotificationCenter.current().delegate = self
        registerVoIPNotifications()

        scheduleWeeklyRebootReminder()

        return true
    }

    @objc func whenDatabaseReady(_ notification: Notification) {
        if let hud {
            hud.removeFromSuperview()
        }

        handleDatabaseInitialization()
        checkSecurity()
    }

    func registerVoIPNotifications() {
        voipRegistry = PKPushRegistry(queue: nil)
        voipRegistry?.delegate = self
        voipRegistry?.desiredPushTypes = [.voIP]

        if let pushData = voipRegistry?.pushToken(for: .voIP) {
            handleVoipPushToken(pushData)
        }
    }

    public func applicationWillResignActive(_ application: UIApplication) {
        GlacierApplicationDelegate.setLastInteractionDate(Date())
    }

    public func applicationDidEnterBackground(_ application: UIApplication) {
        enteringForeground = false
        scheduleVPNHealthCheck()
    }

    public func applicationWillEnterForeground(_ application: UIApplication) {
        didReceiveWillEnterForeground = true
        enteringForeground = true

        // Synchronous proxy check — must gate the network calls below before the
        // async doSettingsSecurityChecks() has a chance to update the flag.
        SecurityCenter.isProxyDetected = IOSSecuritySuite.amIProxied()
        securityCenter.doSettingsSecurityChecks()

        guard !SecurityCenter.isProxyDetected else { return }

        // If the process was launched by a background task (e.g. vpnHealth
        // BGAppRefreshTask), postAuthVerifiedOnce deferred the notification rather
        // than consuming the one-time lock.  Run a fresh auth check now that the
        // user is actually opening the app so the routing decision reflects current
        // Amplify state rather than whatever was true during the background wake.
        if !GlacierApplicationDelegate.authVerificationPosted {
            Log.auth.notice("[GlacierAuth] applicationWillEnterForeground: auth not yet posted — re-running tryFetchSession")
            Task {
                await configureAmplifyIfNeeded()
                await tryFetchSession()
            }
        }

        refreshBackendSubscription()
        TwilioBackendManager.sharedMgr().queryForNumbers()
        TwilioBackendManager.sharedMgr().queryForVMInfo()
    }

    public func applicationDidBecomeActive(_ application: UIApplication) {
        GlacierApplicationDelegate.setLastInteractionDate(Date())
        batteryStateDidChange(nil)
        PhoneSubscriptionLifecycleHandler.shared.handleAppDidBecomeActive()
        didReceiveWillEnterForeground = false
        enteringForeground = false
    }

    public func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        return false
    }

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        //
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
    }

    @objc func batteryStateDidChange(_ notification: Notification?) {
        let currentState = UIDevice.current.batteryState
        if currentState == .charging || currentState == .full {
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - VPN health check background task

    private func scheduleVPNHealthCheck() {
        let request = BGAppRefreshTaskRequest(identifier: "com.theglacierapp.Glacier.task.vpnHealth")
        // Earliest begin date is a lower bound only — iOS decides the actual fire time.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.vpn.info("VPN health BGTask scheduled OK")
        } catch {
            Log.vpn.error("VPN health BGTask schedule failed: \(error.localizedDescription)")
        }
    }

    private func beginVPNHealthCheck(_ task: BGTask) {
        // Reschedule first so the chain continues even if we exhaust our time budget.
        scheduleVPNHealthCheck()

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        // Defer when this process started before first user authentication
        // after device boot. cfprefsd's cache was primed empty during that
        // launch and stays stale for this entire process lifetime — App Group
        // UserDefaults reads would return nil regardless of what's on disk.
        // Acting on a poisoned read here would: (a) interpret a stale
        // kActiveConnectionTypeKey=nil as "user deliberately disconnected" and
        // suppress the VPN reconnect attempt below, and (b) clear
        // kActiveConnectionTypeKey from the widget when wasVPNConnected
        // resolves to false. The reschedule above ensures the next attempt runs
        // ~15 min later in a fresh process (post-first-unlock cfprefsd cache).
        // NOTE: deliberately do *not* gate on `isProtectedDataAvailable` here.
        // That API tracks NSFileProtectionComplete-class availability, which
        // is false whenever the device is currently locked — but UserDefaults
        // uses NSFileProtectionCompleteUntilFirstUserAuthentication, which
        // remains readable across lock/unlock cycles after the first unlock.
        // Gating on it would defer every locked-screen BG task and regress
        // VPN re-arm during normal use.
        if GlacierApplicationDelegate.userDefaultsCachePoisoned {
            Log.vpn.notice("[VPNHealth] BGTask deferred — UserDefaults cache poisoned from pre-first-unlock launch")
            task.setTaskCompleted(success: false)
            return
        }

        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard error == nil, let managers, !managers.isEmpty else {
                task.setTaskCompleted(success: false)
                return
            }

            let isConnected = managers.contains {
                let s = $0.connection.status
                return s == .connected || s == .connecting || s == .reasserting
            }

            let sharedDefaults = UserDefaults(suiteName: kGlacierGroup)

            // Read user intent BEFORE updating the key. When the WireGuard extension
            // is killed while the app is backgrounded, the app never processes the
            // NEVPNStatusDidChange notification, so kActiveConnectionTypeKey still
            // holds "vpn" — that stale value is our signal that the user wanted it
            // running. A deliberate user disconnect clears this key from the foreground
            // before the app backgrounds, so wasVPNConnected will be false there.
            let wasVPNConnected = sharedDefaults?.string(forKey: kActiveConnectionTypeKey) == SecuredConnectionType.vpn.rawValue

            if !isConnected && wasVPNConnected {
                // System killed the extension while user wanted VPN running — notify and recover.
                self?.showVPNDisconnectedNotification()
                if let manager = managers.first(where: { $0.isEnabled }) {
                    do {
                        try manager.connection.startVPNTunnel()
                    } catch {
                        Log.vpn.error("VPN health: reconnect attempt failed: \(error.localizedDescription)")
                    }
                }
            }

            // Run local-only security checks — no API calls, safe in background.
            // Mirrors HomeViewModel.scanDeviceForSecurityIssues() but avoids
            // SecurityCenter.isCompromised() to prevent NotificationCenter
            // side-effects from a background context.
            let isJailbroken = IOSSecuritySuite.amIJailbrokenWithFailMessage().jailbroken
            let isProxied    = IOSSecuritySuite.amIProxied()
            let isRE         = IOSSecuritySuite.amIReverseEngineeredWithFailedChecks().reverseEngineered
            let isEmulator   = IOSSecuritySuite.amIRunInEmulator()

            // Update kActiveConnectionTypeKey only for the VPN case. If VPN is
            // connected we stamp it; if it was "vpn" but is now disconnected we clear
            // the stale value so the widget shows disconnected. DNS state is
            // unknown here so we leave a "dns" value untouched.
            if isConnected {
                sharedDefaults?.set(SecuredConnectionType.vpn.rawValue, forKey: kActiveConnectionTypeKey)
            } else if wasVPNConnected {
                sharedDefaults?.removeObject(forKey: kActiveConnectionTypeKey)
            }

            // Update security issue text using the same strings as HomeViewModel
            // so the widget shows a consistent message. Empty string = all clear.
            let issueText: String
            if isJailbroken {
                issueText = NSLocalizedString("Your system shows signs of being jailbroken.", comment: "Home screen jailbreak detection")
            } else if isRE {
                issueText = NSLocalizedString("This app appears to be running in a modified or analyzed environment.", comment: "Home screen reverse engineering detection")
            } else if isProxied {
                issueText = NSLocalizedString("Unusual network activity or modification tools have been identified.", comment: "Home screen tampering detection")
            } else if isEmulator {
                issueText = NSLocalizedString("The app appears to be running in a simulated environment.", comment: "Home screen running in emulator detection")
            } else {
                issueText = ""
            }
            sharedDefaults?.set(issueText, forKey: kWidgetSecurityIssueKey)

            WidgetCenter.shared.reloadAllTimelines()

            task.setTaskCompleted(success: true)
        }
    }

    private func showVPNDisconnectedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "VPN Disconnected"
        content.body = "Glacier detected your VPN is off. Tap to reconnect."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "vpn-health-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error as NSError? {
                Log.vpn.error("VPN health notification failed: \(error)")
            }
        }
    }

    public class var appDelegate: GlacierApplicationDelegate {
        // UIApplication.shared.delegate is SwiftUI's internal wrapper when
        // @UIApplicationDelegateAdaptor is used, so we use the shared reference
        // set in application(_:didFinishLaunchingWithOptions:) instead.
        guard let delegate = shared else {
            fatalError("GlacierApplicationDelegate.shared is nil – appDelegate accessed before application(_:didFinishLaunchingWithOptions:)")
        }
        return delegate
    }

    func setupTheme() {}

    /// Called when proxy detection state changes. Triggers reconnection when the proxy clears.
    @objc func handleProxyStateDidChange(_ notification: Notification) {
        guard let proxyDetected = notification.userInfo?["proxyDetected"] as? Bool else { return }
        guard !proxyDetected else { return }
        // Proxy cleared — re-establish connections
        reconnectAfterProxyCleared()
    }

    func reconnectAfterProxyCleared() {
        Task {
            await tryFetchSession()
        }
        refreshBackendSubscription()
        TwilioBackendManager.sharedMgr().queryForTwilioTokens()
        TwilioBackendManager.sharedMgr().queryForNumbers()
        TwilioBackendManager.sharedMgr().queryForVMInfo()
    }
}

public extension GlacierApplicationDelegate {
    
    func handleDatabaseInitialization() {
        if GlacierAccountModel.getGlacierAccount() == nil {
            // TODO: shou authentication screen
        } else if PushController.getPushPreference() == .undefined {
            let isSubscribed = GlacierAccountModel.getGlacierAccount()?.hasActivePhoneNumberSubscription ?? false
            if isSubscribed {
                SubscriptionAccessCoordinator.shared.handleSubscriptionStatusChange(isSubscribed: true)
            }
        }
    }
    
    func showLocalNotificationWith(identifier:String?, body:String, badge:Int, userInfo:[AnyHashable:Any]?) {
        DispatchQueue.main.async {
            
            // message from user display name without domain/address
            var bodyslim = body
            let msgparts = body.components(separatedBy: ":")
            if (msgparts.count >= 2) {
                let namecomponents = msgparts[0].components(separatedBy: "@")
                if (namecomponents.count == 2) {
                    if let range = body.range(of: ":") {
                        //let msgtext = body.substring(from: range.lowerBound)
                        let msgtext = String(body[range.lowerBound...])
                        bodyslim = namecomponents[0] + msgtext;
                    }
                }
            }
            
            let localNotification = UNMutableNotificationContent()
            localNotification.body = bodyslim
            localNotification.badge = NSNumber(integerLiteral: badge)
                
            // use non-default alert sound
            let sound = UNNotificationSoundName(rawValue: "NewMessageAlert.wav")
            localNotification.sound = UNNotificationSound(named: sound)
                
            if let identifier = identifier {
                localNotification.threadIdentifier = identifier
            }
            if let userInfo = userInfo {
                localNotification.userInfo = userInfo
            }
            var trigger:UNNotificationTrigger? = nil

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: localNotification, trigger: trigger) // Schedule the notification.
            let center = UNUserNotificationCenter.current()
            center.add(request, withCompletionHandler: { (error: Error?) in
                if let error = error as NSError? {
                    Log.general.error("Error scheduling notification: \(error)")
                }
            })
        }
    }

    /// Registers a repeating weekly "time to reboot" reminder with the system.
    ///
    /// Uses a `UNCalendarNotificationTrigger` rather than firing from the
    /// `vpnHealth` BGAppRefreshTask: the OS owns delivery, so the reminder fires
    /// even when Background App Refresh is disabled, the task is throttled, or the
    /// user rarely opens the app — the cohort most likely to need the nudge and
    /// the one the background-task path failed for.
    ///
    /// Idempotent: a fixed identifier means re-scheduling on every launch replaces
    /// the pending request instead of stacking duplicates. Safe to call whenever.
    func scheduleWeeklyRebootReminder() {
        // Respect the user's Settings toggle; default on when the key is absent.
        let enabled = UserDefaultsService.shared.get(for: \.isRebootReminderEnabled) ?? true
        guard enabled else {
            cancelWeeklyRebootReminder()
            return
        }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            default:
                // Not authorized — nothing to schedule. Re-scheduled on a future
                // launch once permission is granted.
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Reminder to reboot"
            content.body = "Rebooting your device helps maintain iOS security and protects against potential threats."

            // Weekday-only DateComponents repeats weekly. Sunday 21:00 local time.
            // (Gregorian weekday: Sunday = 1.)
            var dateComponents = DateComponents()
            dateComponents.weekday = 1
            dateComponents.hour = 21
            dateComponents.minute = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

            let request = UNNotificationRequest(
                identifier: kRebootReminderNotificationId,
                content: content,
                trigger: trigger
            )
            center.add(request) { error in
                if let error = error as NSError? {
                    Log.general.error("Error scheduling weekly reboot reminder: \(error)")
                }
            }
        }
    }

    /// Removes the pending weekly reboot reminder. Called when the user turns the
    /// reminder off in Settings.
    func cancelWeeklyRebootReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [kRebootReminderNotificationId])
    }

}

extension GlacierApplicationDelegate: SecurityUpdateDel {
    public func securityInfoUpdated(_ success: Bool) {}
}

// MARK: - UNUserNotificationCenterDelegate
extension GlacierApplicationDelegate: UNUserNotificationCenterDelegate {
    
    private func extractNotificationType(notification: UNNotification) -> GlacierNotificationType? {
        let userInfo = notification.request.content.userInfo
        if let rawNotificationType = userInfo[kNotificationType] as? String {
            return GlacierNotificationType(rawValue: rawNotificationType)
        } else if userInfo[kNotificationTwilioType] is String { //we use the key here for NotificationType also, not the value
            return GlacierNotificationType(rawValue: kNotificationTwilioType)
        } else {
            return nil
        }
    }
    
    private func extractThreadInformation(notification: UNNotification) -> (key: String, collection: String)? {
        let userInfo = notification.request.content.userInfo
        if let threadKey = userInfo[kNotificationThreadKey] as? String,
           let threadCollection = userInfo[kNotificationThreadCollection] as? String {
            return (threadKey, threadCollection)
        }
        return nil
    }
    
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard let notificationType = extractNotificationType(notification: response.notification) else {
            completionHandler()
            return
        }
        
        let appd = GlacierApplicationDelegate.appDelegate
        switch notificationType {
        case .connectionError:
            break
        case .smsMessage:
            break
        case .voicemail:
//            appd.window?.rootViewController = appd.dialerViewController
//            if let dialer = appd.dialerViewController.viewControllers.first as? DialerViewController { dialer.vmButtonPressed()
//            }
            break
        }
        
        completionHandler()
    }
    
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard let notificationType = extractNotificationType(notification: notification) else {
            // unknown notification type, so let's show one just in case?
            completionHandler([.badge, .sound, .banner, .list])
            return
        }
        
        switch notificationType {
        case .connectionError:
            completionHandler([.badge, .sound, .banner, .list])
        case .smsMessage:
            completionHandler([.badge, .sound, .banner, .list])
        case .voicemail:
            completionHandler([.badge, .sound, .banner, .list])
        }
    }
}

extension GlacierApplicationDelegate: PKPushRegistryDelegate {
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        if type == .voIP {
            self.handleVoipPushToken(pushCredentials.token)
        }
    }
    
    public func handleVoipPushToken(_ token: Data) {
        CallManager.sharedCallManager().credentialsUpdated(token)
    }
    
    public func pushRegistry(_ registry: PKPushRegistry,
                              didReceiveIncomingPushWith payload: PKPushPayload,
                              for type: PKPushType,
                              completion: @escaping () -> Void) {
        if type == .voIP {
            //if UIApplication.shared.applicationState == .background {
            //AND NOT TWILIO key:twi_message_type, twilio.voice.call
            let userInfo = payload.dictionaryPayload
            
            let jsonData: Data?
            do {
                jsonData = try JSONSerialization.data(withJSONObject: userInfo, options: [.prettyPrinted])
            } catch {
                Log.calls.error("Failed to serialize VoIP push payload for logging: \(error)")
                jsonData = nil
            }
            if let jsonData, let jsonString = String(data: jsonData, encoding: .utf8) {
                Log.calls.debug("Received VoIP push payload:\n\(jsonString)")
            } else {
                Log.calls.debug("Received VoIP push payload (raw): \(userInfo)")
            }
            
            if let type = userInfo[kNotificationTwilioType] as? String, type == kNotificationTwilioVoiceCall {
                //looks like Twilio library wants to get called first
                CallManager.sharedCallManager().incomingCallReceived(callInfo: userInfo)
                completion()
            } else {
                //still need to report call but this shouldn't happen
            }
        }
    }
}
