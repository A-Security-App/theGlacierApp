//
//  GlacierConstants.swift
//  Glacier
//

import Foundation

// MARK: - Keychain / Service Names

let kServiceName                    = "com.glaciersec.Glacier"
let kCertificateServiceName         = "com.glaciersec.Certificate"
let kGlacierServiceName             = "com.glaciersec.Chat"
let kGlacierGroup                   = "group.com.glaciersec.GlacierApp"
let kGlacierAcct                    = "com.glaciersec.Acct"
let kGlacierKeyGroup                = "5MXM7J8H38.group.com.glaciersec.gappaccess"
let kCognitoAcct                    = "com.glaciersec.Cognito"
let kGlacierVpn                     = "com.glaciersec.Vpn"

// MARK: - Encryption Keys

let kGlacierSalt                    = "com.glaciersec.Salt"
let kGlacierKeySpec                 = "com.glaciersec.KeySpec"
let kGlacierMediaSalt               = "com.glaciersec.MediaSalt"
let kGlacierMediaKeySpec            = "com.glaciersec.MediaKeySpec"
let kGlacierBackup                  = "com.glaciersec.Backup"

// MARK: - Misc Keys

let kGlacierImage                   = "kGlacierImage"
let kSettingsValueUpdatedNotification = "kSettingsValueUpdatedNotification"
let kGlacierCoreConnection          = "kGlacierCoreConnection"
let kThreatDetectionKey             = "kThreatDetectionKey"
let kLinkPreviewKey                 = "kLinkPreviewKey"
let kRebootReminderKey              = "kRebootReminderKey"
let kBgTaskId                       = "com.glacier.Glacier.task.refresh"
let kBgRebootTaskId                 = "com.glacier.Glacier.task.reboot"
let kAppVersionKey                  = "kAppVersionKey"
let kOTRErrorDomain                 = "com.glaciersecurity"

// MARK: - Database

let GlacierMediaDatabaseName        = "Glacier-media.sqlite"
let GlacierGRDBPassphraseAccountName = "GlacierGRDBPassphraseAccountName"
let GlacierMediaPassphraseName      = "GlacierMediaPassphraseName"

// MARK: - Notifications

let kNotificationThreadKey          = "kNotificationThreadKey"
let kNotificationThreadCollection   = "kNotificationThreadCollection"
let kNotificationType               = "kNotificationType"
let kNotificationTypeConnectionError = "kNotificationTypeConnectionError"
let kNotificationTwilioType         = "twi_message_type"
let kNotificationTwilioVoiceCall    = "twilio.voice.call"
let kNotificationTwilioCallIdKey    = "twi_call_sid"
let kNotificationTwilioCallerKey    = "twi_from"
let kNotificationVoicemailType      = "voicemail_type"
let UserNotificationsChanged        = "UserNotificationsChanged"

// MARK: - UserDefaults

let kPushEnabledKey                 = "kPushEnabledKey"
let kLastConnectionTypeKey          = "glacier.lastConnectionType"

// MARK: - Widget shared UserDefaults keys (App Group, read by GlacierWidget extension)

/// Current active connection: "dns", "vpn", or absent when disconnected.
let kActiveConnectionTypeKey        = "glacier.activeConnectionType"
/// Latest security issue string for the widget status row; empty string means all clear.
let kWidgetSecurityIssueKey         = "glacier.securityIssueText"
/// Set to true by the widget AppIntent to request a toggle; cleared by the main app after acting.
let kWidgetPendingToggleKey         = "glacier.widgetPendingToggle"
/// Darwin notification name used by the widget to wake the main app process.
let kWidgetDarwinNotification       = "com.glaciersec.widgetToggle"
/// Explicit action the widget requested: "disconnect" or "connect". Read and cleared by the main app.
let kWidgetRequestedActionKey       = "glacier.widgetRequestedAction"
/// Today's blocked-tracker count from DNS analytics; written on each successful queryForDNSAnalytics response.
let kWidgetBlockedTrackersCountKey  = "glacier.blockedTrackersCount"
