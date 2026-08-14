//
//  NotificationSettingsViewModel.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 NotificationSettingsViewModel defines requirements for NotificationSettingsScreen view models.
 */
protocol NotificationSettingsViewModel: AnyObject {
    var isRebootReminderEnabled: Bool { get set }
    var isWeeklyPrivacyReportEnabled: Bool { get set }

    var rebootReminderTitle: String { get }
    var rebootReminderDescription: String { get }
    var weeklyPrivacyReportTitle: String { get }
    var weeklyPrivacyReportDescription: String { get }

    /// Reconciles the Weekly Privacy Report toggle with the backend's value.
    func refreshFromBackend()
}

/**
 NotificationSettingsVM provides data/state and business logic for NotificationSettingsScreen.

 It hosts the two notification toggles:
 - Reboot Reminder: a locally-scheduled weekly reminder to restart the device.
 - Weekly Privacy Report: a backend-controlled weekly summary email.
 */
final class NotificationSettingsVM: NotificationSettingsViewModel, ObservableObject {

    // MARK: - Public properties

    /// Backs the Reboot Reminder toggle. Persisted locally and reflected to the
    /// scheduled notification. The initial value is set in `init` (which does not
    /// trigger `didSet`), so toggling in the UI is the only path that re-schedules.
    @Published var isRebootReminderEnabled: Bool = true {
        didSet {
            UserDefaultsService.shared.set(isRebootReminderEnabled, for: \.isRebootReminderEnabled)
            if isRebootReminderEnabled {
                GlacierApplicationDelegate.appDelegate.scheduleWeeklyRebootReminder()
            } else {
                GlacierApplicationDelegate.appDelegate.cancelWeeklyRebootReminder()
            }
        }
    }

    /// Backs the Weekly Privacy Report toggle. Persisted locally and synced to the
    /// backend. The initial value is set in `init` (which does not trigger `didSet`),
    /// so simply opening the screen never fires a network call.
    @Published var isWeeklyPrivacyReportEnabled: Bool = true {
        didSet {
            // A value applied from `refreshFromBackend()` reflects what the server
            // already has, so it must not be echoed straight back as a write.
            guard !isApplyingRemoteValue else { return }
            UserDefaultsService.shared.set(isWeeklyPrivacyReportEnabled, for: \.isWeeklyPrivacyReportEnabled)
            PrivacyReportManager.shared.setWeeklyPrivacyReport(enabled: isWeeklyPrivacyReportEnabled)
        }
    }

    /// True while a backend-fetched value is being applied, so the `didSet` above
    /// updates the UI and local store without re-triggering a PUT to the backend.
    private var isApplyingRemoteValue = false

    let rebootReminderTitle = NSLocalizedString(
        "Reboot Reminder",
        comment: "Notifications screen reboot reminder title"
    )
    let rebootReminderDescription = NSLocalizedString(
        "Get a weekly reminder to restart your device. Regular reboots clear out memory-resident threats and keep your protection running smoothly.",
        comment: "Notifications screen reboot reminder description"
    )
    let weeklyPrivacyReportTitle = NSLocalizedString(
        "Weekly Privacy Report",
        comment: "Notifications screen weekly privacy report title"
    )
    let weeklyPrivacyReportDescription = NSLocalizedString(
        "Get a weekly email recapping your protection — including how many web trackers Glacier’s private DNS blocked over the past week.",
        comment: "Notifications screen weekly privacy report description"
    )

    // MARK: - Initializer

    init() {
        self.isRebootReminderEnabled = UserDefaultsService.shared.get(for: \.isRebootReminderEnabled) ?? true
        self.isWeeklyPrivacyReportEnabled = UserDefaultsService.shared.get(for: \.isWeeklyPrivacyReportEnabled) ?? true
    }

    // MARK: - Public methods

    /// Reconciles the Weekly Privacy Report toggle with the backend's authoritative
    /// value. Call when the settings screen appears. No-ops on fetch failure so a
    /// dropped request never clobbers the last known-good local state.
    func refreshFromBackend() {
        PrivacyReportManager.shared.fetchWeeklyPrivacyReport { [weak self] remote in
            guard let self, let remote else { return }
            DispatchQueue.main.async {
                guard self.isWeeklyPrivacyReportEnabled != remote else { return }
                self.isApplyingRemoteValue = true
                self.isWeeklyPrivacyReportEnabled = remote
                self.isApplyingRemoteValue = false
                UserDefaultsService.shared.set(remote, for: \.isWeeklyPrivacyReportEnabled)
            }
        }
    }
}
