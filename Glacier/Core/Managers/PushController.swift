//
//  PushController.swift
//  Glacier
//
import UIKit
import Foundation
import UserNotifications
import TwilioVoice
public enum PushPreference: Int {
    case undefined
    case disabled
    case enabled
}
/**
 The purpose of this class is to tie together the api client and the data store.
 It also provides some helper methods that makes dealing with the api easier
 */
open class PushController: NSObject {
    var pubsubEndpoint: NSString?
    var pushToken: String?
    var voipToken: String?
    /// This will delete all your push data and disable push
    open func deactivate() {
        PushController.setPushPreference(.disabled)
    }
    //MARK: Push Preferences
    public static func getPushPreference() -> PushPreference {
        guard let value = UserDefaults.standard.object(forKey: kPushEnabledKey) as? NSNumber else {
            return .undefined
        }
        if value.boolValue == true {
            return .enabled
        } else {
            return .disabled
        }
    }
    public static func setPushPreference(_ preference: PushPreference) {
        var bool = false
        if preference == .enabled {
            bool = true
        }
        UserDefaults.standard.set(bool, forKey: kPushEnabledKey)
        UserDefaults.standard.synchronize()
    }
    //MARK: Utility
    public static func registerForPushNotifications() {
        // PREM: Push notification permission is obtained during user onboarding flow, so it shouldn't happen here
        return
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.badge, .alert, .sound], completionHandler: { (granted, error) in
            DispatchQueue.main.async(execute: {
                // TODO: Handle push registration error
                let app = UIApplication.shared
                NotificationCenter.default.post(name: Notification.Name(rawValue: UserNotificationsChanged), object: app.delegate, userInfo:nil)
                if (granted) {
                    app.registerForRemoteNotifications()
                }
            })
        })
    }
    public static func checkPushNotifications() {
        if PushController.getPushPreference() != .enabled {
            PushController.enablePush()
        } else {
            UNUserNotificationCenter.current().getNotificationSettings(completionHandler: { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional: return
                case .denied, .notDetermined: PushController.enablePush()
                case .ephemeral: return
                }
            })
        }
    }
    private static func enablePush() {
        PushController.setPushPreference(.enabled)
        PushController.registerForPushNotifications()
    }
    public func setPushToken(_ token: String!) -> Void {
        pushToken = token
    }
    public func getPushToken() -> String? {
        return pushToken
    }
    public func setVoipToken(_ token: Data) -> Void {
        voipToken = token.toHexString()
    }
    public func getVoipToken() -> String? {
        return voipToken
    }
}
