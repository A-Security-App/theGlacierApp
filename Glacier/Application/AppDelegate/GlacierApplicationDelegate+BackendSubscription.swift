//
//  GlacierApplicationDelegate+BackendSubscription.swift
//  Glacier
//
//  Queries the backend for the user's subscription status and reconciles it with the
//  Apple StoreKit subscription state.  Either source granting a subscription is sufficient
//  for the user to be considered subscribed.  When neither source grants a subscription,
//  any locally-stored phone numbers are removed (the backend handles server-side cleanup).
//

import UIKit
import Alamofire
import Foundation

extension GlacierApplicationDelegate {

    // MARK: - Response models

    /// Expected response envelope from `GET /status`.
    private struct BackendSubscriptionResponse: Codable {
        let status: Int
        let message: String
        let data: BackendSubscriptionData
    }

    /// Payload within the backend subscription response.
    struct BackendSubscriptionData: Codable {
        /// `true` when the backend sees an active base plan from any store it knows about
        /// (website, Apple, Google Play, or a family plan). `subscriptionSource` says which.
        let subscribed: Bool
        /// Number of phone lines the backend sees billed: 0, 1, 2, or 5, the largest count across
        /// stores, so Apple lines are included. `phoneLineSource` says which store.
        /// `0` indicates no phone-number add-on.
        let phoneNumbers: Int
        /// Store billing the base plan (`stripe` / `apple` / `google_play`), or absent/null when
        /// none does. Optional so a backend older than console#573 still decodes.
        let subscriptionSource: String?
        /// Store billing the phone-line add-on, with the same values as `subscriptionSource`.
        let phoneLineSource: String?
        /// `true` when the plan comes from someone else's family plan. Absent otherwise.
        let familyMember: Bool?
        /// End of the paid period as an ISO-8601 timestamp, or absent when the backend doesn't
        /// report one (not yet sent by the console as of 2026-10; see console `fix/mobile-status-expiry`).
        let expiryTime: String?
        /// Whether the plan renews as it stands. Absent means "not said", never `false`.
        let autoRenewing: Bool?
    }

    // MARK: - Public entry points

