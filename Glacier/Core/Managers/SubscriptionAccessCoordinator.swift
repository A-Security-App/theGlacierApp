import Foundation
import UIKit
import WidgetKit
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

/**
 PhoneSubscriptionLifecycleHandler reacts to a *partial* phone-number downgrade — the subscription
 tier drops below the number of phone numbers the user currently holds, while they still have at
 least a 1-line subscription. (Full cancellation, where no source grants any subscription, is
 handled separately by the local-cleanup path in GlacierApplicationDelegate+BackendSubscription.)

 Design goals:
 - **Never act on a network blip.** A downgrade is only ever tracked when the reconciled tier drop
   is confirmed by a live backend response *and* a definitive (non-timeout) StoreKit read. If a
   later confirmed reading shows the tier recovered (or the user got back within their limit), the
   pending change is cleared. Numbers are only removed after the drop has persisted.
 - **Let the user choose.** While a downgrade is pending we present RemovePhoneNumbersView so the
   user picks which number(s) to remove. The prompt is dismissable ("Decide later").
 - **A deadline the user is told about.** The user has until the end of the day
   `decisionWindowDays` after detection. Every prompt shows that date and names the number(s) we
   will remove if they don't choose, so the eventual auto-removal is never a surprise.
 - **Fair fallback.** Once the deadline passes (and the user has seen the prompt at least once) we
   remove the number(s) we named: the most recently added (by insertion order), or a stable
   order-independent pick when insertion order can't be determined (e.g. after a reinstall).
 */
final class PhoneSubscriptionLifecycleHandler: NSObject {
    static let shared = PhoneSubscriptionLifecycleHandler()

    /// Persisted tracking state for an in-progress downgrade. The actual numbers to release are
    /// always recomputed from the live account list at action time (never persisted), so this
    /// survives refreshes and reinstalls without pointing at stale numbers.
    private struct PendingChange: Codable {
        /// The plan's current allowed number of lines (always > 0 for a downgrade).
        let allowedNumbers: Int
        /// How many distinct app activations we have shown the selection prompt on.
        var promptsShown: Int
        /// When the downgrade was first confirmed — anchors the decision deadline. Moved forward when
        /// the number(s) we named change, so a new pick always gets a full window of its own.
        var firstDetectedAt: Date
        /// The number(s) we told the user we'd remove if they don't choose. Persisted so the
        /// number named in the prompt is the one actually removed; re-picked if it goes stale.
        var autoRemovalNumbers: [String]?
    }

    /// An auto-removal notice that couldn't be shown because another popup was on screen.
    private struct UnshownRemovalNotice: Codable {
        let numbers: [String]
        let deadline: Date
        let allowedNumbers: Int
    }

    // Bumped to `.v3` when the deadline replaced the prompt-count rule: a change pending under the
    // old rule was never shown a deadline, so it starts a fresh window rather than resolving at once.
    private let pendingChangeKey = "com.theglacierapp.phoneSubscription.pendingChange.v3"
    private let legacyPendingChangeKey = "com.theglacierapp.phoneSubscription.pendingChange.v2"
    private let unshownNoticeKey = "com.theglacierapp.phoneSubscription.unshownRemovalNotice"

    /// The user has until the end of this many days after detection to choose. Auto-removal only
    /// happens once that day is over and the user has seen the prompt at least once.
    private let decisionWindowDays = 7

    /// Don't show the chooser again within this long of the last showing. Detection runs on both
    /// activation and the subscription refresh that follows it, and activation also fires for Face ID,
    /// Control Center and system sheets — without this, "Decide later" could be followed straight
    /// away by the same prompt.
    private let repromptInterval: TimeInterval = 60 * 60
    private var lastPromptedAt: Date?

    private override init() {
        super.init()
        UserDefaults.standard.removeObject(forKey: legacyPendingChangeKey)
    }

    // MARK: - Detection (called from backend reconciliation)

