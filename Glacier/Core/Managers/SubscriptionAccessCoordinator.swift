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
 - **Fair fallback.** If the user is given several chances and never chooses, we auto-remove the
   most-recently-added number(s) (by insertion order), falling back to a random pick when insertion
   order can't be determined (e.g. after a reinstall).
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
        /// When the downgrade was first confirmed — anchors the grace-period backstop.
        let firstDetectedAt: Date
    }

    // Bumped to `.v2` — the previous (never-wired) scaffold stored a different shape under the old key.
    private let pendingChangeKey = "com.theglacierapp.phoneSubscription.pendingChange.v2"

    /// The user must see the prompt on this many activations before we auto-resolve.
    private let requiredPrompts = 3
    /// Never auto-resolve within this window of first detection, even after `requiredPrompts`.
    private let minGraceInterval: TimeInterval = 24 * 60 * 60          // 1 day
    /// Hard backstop: auto-resolve after this long (once at least one prompt has been shown),
    /// so a user who opens the app rarely doesn't stay over-limit indefinitely.
    private let maxGraceInterval: TimeInterval = 14 * 24 * 60 * 60     // 2 weeks

    private override init() { }

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
    /// user has been given enough chances.
    @MainActor
    func handleAppDidBecomeActive() {
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

        if shouldAutoResolve(pending) {
            autoResolveDowngrade(pending, accounts: accounts)
            return
        }

        // Count this activation as a shown prompt and present the selection UI.
        pending.promptsShown += 1
        storePendingChange(pending)

        let removalCount = accounts.count - pending.allowedNumbers
        let view = RemovePhoneNumbersView(
            accounts: accounts,
            removalCount: removalCount,
            onRemove: { [weak self] numbers in
                OverlayViewManager.shared.dismissPopupView()
                self?.performRelease(numbers)
            },
            onDefer: {
                OverlayViewManager.shared.dismissPopupView()
            }
        )
        OverlayViewManager.shared.presentPopupView(view)
    }

    private func shouldAutoResolve(_ pending: PendingChange) -> Bool {
        let elapsed = Date().timeIntervalSince(pending.firstDetectedAt)
        if pending.promptsShown >= requiredPrompts && elapsed >= minGraceInterval { return true }
        if pending.promptsShown >= 1 && elapsed >= maxGraceInterval { return true }
        return false
    }

    @MainActor
    private func autoResolveDowngrade(_ pending: PendingChange, accounts: [PhoneAccountModel]) {
        let removalCount = accounts.count - pending.allowedNumbers
        guard removalCount > 0 else {
            clearPendingChangeIfNeeded()
            return
        }
        let victims = automaticRemovalTargets(from: accounts, count: removalCount)
        let numbers = victims.compactMap { $0.grdbRecord?.phoneNumber }
        performRelease(numbers)
        presentReleasedNotice(numbers: numbers)
    }

    /// Selects which number(s) to auto-remove when the user never chose. Prefers the most recently
    /// added numbers (highest GRDB rowid == inserted last on this install). Falls back to a random
    /// pick when insertion order is unreliable — e.g. after a reinstall, where every number was
    /// re-inserted in one pass and rowids no longer reflect true chronological add order.
    private func automaticRemovalTargets(from accounts: [PhoneAccountModel], count: Int) -> [PhoneAccountModel] {
        let ids = accounts.compactMap { $0.grdbRecord?.id }
        let hasReliableRecency = ids.count == accounts.count && Set(ids).count == accounts.count

        let ordered: [PhoneAccountModel]
        if hasReliableRecency {
            // Most recently added first.
            ordered = accounts.sorted { ($0.grdbRecord?.id ?? 0) > ($1.grdbRecord?.id ?? 0) }
            Log.general.notice("[PhoneDowngrade] Auto-removing \(count) most-recently-added number(s)")
        } else {
            ordered = accounts.shuffled()
            Log.general.notice("[PhoneDowngrade] Insertion order unavailable — auto-removing \(count) number(s) at random")
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

    @MainActor
    private func presentReleasedNotice(numbers: [String]) {
        guard !numbers.isEmpty, !OverlayViewManager.shared.isPresentingPopupView() else { return }
        let joined = numbers.joined(separator: ", ")
        let configuration = PopupConfiguration(
            title: NSLocalizedString("Numbers removed", comment: "Downgrade auto-removal notice title"),
            description: String(
                format: NSLocalizedString(
                    "%@ and its messages and call history were removed because your phone plan was downgraded.",
                    comment: "Downgrade auto-removal notice description"
                ),
                joined
            ),
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

    private func heldPhoneAccounts() -> [PhoneAccountModel] {
        PhoneAccountModel.allAccounts().filter { $0.grdbRecord?.phoneNumber != nil }
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
   intent-aware `apply(isEnabled:false)` so the DoT resilience heal can't silently turn it back on)
   and clear the widget's VPN status. The existing lapse path stops the VPN (`turnOffCore()`) and
   presents the non-dismissible paywall.

 Deliberate scope boundaries (see PR notes):
 - VPN **tunnel removal** is intentionally not done here. A lapse only needs `turnOffCore()`
   (already handled by the existing lapse path), which is reversible with no re-permission prompt;
   `removeAllTunnels()` would force the system "add VPN configurations" prompt on the next renew.
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
    /// grace recovered). Clears any grace window and re-enables DoT if enforcement disabled it.
    func handleSubscriptionActive() {
        clearPending()
        reEnableDoTIfEnforcementDisabledIt()
        Task { @MainActor [weak self] in self?.dismissGraceNagIfPresenting() }
    }

    /// Called when the user restores the subscription via the paywall (`.glacierPlanPurchaseSuccessful`).
    func handleSubscriptionRestored() {
        clearPending()
        reEnableDoTIfEnforcementDisabledIt()
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

    /// Disables the system DoT profile (intent-aware, so the resilience heal can't re-enable it) and
    /// clears the widget's VPN status. VPN deactivation is handled by the existing lapse path
    /// (`turnOffCore()`); tunnels are intentionally not removed.
    private func performTeardown() {
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
