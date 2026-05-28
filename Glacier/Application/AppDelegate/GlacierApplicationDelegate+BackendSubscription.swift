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
        /// `true` when the user holds an active subscription purchased through the website.
        let subscribed: Bool
        /// Number of phone lines included in the web subscription: 0, 1, 2, or 5.
        /// `0` indicates no phone-number add-on.
        let phoneNumbers: Int
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
            if !justPurchased {
                account?.hasActiveSubscription = false
                let basePlanService = SKGlacierPlanPurchaseService()
                await basePlanService.refreshEntitlements()
            }

            // Mirror the same pattern for the phone plan. Apple StoreKit is the authoritative
            // source for phone subscriptions (backendPhoneNumbers reflects provisioned count, not
            // subscription status), so we must re-check it here the same way we re-check the
            // base plan — otherwise a stale `true` from a prior session persists indefinitely
            // and a lapsed phone subscription is never detected on foreground transitions.
            if !phoneJustPurchased {
                account?.hasActivePhoneNumberSubscription = false
                let phonePlanService = SKGlacierPhoneNumberPlanPurchaseService()
                await phonePlanService.refreshEntitlements()
            }

            let hadLiveBackendResponse = await queryAndApplyBackendSubscription()

            // Detect base plan active → inactive transition and notify the UI.
            // The guard in GlacierAppRootScreen ensures this only triggers a paywall when the
            // user is already past authentication (i.e. on the main screen, not at the splash).
            // Also suppress this on the first foreground right after a purchase: the StoreKit
            // re-check lag can make isNowSubscribed appear false even though the purchase succeeded.
            //
            // Require a live backend response before declaring a lapse.  If the backend call
            // failed and fell back to the cached lastKnownBackendSubscribed value, we cannot
            // distinguish "subscription genuinely lapsed" from "network was unavailable" (e.g.
            // the WireGuard tunnel was reconnecting).  Apple-only (IAP) subscribers always have
            // lastKnownBackendSubscribed=false, so a cached-fallback result combined with a
            // StoreKit timeout would otherwise incorrectly trigger the PilotEndedScreen and
            // fire destructive actions (tunnel removal, phone number release) against an active
            // subscriber who simply had a bad network moment.
            let isNowSubscribed = account?.hasActiveSubscription == true
            Log.general.notice("[BackendSubscription] refreshBackendSubscription: isNowSubscribed=\(isNowSubscribed) hadLiveBackendResponse=\(hadLiveBackendResponse)")
            if wasSubscribed && !isNowSubscribed && !justPurchased && !phoneJustPurchased && hadLiveBackendResponse {
                Log.general.notice("[BackendSubscription] refreshBackendSubscription: posting glacierBaseSubscriptionLapsed")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .glacierBaseSubscriptionLapsed, object: nil)
                }
            } else if !isNowSubscribed {
                Log.general.notice("[BackendSubscription] refreshBackendSubscription: not subscribed but lapse notification suppressed (wasSubscribed=\(wasSubscribed) justPurchased=\(justPurchased) phoneJustPurchased=\(phoneJustPurchased) hadLiveBackendResponse=\(hadLiveBackendResponse))")
            }

            // Detect phone plan active → inactive transition and notify SubscriptionAccessCoordinator.
            // Must be done here (not inside applyBackendSubscription) because previousPhoneSub is
            // captured after the reset above, so it always reads false inside applyBackendSubscription
            // and the deactivation branch there can never fire.
            let phoneIsNowSubscribed = account?.hasActivePhoneNumberSubscription == true
            if phoneWasSubscribed && !phoneIsNowSubscribed && !phoneJustPurchased {
                SubscriptionAccessCoordinator.shared.handleSubscriptionStatusChange(isSubscribed: false)
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
    /// take destructive action on a "not subscribed" result (e.g. showing PilotEndedScreen)
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
        // confirmed-empty result, and for IAP-only subscribers the backend always returns
        // subscribed=false (so a live backend response alone carries no signal).
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
        var effectiveBaseSubscribed = appleBaseSubscribed || backendSubscribed

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