    /// Evaluates whether a partial downgrade should be tracked. Called after the backend/StoreKit
    /// reconciliation on launch and every foreground. May run off the main thread.
    ///
    /// - Parameters:
    ///   - allowedNumbers: The reconciled (max of Apple/backend) number of lines the plan allows.
    ///   - isConfirmedReading: `true` only when this reconciliation was backed by a live backend
    ///     response, a definitive StoreKit read, and not a just-completed purchase. When `false`
    ///     we do nothing — we can't distinguish a genuine downgrade from a transient outage.
    func evaluatePhoneSubscriptionDowngrade(allowedNumbers: Int, isConfirmedReading: Bool) {
        // Only a confirmed reading may schedule OR clear a pending change. An unconfirmed reading
        // (network blip / StoreKit timeout) is ignored entirely so it can neither create a false
        // downgrade nor cancel a legitimate pending one.
        guard isConfirmedReading else { return }

        // allowedNumbers == 0 means no phone subscription at all — that's a full cancellation,
        // handled by the local-cleanup path in applyBackendSubscription, not here.
        guard allowedNumbers > 0 else { return }

        let heldCount = heldPhoneAccounts().count
        guard heldCount > allowedNumbers else {
            // Within the limit now (e.g. user re-upgraded or removed a number manually) — stand down.
            clearPendingChangeIfNeeded()
            return
        }

        scheduleOrUpdateDowngrade(allowedNumbers: allowedNumbers)

        // Surface the prompt on this foreground too, in case detection completed after
        // applicationDidBecomeActive already ran (refreshBackendSubscription is async).
        Task { @MainActor [weak self] in
            self?.presentDowngradeUIIfNeeded()
        }
    }

    /// Called from applicationDidBecomeActive. Presents the selection UI, or auto-resolves once the
    /// decision deadline has passed.
    @MainActor
    func handleAppDidBecomeActive() {
        presentUnshownRemovalNoticeIfNeeded()
        presentDowngradeUIIfNeeded()
    }

    // MARK: - Presentation / resolution

    @MainActor
    private func presentDowngradeUIIfNeeded() {
        guard var pending = currentPendingChange else { return }

        let accounts = heldPhoneAccounts()
        guard accounts.count > pending.allowedNumbers else {
            // No longer over the limit — nothing to do.
            clearPendingChangeIfNeeded()
            return
        }

        // Don't stack over any popup already on screen (including our own from a prior activation).
        guard !OverlayViewManager.shared.isPresentingPopupView() else { return }

        let removalCount = accounts.count - pending.allowedNumbers
        let autoRemovalNumbers = resolvedAutoRemovalNumbers(for: &pending, accounts: accounts, count: removalCount)
        let deadline = decisionDeadline(for: pending)

        if pending.promptsShown >= 1 && Date() >= enforcementDate(for: pending) {
            autoResolveDowngrade(numbers: autoRemovalNumbers, deadline: deadline, allowedNumbers: pending.allowedNumbers)
            return
        }

        if let lastPromptedAt, Date().timeIntervalSince(lastPromptedAt) < repromptInterval { return }
        lastPromptedAt = Date()

        // Count this activation as a shown prompt and present the selection UI.
        pending.promptsShown += 1
        storePendingChange(pending)

        let view = RemovePhoneNumbersView(
            accounts: accounts,
            removalCount: removalCount,
            allowedNumbers: pending.allowedNumbers,
            deadline: deadline,
            autoRemovalNumbers: autoRemovalNumbers,
            onRemove: { [weak self] numbers in
                OverlayViewManager.shared.dismissPopupView()
                self?.performRelease(numbers)
            },
            onDefer: { [weak self] in
                OverlayViewManager.shared.dismissPopupView()
                self?.presentDeferredNotice(deadline: deadline, autoRemovalNumbers: autoRemovalNumbers)
            }
        )
        OverlayViewManager.shared.presentPopupView(view)
    }