    /// Checks the backend subscription status and reconciles it with the current Apple
    /// subscription state.  Safe to call at launch and on every foreground transition.
    ///
    /// When called while the user is actively using the app (e.g. on foreground), this method
    /// also detects if the base subscription has just lapsed and fires `.glacierBaseSubscriptionLapsed`
    /// so that the UI can enforce the paywall and stop the VPN.
    func refreshBackendSubscription() {
        Task {
            // Capture and clear the just-purchased flags atomically at the start of this refresh.
            // If the user just completed a purchase this session, we skip the StoreKit reset
            // and re-check for that plan: Transaction.currentEntitlements can lag right after a
            // new purchase, and we already have authoritative confirmation from the verified
            // transaction itself. Clearing the flags here means the very next foreground after
            // this one resumes normal lapse detection.
            let justPurchased = Self.subscriptionJustPurchased
            Self.subscriptionJustPurchased = false
            let phoneJustPurchased = Self.phoneNumberSubscriptionJustPurchased
            Self.phoneNumberSubscriptionJustPurchased = false

            // Always re-verify from StoreKit and the backend — do not gate on account availability.
            // The account may be nil if the GRDB query returns no record (e.g. during early
            // launch before the DB is populated), but the entitlement check must still run so
            // that a previously-active subscription is not silently carried as stale-true.
            let account = GlacierAccountModel.getGlacierAccount()

            // Capture pre-refresh state for lapse detection (nil account → wasSubscribed=false,
            // so no spurious lapse notification is posted before the user has logged in).
            let wasSubscribed = account?.hasActiveSubscription == true
            let phoneWasSubscribed = account?.hasActivePhoneNumberSubscription == true
            Log.general.debug("[BackendSubscription] refreshBackendSubscription: wasSubscribed=\(wasSubscribed) justPurchased=\(justPurchased)")

            // Reset the cached Apple state and re-verify from StoreKit so that a stale `true`
            // value does not prevent lapse detection. Skip when a purchase just completed —
            // the purchase notification already set the flag correctly, and a redundant StoreKit
            // re-check here can race against currentEntitlements propagation and clear it.
            // Capture the base plan's definitiveness (was the entitlement enumeration a real result,
            // or a 5-second timeout?). Base-plan expiration enforcement / teardown must never act off
            // a timeout: StoreKit is the only source that sees an Apple subscription the moment it
            // ends, and a timeout looks exactly like "no entitlement". Previously this bool was
            // discarded for the base plan.
            var baseStoreKitWasDefinitive = false
            // Set when StoreKit has confirmed the Apple plan ended on this device; used below to
            // stop the backend's 3-day Apple grace from delaying lapse detection.
            var appleLapseConfirmedOnDevice = false
            if !justPurchased {
                account?.hasActiveSubscription = false
                let basePlanService = SKGlacierPlanPurchaseService()
                baseStoreKitWasDefinitive = await basePlanService.refreshEntitlements()
                if baseStoreKitWasDefinitive && account?.hasActiveSubscription == false {
                    appleLapseConfirmedOnDevice = await basePlanService.didAccountSubscriptionEndRecently()
                }
            } else {
                // A purchase just completed this session — the verified transaction is authoritative,
                // so treat the base StoreKit read as definitively confirmed for this cycle.
                baseStoreKitWasDefinitive = true
            }

            // Mirror the same pattern for the phone plan. StoreKit is the authoritative source for
            // Apple phone subscriptions: the backend's phoneNumbers keeps counting Apple lines for
            // 3 days past their expiry (its billing-retry grace), so we must re-check StoreKit here
            // the same way we re-check the base plan — otherwise a stale `true` from a prior
            // session persists indefinitely and a lapsed phone subscription is never detected on
            // foreground transitions.
            // Capture the phone plan's definitiveness (was the entitlement enumeration a real
            // result, or a 5-second timeout?). A downgrade must never be acted on off a timeout.
            var phoneStoreKitWasDefinitive = false
            if !phoneJustPurchased {
                account?.hasActivePhoneNumberSubscription = false
                let phonePlanService = SKGlacierPhoneNumberPlanPurchaseService()
                phoneStoreKitWasDefinitive = await phonePlanService.refreshEntitlements()
            }

            let hadLiveBackendResponse = await queryAndApplyBackendSubscription()

            // The backend keeps an Apple plan active for 3 days past Apple's expiry, and the result
            // above is StoreKit OR backend, so without this an Apple lapse would only be seen once
            // that window ends — and the 72-hour grace below would start from there (about 6 days
            // from expiry to the paywall). When StoreKit has definitely said no, the backend says
            // the plan is Apple's, and this device's App Store account is the one whose
            // subscription just ended for this Glacier account, trust StoreKit. The grace window
            // still applies, so protection stays on for 72 hours.
            //
            // Foreground only: resolveSubscriptionStatus() at cold launch keeps believing the
            // backend, because the launch path enforces with no grace when no window is open. Launch
            // never clears an open window, so the two paths don't fight; and since the backend's
            // grace is no longer than ours, it agrees the plan has lapsed by the time ours ends.
            if appleLapseConfirmedOnDevice,
               hadLiveBackendResponse,
               account?.lastKnownBackendSubscriptionSource == .apple,
               account?.hasActiveSubscription == true {
                account?.hasActiveSubscription = false
                Log.general.notice("[BackendSubscription] refreshBackendSubscription: Apple plan ended per StoreKit; not waiting for the backend's grace")
            }

            // Detect base plan active → inactive transition and notify the UI.
            // The guard in GlacierAppRootScreen ensures this only triggers a paywall when the
            // user is already past authentication (i.e. on the main screen, not at the splash).
            // Also suppress this on the first foreground right after a purchase: the StoreKit
            // re-check lag can make isNowSubscribed appear false even though the purchase succeeded.
            //
            // Require a live backend response before declaring a lapse.  If the backend call
            // failed and fell back to the cached lastKnownBackendSubscribed value, we cannot
            // distinguish "subscription genuinely lapsed" from "network was unavailable" (e.g.
            // the WireGuard tunnel was reconnecting).  The cached value can be false for an
            // active Apple subscriber (it was never set, or was saved before the backend saw the
            // purchase), so a cached-fallback result combined with a StoreKit timeout would
            // otherwise incorrectly read as a lapse and fire destructive actions (tunnel teardown,
            // DoT disabled) against an active subscriber who simply had a bad network moment.
            //
            // The backend reports Apple subscriptions too, and keeps them active for 3 days past
            // Apple's expiry (APPLE_EXPIRY_GRACE_MS in the console). See appleLapseConfirmedOnDevice
            // above for how that window is kept from delaying lapse detection.
            let isNowSubscribed = account?.hasActiveSubscription == true
            // A base-plan reading is only "confirmed" when BOTH the backend gave a live response AND
            // StoreKit gave a definitive (non-timeout) answer. Either gap means we cannot declare a
            // lapse: a cached backend value may be stale, and a StoreKit timeout is indistinguishable
            // from a confirmed-empty result. A live "not subscribed" from the backend isn't enough on
            // its own either: the backend may not have recorded a new Apple purchase yet.
            let baseReadingConfirmed = hadLiveBackendResponse && baseStoreKitWasDefinitive
            Log.general.notice("[BackendSubscription] refreshBackendSubscription: isNowSubscribed=\(isNowSubscribed) hadLiveBackendResponse=\(hadLiveBackendResponse) baseStoreKitWasDefinitive=\(baseStoreKitWasDefinitive)")
            // Gate only on the BASE just-purchased flag. The phone plan is an independent
            // subscription: a phone-plan purchase/renewal (which in sandbox auto-renews every few
            // minutes and re-arms phoneJustPurchased) must not suppress base-plan lapse detection —
            // doing so left an expired base subscription with no grace nag / paywall while the phone
            // plan was active.
            if wasSubscribed && !isNowSubscribed && !justPurchased {
                if baseReadingConfirmed {
                    // Confirmed expiration. Route through the grace handler (Model A + short grace):
                    // it preserves protection (VPN/DoT) during the grace window and only tears down +
                    // paywalls once the window elapses.
                    switch BaseSubscriptionLifecycleHandler.shared.evaluateExpiration() {
                    case .grace:
                        // Preserve protection while the grace window is open.
                        account?.hasActiveSubscription = true
                        Log.general.notice("[BackendSubscription] base expiry within grace — protection preserved")
                    case .enforce:
                        // Handler already disabled DoT + cleared widget status; stop VPN + show paywall.
                        Log.general.notice("[BackendSubscription] base grace elapsed — posting glacierBaseSubscriptionLapsed")
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .glacierBaseSubscriptionLapsed, object: nil)
                        }
                    case .inconclusive:
                        // Unreachable while baseReadingConfirmed == true; stay safe with benefit of doubt.
                        account?.hasActiveSubscription = true
                    }
                } else {
                    // Not a confirmed reading (StoreKit timeout / cached backend). Never act on a blip:
                    // give benefit of the doubt so a genuine lapse is caught on the next confirmed cycle.
                    account?.hasActiveSubscription = true
                    Log.general.notice("[BackendSubscription] base not-subscribed but reading unconfirmed — benefit of the doubt (hadLiveBackendResponse=\(hadLiveBackendResponse) baseStoreKitWasDefinitive=\(baseStoreKitWasDefinitive))")
                }
            } else if isNowSubscribed && baseReadingConfirmed {
                // Confirmed still-subscribed (renewed, or Apple billing grace recovered): clear any
                // open grace window and re-enable DoT if a prior enforcement had disabled it.
                BaseSubscriptionLifecycleHandler.shared.handleSubscriptionActive()
            }

