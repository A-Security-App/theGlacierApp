import Foundation
import UIKit
final class SubscriptionAccessCoordinator: NSObject {
    static let shared = SubscriptionAccessCoordinator()
    private var hasActivatedSubscriptionFeatures = false
    private var shouldActivateSubscriptionFeatures = false
    private override init() {
        super.init()
    }
    func handleSubscriptionStatusChange(isSubscribed: Bool) {
        shouldActivateSubscriptionFeatures = isSubscribed
        if !isSubscribed {
            hasActivatedSubscriptionFeatures = false
        }
    }
    func accessTokenDidUpdate() {
        activateSubscriptionFeaturesIfNeeded()
    }
    func activateSubscriptionFeaturesIfNeeded() {
        guard shouldActivateSubscriptionFeatures else { return }
        guard hasActivatedSubscriptionFeatures == false else { return }
        guard let account = GlacierAccountModel.getGlacierAccount(), account.hasActivePhoneNumberSubscription else { return }
        //guard let idToken = TwilioBackendManager.sharedMgr().getAccessToken() else { return }
        hasActivatedSubscriptionFeatures = true
        DispatchQueue.main.async {
            switch PushController.getPushPreference() {
            case .enabled:
                PushController.registerForPushNotifications()
            case .undefined:
                PushController.setPushPreference(.enabled)
                PushController.registerForPushNotifications()
            case .disabled:
                break
            @unknown default:
                break
            }
        }
        TwilioBackendManager.sharedMgr().queryForNumbers()
    }
}
// MARK: - PhoneSubscriptionLifecycleHandler
final class PhoneSubscriptionLifecycleHandler: NSObject {
    static let shared = PhoneSubscriptionLifecycleHandler()
    private enum ChangeType: String, Codable {
        case downgrade
        case cancellation
    }
    private struct PendingChange: Codable {
        let type: ChangeType
        let deadline: Date
        var numbersToRelease: [String]
        let allowedNumbers: Int
        var hasShownWarning: Bool
    }
    private let pendingChangeKey = "com.theglacierapp.phoneSubscription.pendingChange"
    private let lastAllowedNumbersKey = "com.theglacierapp.phoneSubscription.lastAllowedNumbers"
    private let lastExpirationDateKey = "com.theglacierapp.phoneSubscription.lastExpirationDate"
    private override init() { }
    func handleSubscriptionStatusChange(isSubscribed: Bool,
                                        allowedNumbers: Int,
                                        expirationDate: Date?,
                                        numbersInUse: [String]) {
        //let sortedNumbers = numbersInUse.sorted()
        let lastAllowedNumbers = UserDefaults.standard.integer(forKey: lastAllowedNumbersKey)
        if let expirationDate {
            UserDefaults.standard.set(expirationDate, forKey: lastExpirationDateKey)
        }
        if isSubscribed {
            if numbersInUse.count <= allowedNumbers {
                clearPendingChangeIfNeeded()
            } else if allowedNumbers > 0 {
                let releaseCandidates = Array(numbersInUse.dropFirst(allowedNumbers))
                let deadline = expirationDate ?? UserDefaults.standard.object(forKey: lastExpirationDateKey) as? Date ?? Date()
                scheduleChange(type: .downgrade,
                               deadline: deadline,
                               numbersToRelease: releaseCandidates,
                               allowedNumbers: allowedNumbers)
            }
        } else if !numbersInUse.isEmpty {
            let deadline = expirationDate ?? UserDefaults.standard.object(forKey: lastExpirationDateKey) as? Date ?? Date()
            scheduleChange(type: .cancellation,
                           deadline: deadline,
                           numbersToRelease: numbersInUse,
                           allowedNumbers: 0)
        } else {
            clearPendingChangeIfNeeded()
        }
        if allowedNumbers != lastAllowedNumbers {
            UserDefaults.standard.set(allowedNumbers, forKey: lastAllowedNumbersKey)
        }
    }
    func handleAppDidBecomeActive() {
        guard var pendingChange = currentPendingChange else { return }
        let activeNumbers = TwilioBackendManager.sharedMgr()
            .getExistingAccounts()
            .compactMap { $0.grdbRecord?.phoneNumber }
            .sorted()
        let releaseTargets: [String]
        if pendingChange.allowedNumbers > 0 {
            let extras = max(0, activeNumbers.count - pendingChange.allowedNumbers)
            releaseTargets = Array(activeNumbers.suffix(extras))
        } else {
            releaseTargets = activeNumbers
        }
        if releaseTargets.isEmpty {
            clearPendingChangeIfNeeded()
            return
        }
        pendingChange.numbersToRelease = releaseTargets
        storePendingChange(pendingChange)
        if Date() >= pendingChange.deadline {
            releaseNumbers(releaseTargets)
            presentReleased(for: pendingChange)
            clearPendingChangeIfNeeded()
            return
        }
        if pendingChange.hasShownWarning {
            return
        }
        presentWarning(for: pendingChange)
    }
    private var currentPendingChange: PendingChange? {
        guard let data = UserDefaults.standard.data(forKey: pendingChangeKey) else { return nil }
        do {
            return try JSONDecoder().decode(PendingChange.self, from: data)
        } catch {
            Log.general.error("Failed to decode PendingChange from UserDefaults: \(error)")
            return nil
        }
    }
    private func storePendingChange(_ change: PendingChange?) {
        if let change {
            do {
                let data = try JSONEncoder().encode(change)
                UserDefaults.standard.set(data, forKey: pendingChangeKey)
            } catch {
                Log.general.error("Failed to encode PendingChange for UserDefaults: \(error)")
            }
        } else {
            UserDefaults.standard.removeObject(forKey: pendingChangeKey)
        }
    }
    private func clearPendingChangeIfNeeded() {
        if currentPendingChange != nil {
            storePendingChange(nil)
        }
    }
    private func scheduleChange(type: ChangeType,
                                deadline: Date,
                                numbersToRelease: [String],
                                allowedNumbers: Int) {
        guard !numbersToRelease.isEmpty else {
            clearPendingChangeIfNeeded()
            return
        }
        let newChange = PendingChange(type: type,
                                      deadline: deadline,
                                      numbersToRelease: numbersToRelease,
                                      allowedNumbers: allowedNumbers,
                                      hasShownWarning: false)
        storePendingChange(newChange)
    }
    private func presentWarning(for change: PendingChange) {
        guard let presenter = topViewController() else { return }
        let numbers = change.numbersToRelease.joined(separator: ", ")
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let deadline = dateFormatter.string(from: change.deadline)
        let message: String
        switch change.type {
        case .downgrade:
            message = "Downgrading permanently removes additional numbers, messages, and call history. Without action, \(numbers) will be released on \(deadline). Manage numbers or re-subscribe before then."
        case .cancellation:
            message = "Canceling phone subscription permanently removes your numbers, messages, and call history. You have until \(deadline) to re-subscribe if desired."
        }
        let alert = UIAlertController(title: "Subscription changing", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        presenter.present(alert, animated: true)
        var updatedChange = change
        updatedChange.hasShownWarning = true
        storePendingChange(updatedChange)
    }
    private func presentReleased(for change: PendingChange) {
        guard let presenter = topViewController() else { return }
        let numbers = change.numbersToRelease.joined(separator: ", ")
        let message: String
        switch change.type {
        case .downgrade:
            message = "Messages and call history removed for \(numbers) due to subscription downgrade."
        case .cancellation:
            message = "Phone numbers and associated data removed due to subscription cancellation."
        }
        let alert = UIAlertController(title: "Subscription changed", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        presenter.present(alert, animated: true)
    }
    private func releaseNumbers(_ numbers: [String]) {
        for number in numbers {
            release(number)
        }
    }
    private func release(_ number: String) {
        if let account = TwilioBackendManager.sharedMgr().getExistingAccount(phoneNumber: number) {
            removeData(for: account)
        }
        TwilioBackendManager.sharedMgr().releaseNumber(number)
    }
    /// Removes all local data for a phone number (GRDB records, in-memory state, avatar entry)
    /// **without** calling the backend `/release` endpoint.  Use when the backend will handle
    /// the server-side release independently — e.g. when a lapsed subscription is detected via
    /// the backend subscription status endpoint.
    func releaseNumberLocally(_ number: String) {
        if let account = TwilioBackendManager.sharedMgr().getExistingAccount(phoneNumber: number) {
            removeData(for: account)
        }
        TwilioBackendManager.sharedMgr().removeNumberLocally(number)
    }
    private func removeData(for account: PhoneAccountModel) {
        guard let accountId = account.grdbRecord?.uniqueId else { return }
        if let phoneNumber = account.grdbRecord?.phoneNumber {
            CallRecord.removeAll(for: phoneNumber)
        }
        account.remove { }
    }
    private func topViewController(base: UIViewController? = UIApplication.shared.windows.first { $0.isKeyWindow }?.rootViewController) -> UIViewController? {
        if let nav = base as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(base: selected)
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}