    /// The last day the user can choose, shown in every prompt.
    private func decisionDeadline(for pending: PendingChange) -> Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: pending.firstDetectedAt)
        return calendar.date(byAdding: .day, value: decisionWindowDays, to: day) ?? day
    }

    /// Auto-removal starts once the deadline day is over, so "choose by Oct 12" includes all of Oct 12.
    private func enforcementDate(for pending: PendingChange) -> Date {
        let deadline = decisionDeadline(for: pending)
        return Calendar.current.date(byAdding: .day, value: 1, to: deadline) ?? deadline
    }

    /// Returns the persisted auto-removal pick when it still names exactly `count` numbers the user
    /// holds; otherwise picks again and persists the new pick.
    ///
    /// The pick goes stale when the user removes a number themselves but is still over the limit
    /// (e.g. a 5-line → 1-line downgrade where they remove one of the four extras). The user was
    /// shown a different number than we'd now remove, so the deadline restarts and the new pick has
    /// to be shown before anything is removed.
    private func resolvedAutoRemovalNumbers(for pending: inout PendingChange,
                                            accounts: [PhoneAccountModel],
                                            count: Int) -> [String] {
        let held = Set(accounts.compactMap { $0.grdbRecord?.phoneNumber })
        if let stored = pending.autoRemovalNumbers, stored.count == count, Set(stored).isSubset(of: held) {
            return stored
        }
        let numbers = automaticRemovalTargets(from: accounts, count: count).compactMap { $0.grdbRecord?.phoneNumber }
        if pending.autoRemovalNumbers != nil {
            Log.general.notice("[PhoneDowngrade] Auto-removal pick changed — restarting the decision window")
            pending.firstDetectedAt = Date()
            pending.promptsShown = 0
        }
        pending.autoRemovalNumbers = numbers
        storePendingChange(pending)
        return numbers
    }

    @MainActor
    private func autoResolveDowngrade(numbers: [String], deadline: Date, allowedNumbers: Int) {
        guard !numbers.isEmpty else {
            clearPendingChangeIfNeeded()
            return
        }
        Log.general.notice("[PhoneDowngrade] Decision deadline passed — auto-removing \(numbers.count) number(s)")
        performRelease(numbers)
        presentReleasedNotice(UnshownRemovalNotice(numbers: numbers, deadline: deadline, allowedNumbers: allowedNumbers))
    }

    /// Selects which number(s) to auto-remove if the user never chooses. Prefers the most recently
    /// added numbers (highest GRDB rowid == inserted last on this install). When insertion order is
    /// unreliable — e.g. after a reinstall, where every number was re-inserted in one pass — falls
    /// back to an order that doesn't depend on insertion (the number itself), so the pick is stable
    /// between the prompt that names it and the removal.
    private func automaticRemovalTargets(from accounts: [PhoneAccountModel], count: Int) -> [PhoneAccountModel] {
        let ids = accounts.compactMap { $0.grdbRecord?.id }
        let hasReliableRecency = ids.count == accounts.count && Set(ids).count == accounts.count

        let ordered: [PhoneAccountModel]
        if hasReliableRecency {
            // Most recently added first.
            ordered = accounts.sorted { ($0.grdbRecord?.id ?? 0) > ($1.grdbRecord?.id ?? 0) }
        } else {
            ordered = accounts.sorted { ($0.grdbRecord?.phoneNumber ?? "") > ($1.grdbRecord?.phoneNumber ?? "") }
            Log.general.notice("[PhoneDowngrade] Insertion order unavailable — picking auto-removal by number")
        }
        return Array(ordered.prefix(count))
    }

    @MainActor
    private func performRelease(_ numbers: [String]) {
        guard !numbers.isEmpty else {
            clearPendingChangeIfNeeded()
            return
        }
        clearPendingChangeIfNeeded()

        let group = DispatchGroup()
        for number in numbers {
            // Delete local call history; releaseNumber handles the backend release plus the local
            // GRDB record removal, in-memory selectedAccount update, and avatar cleanup.
            CallRecord.removeAll(for: number)
            group.enter()
            TwilioBackendManager.sharedMgr().releaseNumber(number) { _ in
                group.leave()
            }
        }

        // Notify observers only after the release round-trip (and the local GRDB removal it
        // performs) has completed. Posting immediately raced the async delete: MainViewModel would
        // re-query a list that still contained the removed number and leave it selected in the
        // header even though the list below it had refreshed.
        group.notify(queue: .main) {
            NotificationCenter.default.post(name: .userPhoneNumberDetailsUpdated, object: nil)
        }
    }

    /// Confirms what "Decide later" means: both numbers stay until the deadline, then the named
    /// number(s) go.
    @MainActor
    private func presentDeferredNotice(deadline: Date, autoRemovalNumbers: [String]) {
        guard !OverlayViewManager.shared.isPresentingPopupView() else { return }
        let date = Self.deadlineString(deadline)
        let numbers = autoRemovalNumbers.joined(separator: ", ")
        let description = String(format: NSLocalizedString(
            "Until then you'll keep all your numbers. After that, we'll remove %@.",
            comment: "Downgrade defer notice description — %@ is the number(s) to be removed"), numbers)
        let configuration = PopupConfiguration(
            title: String(format: NSLocalizedString("Decide by %@", comment: "Downgrade defer notice title"), date),
            description: description,
            buttons: [
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("OK", comment: "OK button title"),
                    onTap: { OverlayViewManager.shared.dismissPopupView() }
                )
            ],
            buttonsAlignment: .vertical
        )
        OverlayViewManager.shared.presentPopupView(GlacierPopup(configuration: configuration))
    }

    /// Tells the user which number(s) were removed. If another popup is on screen, the notice is
    /// saved and shown on the next activation instead of being dropped.
    @MainActor
    private func presentReleasedNotice(_ notice: UnshownRemovalNotice) {
        guard !notice.numbers.isEmpty else { return }
        guard !OverlayViewManager.shared.isPresentingPopupView() else {
            storeUnshownNotice(notice)
            return
        }
        storeUnshownNotice(nil)

        let joined = notice.numbers.joined(separator: ", ")
        let date = Self.deadlineString(notice.deadline)
        let isSingle = notice.numbers.count == 1
        let title = isSingle
            ? String(format: NSLocalizedString("%@ was removed", comment: "Downgrade auto-removal notice title — one number"), joined)
            : NSLocalizedString("Numbers removed", comment: "Downgrade auto-removal notice title")
        let planDescription = Self.planDescription(allowedNumbers: notice.allowedNumbers)
        let description = isSingle
            ? String(format: NSLocalizedString(
                "%@, and no number was chosen by %@, so we removed this one along with its messages, call history and voicemails.",
                comment: "Downgrade auto-removal notice description — one number. First %@ is e.g. 'Your plan includes 1 line', second is a date"),
                     planDescription, date)
            : String(format: NSLocalizedString(
                "%@, and no numbers were chosen by %@, so we removed %@ along with their messages, call history and voicemails.",
                comment: "Downgrade auto-removal notice description — several numbers. First %@ is e.g. 'Your plan includes 2 lines', second is a date, third the numbers"),
                     planDescription, date, joined)
        let configuration = PopupConfiguration(
            title: title,
            description: description,
            buttons: [
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("OK", comment: "OK button title"),
                    onTap: { OverlayViewManager.shared.dismissPopupView() }
                )
            ],
            buttonsAlignment: .vertical
        )
        OverlayViewManager.shared.presentPopupView(GlacierPopup(configuration: configuration))
    }

    @MainActor
    private func presentUnshownRemovalNoticeIfNeeded() {
        guard let notice = unshownNotice, !OverlayViewManager.shared.isPresentingPopupView() else { return }
        presentReleasedNotice(notice)
    }

    // MARK: - Formatting

    /// "Oct 12" — the deadline shown in every downgrade prompt.
    static func deadlineString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    /// "Your plan includes 1 line" / "Your plan includes 2 lines".
    private static func planDescription(allowedNumbers: Int) -> String {
        allowedNumbers == 1
            ? NSLocalizedString("Your plan includes 1 line", comment: "Downgrade notice — plan size, singular")
            : String(format: NSLocalizedString("Your plan includes %d lines", comment: "Downgrade notice — plan size, plural"), allowedNumbers)
    }

    // MARK: - Persistence

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

    private var unshownNotice: UnshownRemovalNotice? {
        guard let data = UserDefaults.standard.data(forKey: unshownNoticeKey) else { return nil }
        return try? JSONDecoder().decode(UnshownRemovalNotice.self, from: data)
    }

    private func storeUnshownNotice(_ notice: UnshownRemovalNotice?) {
        if let notice, let data = try? JSONEncoder().encode(notice) {
            UserDefaults.standard.set(data, forKey: unshownNoticeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: unshownNoticeKey)
        }
    }

    private func clearPendingChangeIfNeeded() {
        if currentPendingChange != nil {
            storePendingChange(nil)
        }
    }

    private func scheduleOrUpdateDowngrade(allowedNumbers: Int) {
        if let existing = currentPendingChange, existing.allowedNumbers == allowedNumbers {
            // Already tracking this exact downgrade — keep the existing window (promptsShown, firstDetectedAt).
            return
        }
        // No pending change, or the tier moved again — start a fresh tracking window.
        let change = PendingChange(allowedNumbers: allowedNumbers,
                                   promptsShown: 0,
                                   firstDetectedAt: Date())
        storePendingChange(change)
    }

    // MARK: - Number release

    /// One account per distinct phone number. Duplicate local rows for the same number are a
    /// local-database artifact, not extra lines: counting them made a single-line user look over
    /// their limit, and releasing a "duplicate" would release their only number on the backend.
    /// When a number has several rows, the oldest (lowest id) represents it.
    private func heldPhoneAccounts() -> [PhoneAccountModel] {
        var seen = Set<String>()
        return PhoneAccountModel.allAccounts()
            .sorted { ($0.grdbRecord?.id ?? .max) < ($1.grdbRecord?.id ?? .max) }
            .filter { account in
                guard let number = account.grdbRecord?.phoneNumber else { return false }
                return seen.insert(number).inserted
            }
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
        guard account.grdbRecord?.uniqueId != nil else { return }
        if let phoneNumber = account.grdbRecord?.phoneNumber {
            CallRecord.removeAll(for: phoneNumber)
        }
        account.remove { }
    }
}

