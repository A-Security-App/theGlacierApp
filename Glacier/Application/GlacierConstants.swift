//
//  GlacierConstants.swift
//  Glacier
//

import Foundation

// MARK: - Keychain / Service Names

let kServiceName                    = "com.theglacierapp.Glacier"
let kCertificateServiceName         = "com.theglacierapp.Certificate"
let kGlacierServiceName             = "com.theglacierapp.Chat"
let kGlacierGroup                   = "group.com.theglacierapp.GlacierApp"
let kGlacierAcct                    = "com.theglacierapp.Acct"
let kGlacierKeyGroup                = "UG8VC96NZF.group.com.theglacierapp.gappaccess"
let kCognitoAcct                    = "com.theglacierapp.Cognito"
let kGlacierVpn                     = "com.theglacierapp.Vpn"
/// Keychain account for the transient sign-up password held only between account
/// creation and the post-confirmation auto sign-in. Never stored in UserDefaults.
let kGlacierPendingSignupAcct       = "com.theglacierapp.PendingSignup"

// MARK: - Encryption Keys

let kGlacierSalt                    = "com.theglacierapp.Salt"
let kGlacierKeySpec                 = "com.theglacierapp.KeySpec"
let kGlacierMediaSalt               = "com.theglacierapp.MediaSalt"
let kGlacierMediaKeySpec            = "com.theglacierapp.MediaKeySpec"
let kGlacierBackup                  = "com.theglacierapp.Backup"

// MARK: - Misc Keys

let kGlacierImage                   = "kGlacierImage"
let kSettingsValueUpdatedNotification = "kSettingsValueUpdatedNotification"
let kGlacierCoreConnection          = "kGlacierCoreConnection"
let kThreatDetectionKey             = "kThreatDetectionKey"
let kLinkPreviewKey                 = "kLinkPreviewKey"
let kRebootReminderKey              = "kRebootReminderKey"
let kBgTaskId                       = "com.theglacierapp.Glacier.task.refresh"
let kBgRebootTaskId                 = "com.theglacierapp.Glacier.task.reboot"
let kRebootReminderNotificationId   = "glacier.weeklyRebootReminder"
let kAppVersionKey                  = "kAppVersionKey"
let kOTRErrorDomain                 = "com.theglacierapp"

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
let kWidgetDarwinNotification       = "com.theglacierapp.widgetToggle"
/// Explicit action the widget requested: "disconnect" or "connect". Read and cleared by the main app.
let kWidgetRequestedActionKey       = "glacier.widgetRequestedAction"
/// Today's blocked-tracker count from DNS analytics; written on each successful queryForDNSAnalytics response.
let kWidgetBlockedTrackersCountKey  = "glacier.blockedTrackersCount"