            // Detect phone plan active → inactive transition and notify SubscriptionAccessCoordinator.
            // Must be done here (not inside applyBackendSubscription) because previousPhoneSub is
            // captured after the reset above, so it always reads false inside applyBackendSubscription
            // and the deactivation branch there can never fire.
            let phoneIsNowSubscribed = account?.hasActivePhoneNumberSubscription == true
            if phoneWasSubscribed && !phoneIsNowSubscribed && !phoneJustPurchased {
                SubscriptionAccessCoordinator.shared.handleSubscriptionStatusChange(isSubscribed: false)
            }

            // Detect a *partial* downgrade: the user still holds a phone subscription (>= 1 line)
            // but their tier dropped below the number of numbers they currently hold. Only act on
            // a confirmed reading — a live backend response AND a definitive (non-timeout) StoreKit
            // read, and not a just-completed purchase — so a transient network/timeout blip can
            // never trigger number removal. The reconciled allowedNumbers is the max() of the Apple
            // and backend tiers, so it only drops once *both* sources agree the tier is lower.
            if phoneIsNowSubscribed {
                let allowedNumbers = GlacierPhoneNumberSubscriptionPlan.activePlan?.maxPhoneNumbers ?? 1
                let isConfirmedReading = hadLiveBackendResponse && phoneStoreKitWasDefinitive && !phoneJustPurchased
                PhoneSubscriptionLifecycleHandler.shared.evaluatePhoneSubscriptionDowngrade(
                    allowedNumbers: allowedNumbers,
                    isConfirmedReading: isConfirmedReading
                )
            }
        }
    }

    /// Resolves the full subscription status from both Apple (StoreKit) and the backend,
    /// then reconciles the results. Call this once after authentication is confirmed and
    /// before routing the user to onboarding or the main screen. Idempotent and safe to
    /// call multiple times.
    ///
    /// Returns `true` when the backend responded with a live HTTP result, `false` when the
    /// backend call was skipped or failed and fell back to the cached value. Callers that
    /// take destructive action on a "not subscribed" result (e.g. tearing down protection
    /// and presenting the lapse paywall)
    /// should only do so when this returns `true` — a `false` return means we cannot
    /// distinguish a genuine lapse from a transient network outage (e.g. the WireGuard
    /// tunnel mid-reconnect at launch).
    @discardableResult
    func resolveSubscriptionStatus() async -> Bool {
        Log.general.debug("[BackendSubscription] resolveSubscriptionStatus: starting")
        // Reset the cached Apple subscription state before querying StoreKit.  Without this,
        // a stale `true` value from a prior session survives into the reconciliation step and
        // prevents the backend from revoking access when the subscription has lapsed.
        // The notification handlers in GlacierApplicationDelegate+InAppPurchase restore each
        // value to `true` only when StoreKit confirms an active entitlement.
        if let account = GlacierAccountModel.getGlacierAccount() {
            account.hasActiveSubscription = false
            account.hasActivePhoneNumberSubscription = false
        }

        // 1 & 2. Apple base and phone subscriptions — run concurrently since they write to
        //        independent account properties and post different notifications.
        //        Only the base plan's definitiveness matters for lapse/pilot routing — the
        //        phone plan result is discarded here (the phone-plan lapse path in
        //        refreshBackendSubscription uses its own detection logic).
        async let baseRefresh: Bool = SKGlacierPlanPurchaseService().refreshEntitlements()
        async let phoneRefresh: Bool = SKGlacierPhoneNumberPlanPurchaseService().refreshEntitlements()
        let (baseStoreKitWasDefinitive, _) = await (baseRefresh, phoneRefresh)

        // 3. Backend check — one network round-trip to /v1/mobile/status. Reconciles Apple +
        //    backend data and writes the winning value into hasActiveSubscription /
        //    hasActivePhoneNumberSubscription on the account.
        let hadLiveBackendResponse = await queryAndApplyBackendSubscription()

        // 4. If the user holds a phone subscription, kick off a queryForNumbers fetch so that
        //    any previously-provisioned Twilio numbers are populated into the local DB before
        //    onboarding routing decisions are made.  This is fire-and-forget: the network call
        //    runs concurrently while the user works through the onboarding screens (welcome →
        //    DNS → VPN → trusted networks), giving it ample time to complete.
        let account = GlacierAccountModel.getGlacierAccount()
        Log.general.notice("[BackendSubscription] resolveSubscriptionStatus: complete — hasActiveSubscription=\(account?.hasActiveSubscription == true) hasActivePhoneNumberSubscription=\(account?.hasActivePhoneNumberSubscription == true) hadLiveBackendResponse=\(hadLiveBackendResponse) baseStoreKitWasDefinitive=\(baseStoreKitWasDefinitive)")
        if account?.hasActivePhoneNumberSubscription == true {
            TwilioBackendManager.sharedMgr().queryForNumbers()
        }

        // Return true only when BOTH the backend gave a live response AND StoreKit gave a
        // definitive (non-timeout) answer for the base plan.  Either gap means we cannot
        // confidently declare a lapse: a StoreKit timeout is indistinguishable from a
        // confirmed-empty result, and the backend may not have recorded a new Apple purchase
        // yet (so a live "not subscribed" from it is not enough on its own).
        return hadLiveBackendResponse && baseStoreKitWasDefinitive
    }

    // MARK: - Private implementation

    /// Queries the backend subscription endpoint and applies the result.
    /// Returns `true` when a live HTTP response was received (success or authoritative failure),
    /// `false` when the call was skipped or the network request itself failed and the cached
    /// `lastKnownBackendSubscribed` value was used as a fallback instead.
    /// Callers that perform lapse detection should only act on the result when this returns
    /// `true` — a `false` return means we cannot distinguish a genuine lapse from a transient
    /// network outage (e.g. the WireGuard tunnel mid-reconnect).
    @discardableResult
    func queryAndApplyBackendSubscription() async -> Bool {
        guard let account = GlacierAccountModel.getGlacierAccount() else {
            Log.general.debug("[BackendSubscription] queryAndApply: no account — skipping")
            return false
        }

        guard !SecurityCenter.isProxyDetected else {
            Log.general.notice("[BackendSubscription] queryAndApply: proxy detected — using lastKnownBackendSubscribed=\(account.lastKnownBackendSubscribed)")
            applyBackendSubscription(subscribed: account.lastKnownBackendSubscribed,
                                     phoneNumbers: account.lastKnownBackendPhoneNumbers,
                                     account: account)
            return false
        }

        guard let url = EndpointService.shared.subscriptionURL else {
            Log.general.error("[BackendSubscription] queryAndApply: no subscription URL — using lastKnownBackendSubscribed=\(account.lastKnownBackendSubscribed)")
            applyBackendSubscription(subscribed: account.lastKnownBackendSubscribed,
                                     phoneNumbers: account.lastKnownBackendPhoneNumbers,
                                     account: account)
            return false
        }

        guard let headers = await GlacierAPIHeaders.authHeaders() else {
            Log.general.notice("[BackendSubscription] queryAndApply: auth headers unavailable — using lastKnownBackendSubscribed=\(account.lastKnownBackendSubscribed)")
            applyBackendSubscription(subscribed: account.lastKnownBackendSubscribed,
                                     phoneNumbers: account.lastKnownBackendPhoneNumbers,
                                     account: account)
            return false
        }
        Log.general.info("[BackendSubscription] queryAndApply: auth headers available — making backend call")

        return await withCheckedContinuation { continuation in
            GlacierPinningConfiguration.pinnedSession.request(url, method: .get, headers: headers,
                                                              requestModifier: { $0.timeoutInterval = 15 })
                .validate()
                .responseDecodable(of: BackendSubscriptionResponse.self) { [weak self] response in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }

                    switch response.result {
                    case .success(let body):
                        Log.general.info("[BackendSubscription] queryAndApply: backend returned subscribed=\(body.data.subscribed) phoneNumbers=\(body.data.phoneNumbers)")
                        account.lastKnownBackendSubscribed = body.data.subscribed
                        account.lastKnownBackendPhoneNumbers = body.data.phoneNumbers
                        // Only used to tell the user where to cancel when they delete their account.
                        // An unrecognised store is saved as unknown rather than guessed.
                        account.lastKnownBackendSubscriptionSource = body.data.subscriptionSource.flatMap(BillingStore.init(rawValue:))
                        account.lastKnownBackendPhoneLineSource = body.data.phoneLineSource.flatMap(BillingStore.init(rawValue:))
                        account.lastKnownBackendFamilyMember = body.data.familyMember ?? false
                        // Display-only, for Settings → Subscription. An unparseable date is dropped.
                        account.lastKnownBackendExpiry = body.data.expiryTime.flatMap(Self.parseBackendDate)
                        account.lastKnownBackendAutoRenewing = body.data.autoRenewing
                        self.applyBackendSubscription(subscribed: body.data.subscribed,
                                                      phoneNumbers: body.data.phoneNumbers,
                                                      account: account)
                        continuation.resume(returning: true)

                    case .failure(let error):
                        Log.general.notice("[BackendSubscription] queryAndApply: request failed (\(error)) — using lastKnownBackendSubscribed=\(account.lastKnownBackendSubscribed)")
                        self.applyBackendSubscription(subscribed: account.lastKnownBackendSubscribed,
                                                      phoneNumbers: account.lastKnownBackendPhoneNumbers,
                                                      account: account)
                        continuation.resume(returning: false)
                    }
                }
        }
    }

    /// Parses a backend ISO-8601 timestamp, with or without fractional seconds.
    private static func parseBackendDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    // MARK: - Reconciliation

    /// Merges the backend subscription result with the current Apple subscription state
    /// and updates `hasActiveSubscription` / `hasActivePhoneNumberSubscription` accordingly.
    ///
    /// - Parameters:
    ///   - backendSubscribed: Whether the backend reports an active subscription.
    ///   - backendPhoneNumbers: Number of phone lines granted by the backend (0, 1, 2, or 5).
    ///   - account: The current `GlacierAccountModel`.
    private func applyBackendSubscription(subscribed backendSubscribed: Bool,
                                          phoneNumbers backendPhoneNumbers: Int,
                                          account: GlacierAccountModel) {
        // --- Base subscription ---
        // account.hasActiveSubscription here reflects the current StoreKit result (either set
        // to `true` by the .glacierPlanPurchaseVerified notification handler, or reset to `false`
        // when no entitlement was found — see resolveSubscriptionStatus / refreshBackendSubscription).
        let appleBaseSubscribed = account.hasActiveSubscription
        let effectiveBaseSubscribed = appleBaseSubscribed || backendSubscribed

        // Persist "has ever subscribed" so the TestFlight override survives subscription expiry.
        if effectiveBaseSubscribed {
            UserDefaultsService.shared.set(true, for: \.hasEverSubscribedToGlacierPlan)
        }

        // Always write back so the cache is authoritative after every reconciliation cycle.
        // This also covers the revocation case: when neither Apple nor the backend grants a
        // subscription, hasActiveSubscription is correctly set to false here rather than
        // retaining a stale true from a prior session.
        account.hasActiveSubscription = effectiveBaseSubscribed

        // --- Phone number subscription ---
        // Use the in-memory flag (reset to false at the top of resolveSubscriptionStatus, then
        // set back to true by the .phoneNumberPlanPurchaseVerified handler only when StoreKit
        // confirms an active entitlement) as the Apple-side gate — mirroring how the base plan
        // uses account.hasActiveSubscription.  Reading activePlan directly from UserDefaults here
        // caused a bug: the stored plan ID is never cleared when a subscription expires (the
        // phoneNumberSubscriptionVerifiedThisSession guard blocks it), so applePhoneNumbers was
        // always > 0 and effectivePhoneSub was always true, even after the subscription lapsed.
        let applePhoneSubscribed = account.hasActivePhoneNumberSubscription
        // When Apple confirms the subscription is active, read the tier from activePlan.
        // Fall back to 1 if the plan ID is somehow absent (purchase in progress, etc.).
        let applePhoneNumbers = applePhoneSubscribed
            ? (GlacierPhoneNumberSubscriptionPlan.activePlan?.maxPhoneNumbers ?? 1)
            : 0
        // Higher value from either source takes precedence.
        let effectivePhoneNumbers = max(applePhoneNumbers, backendPhoneNumbers)
        let effectivePhoneSub = effectivePhoneNumbers > 0

        // Sync activePhoneNumberSubscriptionPlanId so all enforcement gates (which read
        // activePlan) reflect the correct tier regardless of whether the subscription
        // came from Apple or the backend. If effectivePhoneNumbers is 0, nothing is
        // written — the value stays unchanged and hasActivePhoneNumberSubscription=false
        // already blocks access to phone features.
        if let effectivePlan = GlacierPhoneNumberSubscriptionPlan.plan(forLineCount: effectivePhoneNumbers) {
            UserDefaultsService.shared.set(effectivePlan.rawValue, for: \.activePhoneNumberSubscriptionPlanId)
        }

        // Persist "has ever subscribed to phone" so the TestFlight override survives expiry.
        if effectivePhoneSub {
            UserDefaultsService.shared.set(true, for: \.hasEverSubscribedToPhoneNumberPlan)
        }

        let previousPhoneSub = account.hasActivePhoneNumberSubscription
        account.hasActivePhoneNumberSubscription = effectivePhoneSub

        // Notify MainVM, PhoneVM, and any other UI observers that the reconciled phone
        // subscription state is now written. This fires on every applyBackendSubscription call
        // (launch and foreground refresh) so that ViewModels initialized concurrently with
        // resolveSubscriptionStatus() always converge to the correct value.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .phoneSubscriptionStateDidChange, object: nil)
        }

        // Notify SubscriptionAccessCoordinator when the phone subscription becomes active so that
        // push notifications and Twilio token fetching are triggered. Deactivation is handled in
        // refreshBackendSubscription() using the pre-reset phoneWasSubscribed capture, because
        // previousPhoneSub here is read after the reset and is always false on lapse.
        if !previousPhoneSub && effectivePhoneSub {
            SubscriptionAccessCoordinator.shared.handleSubscriptionStatusChange(isSubscribed: true)
        }

        // --- Local phone number cleanup ---
        // Only remove locally-stored numbers when *neither* Apple nor the backend grants any
        // subscription.  The backend is responsible for server-side cleanup; we do not call
        // TwilioBackendManager.releaseNumber here.
        guard !effectiveBaseSubscribed else { return }

        let existingAccounts = TwilioBackendManager.sharedMgr().getExistingAccounts()
        guard !existingAccounts.isEmpty else { return }

        Log.general.notice("[BackendSubscription] No active subscription from any source – removing \(existingAccounts.count) phone number(s) locally")

        let numbers = existingAccounts.compactMap { $0.grdbRecord?.phoneNumber }
        for number in numbers {
            PhoneSubscriptionLifecycleHandler.shared.releaseNumberLocally(number)
        }
    }
}