// MARK: - BaseSubscriptionLifecycleHandler

/**
 BaseSubscriptionLifecycleHandler governs expiration of the *base* Glacier subscription
 (yearly / monthly) — the plan that gates the VPN and encrypted-DNS (DoT) security features.

 It implements "Model A + short grace":
 - On a **confirmed** base-plan expiration (a live backend response AND a definitive, non-timeout
   StoreKit read — never a network blip) we do NOT immediately cut protection. We open a short
   grace window during which the VPN and DoT keep running and the user is softly nagged to renew.
   Re-subscribing at any point clears the grace and everything continues seamlessly.
 - When the grace window elapses without a renewal we **enforce**: disable the DoT profile (via the
   intent-aware `apply(isEnabled:false)` so the DoT resilience heal can't silently turn it back on),
   stop the VPN (`turnOffCore()`), and clear the widget's VPN status. The lapse path then presents
   the non-dismissible paywall.
 - Enforcement **records what it turned off** (`dotDisabledByEnforcementKey`,
   `vpnDisabledByEnforcementKey`) and restore puts back exactly that much. Protection the user had
   already chosen to leave off is never flagged, so restore can never switch it on for them. The VPN
   half of this was previously missing: a lapse stopped the VPN and nothing ever re-armed it, so a
   blip left the VPN off permanently while DNS kept running and the Wi-Fi auto-activation settings
   still read as enabled.

 Deliberate scope boundaries (see PR notes):
 - VPN **tunnel removal** is intentionally not done here. A lapse only needs `turnOffCore()`, which
   is reversible with no re-permission prompt; `removeAllTunnels()` would force the system "add VPN
   configurations" prompt on the next renew — and would also destroy the on-demand rules that carry
   the user's trusted networks.
 - Local phone-number cleanup on a full base-plan expiry is unchanged (handled in
   `applyBackendSubscription`). This handler governs the VPN/DoT protection lifecycle only.
 - A base-plan expiry only ever observed at cold launch (the app was never foregrounded while
   subscribed since the expiry) has no in-session transition to anchor a grace window, so it
   enforces immediately. The paywall is still fully recoverable via renew/restore.
 */
final class BaseSubscriptionLifecycleHandler: NSObject {
    static let shared = BaseSubscriptionLifecycleHandler()

    enum Decision {
        /// Protection preserved; a grace window is active (or was just started).
        case grace
        /// Grace elapsed (or none owed): protection torn down; caller should present the paywall.
        case enforce
        /// Reading was not confirmed (network blip / StoreKit timeout) — take no destructive action.
        case inconclusive
    }

    /// Persisted grace-window state. `firstDetectedAt` anchors the window; the teardown is always
    /// recomputed from the clock at decision time, never scheduled, so it survives relaunches.
    private struct PendingExpiration: Codable {
        let firstDetectedAt: Date
    }

    private let pendingKey = "com.theglacierapp.baseSubscription.pendingExpiration.v1"
    /// Set when enforcement disabled a DoT profile that had been enabled, so restore only re-enables
    /// what we turned off — never switches DoT on for a user who never had it.
    private let dotDisabledByEnforcementKey = "com.theglacierapp.baseSubscription.dotDisabledByEnforcement"
    /// Set when enforcement stopped a VPN that was running, so restore only re-arms what we turned
    /// off — never switches the VPN on for a user who had deliberately left it off.
    private let vpnDisabledByEnforcementKey = "com.theglacierapp.baseSubscription.vpnDisabledByEnforcement"

    /// How long protection is preserved after a confirmed expiry before enforcement. Tunable.
    private let graceInterval: TimeInterval = 72 * 60 * 60   // 72 hours

    /// Whether the grace nag popup we presented is currently on screen. Lets us retract it the
    /// moment the subscription renews (the persisted-window clear alone can't dismiss a popup that
    /// applicationDidBecomeActive re-presented in the beat before the renewal was observed).
    private var isPresentingGraceNag = false

    /// True while a renew/lapse paywall is on screen. Suppresses the grace nag so it can't pop up
    /// over the paywall — e.g. when applicationDidBecomeActive fires as the StoreKit purchase sheet
    /// dismisses mid-renewal, while the user is still on the paywall. Set by the root screen.
    private var isPaywallPresented = false

    private override init() { super.init() }

    var hasActiveGracePeriod: Bool {
        guard let pending = currentPending else { return false }
        return Date().timeIntervalSince(pending.firstDetectedAt) < graceInterval
    }

    /// When protection turns off if the plan isn't renewed, or `nil` when no grace window is open.
    var gracePeriodEndsAt: Date? {
        guard hasActiveGracePeriod, let pending = currentPending else { return nil }
        return pending.firstDetectedAt.addingTimeInterval(graceInterval)
    }

    // MARK: - Detection entry points

    /// Called from the foreground reconciliation ONLY on a confirmed `wasSubscribed -> notSubscribed`
    /// base-plan transition (the caller owns that guard). Starts or continues the grace window and
    /// returns whether protection should be preserved (`.grace`) or torn down (`.enforce`).
    func evaluateExpiration() -> Decision {
        if currentPending == nil {
            storePending(PendingExpiration(firstDetectedAt: Date()))
        }
        guard let pending = currentPending else { return .enforce }

        if Date().timeIntervalSince(pending.firstDetectedAt) >= graceInterval {
            clearPending()
            performTeardown()
            return .enforce
        }

        Task { @MainActor [weak self] in self?.presentGraceNagIfNeeded() }
        return .grace
    }

    /// Called from the launch reconciliation when the account is (currently) not subscribed. Never
    /// *starts* a grace window (cold start has no reliable in-session "was subscribed" signal); it
    /// only continues an already-open one, and otherwise enforces.
    func launchDecision(isConfirmedReading: Bool) -> Decision {
        guard isConfirmedReading else { return .inconclusive }
        guard let pending = currentPending else {
            performTeardown()
            return .enforce
        }
        if Date().timeIntervalSince(pending.firstDetectedAt) >= graceInterval {
            clearPending()
            performTeardown()
            return .enforce
        }
        return .grace
    }

    /// Called on a confirmed reading that shows the base plan active again (renewed, or Apple billing
    /// grace recovered). Clears any grace window and puts back whatever enforcement turned off.
    func handleSubscriptionActive() {
        clearPending()
        reEnableDoTIfEnforcementDisabledIt()
        reArmVPNIfEnforcementDisabledIt()
        Task { @MainActor [weak self] in self?.dismissGraceNagIfPresenting() }
    }

    /// Called when the user restores the subscription via the paywall (`.glacierPlanPurchaseSuccessful`).
    func handleSubscriptionRestored() {
        clearPending()
        reEnableDoTIfEnforcementDisabledIt()
        reArmVPNIfEnforcementDisabledIt()
        Task { @MainActor [weak self] in self?.dismissGraceNagIfPresenting() }
    }

    /// Retracts the grace nag if we currently have it on screen. Called when the subscription
    /// renews so the user isn't left staring at an "expired" popup after paying.
    @MainActor
    private func dismissGraceNagIfPresenting() {
        guard isPresentingGraceNag else { return }
        isPresentingGraceNag = false
        OverlayViewManager.shared.dismissPopupView()
    }

    /// Called by the root screen when a renew/lapse paywall is presented or dismissed, so the grace
    /// nag isn't shown on top of the paywall the user is actively renewing through.
    func setPaywallPresented(_ presented: Bool) {
        isPaywallPresented = presented
    }

    /// Called from `applicationDidBecomeActive`. Presents the soft nag while the grace window is
    /// open. Enforcement is intentionally NOT done here — see the note in the body.
    @MainActor
    func handleAppDidBecomeActive() {
        // Only present the soft nag while the window is open. Enforcement is deliberately left to the
        // confirmed-reading paths (foreground refresh / launch): acting on the persisted window here
        // could tear down protection on the very activation where the user renewed out-of-app, before
        // the refresh has had a chance to observe the renewal.
        guard hasActiveGracePeriod else { return }
        presentGraceNagIfNeeded()
    }

    // MARK: - Presentation

    @MainActor
    private func presentGraceNagIfNeeded() {
        guard let pending = currentPending else { return }
        // Don't show the nag over the renew/lapse paywall the user is already acting on.
        guard !isPaywallPresented else { return }
        // Don't stack over any popup already on screen (including our own from a prior activation).
        guard !OverlayViewManager.shared.isPresentingPopupView() else { return }

        let remaining = graceInterval - Date().timeIntervalSince(pending.firstDetectedAt)
        let daysLeft = max(1, Int(ceil(remaining / (24 * 60 * 60))))
        // The grace window is anchored to firstDetectedAt, so this counts down on wall-clock time —
        // dismissing with "Later" does not shorten it.
        let bodyFormat = daysLeft == 1
            ? NSLocalizedString(
                "Your Glacier subscription has expired. Renew to keep your VPN and encrypted DNS protection — otherwise it will turn off in about %d day.",
                comment: "Base subscription grace nag body (singular)"
            )
            : NSLocalizedString(
                "Your Glacier subscription has expired. Renew to keep your VPN and encrypted DNS protection — otherwise it will turn off in about %d days.",
                comment: "Base subscription grace nag body (plural)"
            )
        let configuration = PopupConfiguration(
            title: NSLocalizedString("Subscription expired", comment: "Base subscription grace nag title"),
            description: String(format: bodyFormat, daysLeft),
            buttons: [
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Renew now", comment: "Renew now button title"),
                    onTap: { [weak self] in
                        self?.isPresentingGraceNag = false
                        OverlayViewManager.shared.dismissPopupView()
                        NotificationCenter.default.post(name: .glacierPresentRenewPaywall, object: nil)
                    }
                ),
                PopupButton(
                    style: .secondary,
                    title: NSLocalizedString("Later", comment: "Defer renewal button title"),
                    onTap: { [weak self] in
                        self?.isPresentingGraceNag = false
                        OverlayViewManager.shared.dismissPopupView()
                    }
                )
            ],
            buttonsAlignment: .vertical
        )
        OverlayViewManager.shared.presentPopupView(GlacierPopup(configuration: configuration))
        isPresentingGraceNag = true
    }

    // MARK: - Enforcement / restore

    /// Disables the system DoT profile (intent-aware, so the resilience heal can't re-enable it),
    /// stops the VPN, and clears the widget's VPN status. Tunnels are intentionally not removed.
    ///
    /// Both teardowns record whether *enforcement* was what turned them off, so restore puts back
    /// only what we took away. The VPN stop lives here rather than at the call sites because every
    /// path that returns `.enforce` runs this method: keeping the stop and the flag in one place is
    /// what stops them drifting apart, which is how a lapse used to leave the VPN off permanently.
    ///
    /// Safe to call more than once: each half is gated on the protection actually being on, so a
    /// second call neither re-flags nor re-tears-down.
    ///
    /// Called from every confirmed `.enforce` decision, and directly by the lapse-notification
    /// handler to cover `onGlacierPlanPurchaseVerificationFailed()`, which posts without routing
    /// through `evaluateExpiration()`.
    ///
    /// That second caller acts on a reading that may be a StoreKit timeout rather than a real
    /// lapse, and tearing down anyway is deliberate. Leaving protection up once entitlement is in
    /// doubt is the worse failure: if the backend has revoked the WireGuard peer, an armed
    /// on-demand rule keeps reviving a tunnel that blackholes traffic, and a paywalled user's only
    /// escape is deleting the profile in iOS Settings. `turnOffCore()` disables on-demand as well
    /// as deactivating, so nothing revives it. A teardown that turns out to be spurious costs the
    /// user protection only until the next confirmed reading, which re-arms it from the flags below.
    func performTeardown() {
        DispatchQueue.main.async {
            let saved = DnsOverTlsController.shared.loadSavedConfiguration()
            if saved.isEnabled {
                UserDefaults.standard.set(true, forKey: self.dotDisabledByEnforcementKey)
                let disabled = DnsOverTlsConfiguration(urlString: saved.urlString, isEnabled: false)
                DnsOverTlsController.shared.apply(configuration: disabled) { result in
                    if case .failure(let error) = result {
                        Log.general.error("[BaseSubExpiry] DoT disable on enforcement failed: \(error)")
                    }
                }
            }
            // Only flag (and stop) a VPN that is actually running. `tunnelInOperation()` is the
            // app's own definition of "the VPN is on" — the same one behind the settings toggle —
            // so a VPN the user had already switched off is never flagged and never comes back.
            if WireGuardManager.shared().tunnelsManager?.tunnelInOperation() != nil {
                UserDefaults.standard.set(true, forKey: self.vpnDisabledByEnforcementKey)
                WireGuardManager.shared().turnOffCore()
            }
            self.clearWidgetVPNStatus()
        }
    }

    private func reEnableDoTIfEnforcementDisabledIt() {
        guard UserDefaults.standard.bool(forKey: dotDisabledByEnforcementKey) else { return }
        let saved = DnsOverTlsController.shared.loadSavedConfiguration()
        // A DoT profile that enforcement disabled always had a URL on file, so re-enable directly.
        guard let url = saved.urlString, !url.isEmpty else {
            // Nothing to re-enable — clear the flag so we don't keep trying.
            UserDefaults.standard.removeObject(forKey: dotDisabledByEnforcementKey)
            return
        }
        DispatchQueue.main.async {
            let enabled = DnsOverTlsConfiguration(urlString: url, isEnabled: true)
            DnsOverTlsController.shared.apply(configuration: enabled) { result in
                switch result {
                case .success:
                    // Only clear the flag once the re-enable actually lands, so a restore-while-offline
                    // is retried on the next confirmed-active reading (handleSubscriptionActive).
                    UserDefaults.standard.removeObject(forKey: self.dotDisabledByEnforcementKey)
                case .failure(let error):
                    Log.general.error("[BaseSubExpiry] DoT re-enable on restore failed (will retry): \(error)")
                }
            }
        }
    }

    /// Re-arms the VPN that enforcement stopped, mirroring `reEnableDoTIfEnforcementDisabledIt()`.
    ///
    /// Looks the tunnel up by name rather than through `tunnelInOperation()`. Enforcement left the
    /// tunnel inactive with on-demand disabled, which is precisely the state `tunnelInOperation()`
    /// reports as nil — keying on it here would silently restore nothing.
    private func reArmVPNIfEnforcementDisabledIt() {
        guard UserDefaults.standard.bool(forKey: vpnDisabledByEnforcementKey) else { return }

        DispatchQueue.main.async {
            // Not ready yet (the WireGuard client initialises lazily). Keep the flag so the next
            // confirmed-active reading retries, rather than dropping the user's VPN on the floor.
            guard let tunnelsManager = WireGuardManager.shared().tunnelsManager else { return }

            let installedRegion = UserDefaults.standard.string(forKey: "glacier_vpn_installed_region") ?? "us-east-2"
            guard let tunnel = tunnelsManager.tunnel(named: installedRegion) else {
                // The tunnel is genuinely gone (sign-out removed it) — there is nothing to restore.
                UserDefaults.standard.removeObject(forKey: self.vpnDisabledByEnforcementKey)
                return
            }

            // `turnOffCore()` only flips `isOnDemandEnabled`; the on-demand rules — and with them
            // the user's trusted networks and Wi-Fi/cellular choices — survive untouched. So there
            // is nothing to reconstruct here, and nothing is invented when there are no rules.
            let onDemandOption = ActivateOnDemandViewModel(tunnel: tunnel).toOnDemandOption()

            let activate = {
                // startActivation rejects a tunnel that isn't inactive; on-demand may already have
                // brought it up between the flag being set and this running.
                guard tunnel.status == .inactive else { return }
                tunnelsManager.startActivation(of: tunnel)
            }

            if case .off = onDemandOption {
                UserDefaults.standard.removeObject(forKey: self.vpnDisabledByEnforcementKey)
                activate()
                return
            }

            tunnelsManager.setOnDemandEnabled(true, on: tunnel) { error in
                if let error = error {
                    // Leave the flag set so the next confirmed-active reading retries, matching
                    // how the DoT re-enable survives a restore that happens while offline.
                    Log.general.error("[BaseSubExpiry] VPN re-arm on restore failed (will retry): \(String(describing: error))")
                    return
                }
                UserDefaults.standard.removeObject(forKey: self.vpnDisabledByEnforcementKey)
                activate()
            }
        }
    }

    /// Drops any record that enforcement turned protection off. Called on sign-out and account
    /// deletion, where the tunnel and DoT profile are removed outright — a flag left behind could
    /// otherwise re-arm protection for whoever signs in next on this device.
    func clearEnforcementRestoreState() {
        UserDefaults.standard.removeObject(forKey: vpnDisabledByEnforcementKey)
        UserDefaults.standard.removeObject(forKey: dotDisabledByEnforcementKey)
    }

    private func clearWidgetVPNStatus() {
        UserDefaults(suiteName: kGlacierGroup)?.removeObject(forKey: kActiveConnectionTypeKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Persistence

    private var currentPending: PendingExpiration? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return nil }
        do {
            return try JSONDecoder().decode(PendingExpiration.self, from: data)
        } catch {
            Log.general.error("Failed to decode base-subscription PendingExpiration: \(error)")
            return nil
        }
    }

    private func storePending(_ change: PendingExpiration) {
        do {
            let data = try JSONEncoder().encode(change)
            UserDefaults.standard.set(data, forKey: pendingKey)
        } catch {
            Log.general.error("Failed to encode base-subscription PendingExpiration: \(error)")
        }
    }

    private func clearPending() {
        if UserDefaults.standard.data(forKey: pendingKey) != nil {
            UserDefaults.standard.removeObject(forKey: pendingKey)
        }
    }
}
