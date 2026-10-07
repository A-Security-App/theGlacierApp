//
//  SubscriptionSettingsViewModel.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import StoreKit
import UIKit

/**
 Where one half of the account's subscription (the Glacier plan or the phone lines) is billed, from
 this device's point of view: only an App Store subscription on the Apple Account this device buys
 with can be shown in detail and changed from inside the app.

 "This device's Apple Account" is whichever account StoreKit purchases with: the App Store account
 in Settings → your name → Media & Purchases, or the Sandbox Apple Account on development builds.
 It has nothing to do with the email the user signs in to Glacier with.
 */
enum SubscriptionOrigin: Equatable {
    /// StoreKit on this device holds it.
    case appStoreHere
    /// This device's Apple Account bought it for this Glacier account, and it ended at `endedAt`.
    case appStoreExpired(endedAt: Date)
    /// The backend says Apple bills it, but this device's Apple Account has no matching purchase.
    case appStoreOtherAccount
    case googlePlay
    case website
    /// Shared from someone else's family plan; the organizer manages it.
    case family
    /// Something bills it, but the backend didn't say which store.
    case unknown

    /// Name shown beside the plan, or `nil` when there is no store to name.
    var storeLabel: String? {
        switch self {
        case .appStoreHere, .appStoreExpired, .appStoreOtherAccount:
            return NSLocalizedString("App Store", comment: "Subscription settings store name")
        case .googlePlay:
            return NSLocalizedString("Google Play", comment: "Subscription settings store name")
        case .website:
            return NSLocalizedString("Glacier website", comment: "Subscription settings store name")
        case .family:
            return NSLocalizedString("Family plan", comment: "Subscription settings store name")
        case .unknown:
            return nil
        }
    }

    /// Where the plan was bought, as it reads mid-sentence ("bought …").
    fileprivate var boughtPhrase: String {
        switch self {
        case .appStoreHere, .appStoreExpired, .appStoreOtherAccount:
            return NSLocalizedString("through the App Store", comment: "Subscription settings: bought through the App Store")
        case .googlePlay:
            return NSLocalizedString("through Google Play", comment: "Subscription settings: bought through Google Play")
        case .website:
            return NSLocalizedString("on the Glacier website", comment: "Subscription settings: bought on the Glacier website")
        case .family, .unknown:
            return NSLocalizedString("outside the App Store", comment: "Subscription settings: bought outside the App Store")
        }
    }

    fileprivate var isExpired: Bool {
        if case .appStoreExpired = self { return true }
        return false
    }
}

/// An explanation card on the Subscription screen.
struct SubscriptionManagedNotice: Equatable, Identifiable {
    let title: String
    let message: String

    var id: String { title + message }
}

/**
 What StoreKit on this device says about Glacier's subscriptions. Answered on the device, so it
 needs no network, but enumeration can be slow; see `SubscriptionSettingsVM.appleSnapshot`.
 */
struct AppleSubscriptionSnapshot: Equatable {
    var basePlan: GlacierSubscriptionPlan?
    var basePlanExpiry: Date?
    var basePlanWillAutoRenew: Bool?
    var phonePlan: GlacierPhoneNumberSubscriptionPlan?
    /// Expiry of the most recent base-plan purchase this device's Apple Account made for this
    /// Glacier account, running or ended; `nil` when it made none.
    var basePlanLastExpiry: Date?
    /// Same for the phone-line add-on.
    var phonePlanLastExpiry: Date?
    /// `false` when StoreKit didn't answer in time, so "holds nothing" can't be trusted.
    var isDefinitive: Bool
}

/**
 SubscriptionSettingsViewModel defines requirements for the Subscription settings screen.
 */
protocol SubscriptionSettingsViewModel: GlacierViewModelWithRootCoordinator {
    var glacierPlanValue: String { get }
    var phoneLinesValue: String { get }
    var renewsValue: String? { get }
    var notices: [SubscriptionManagedNotice] { get }
    var canRenewGlacierPlan: Bool { get }
    var canRenewPhoneLines: Bool { get }
    var canChangePhoneLinePlan: Bool { get }
    var canManageInAppStore: Bool { get }
    var canManageOnWebsite: Bool { get }
    var footerText: String { get }

    func refresh()

    @MainActor
    func renewGlacierPlan()

    @MainActor
    func renewPhoneLines()

    @MainActor
    func changePhoneLinePlan()

    @MainActor
    func manageInAppStore()

    @MainActor
    func manageOnWebsite()

    @MainActor
    func restorePurchases()
}

/**
 SubscriptionSettingsVM shows what the account holds, where it's billed, and where to change it.

 Built from the reconciled entitlement (StoreKit + backend `mobile/status`), not StoreKit alone: a
 subscriber who bought on the website, on Android, or through a family plan must see the plan
 they're paying for rather than nothing. The cached values are shown first and then refreshed, so
 the screen never waits on the network.

 An expired plan is reported as expired even while something still grants access: the backend
 keeps an Apple plan active for 3 days past Apple's expiry, and the app keeps protection on for its
 own 72-hour grace window (`BaseSubscriptionLifecycleHandler`). The screen agrees with the
 "Subscription expired" popup rather than with those grace periods.

 Nothing here links out to Google Play, and the website is linked only on the US storefront (see
 `GlacierWebsite`): elsewhere, steering to an external payment flow is what App Store Review
 Guideline 3.1.1 targets. The screen names where a plan is managed instead.
 */
final class SubscriptionSettingsVM: SubscriptionSettingsViewModel, ObservableObject {

    // MARK: - Public properties

    @Published private(set) var glacierPlanValue: String = ""
    @Published private(set) var phoneLinesValue: String = ""
    @Published private(set) var renewsValue: String?
    @Published private(set) var notices: [SubscriptionManagedNotice] = []
    @Published private(set) var canRenewGlacierPlan: Bool = false
    @Published private(set) var canRenewPhoneLines: Bool = false
    @Published private(set) var canChangePhoneLinePlan: Bool = false
    @Published private(set) var canManageInAppStore: Bool = false
    @Published private(set) var canManageOnWebsite: Bool = false
    @Published private(set) var footerText: String = ""

    var rootCoordinator: any GlacierRootCoordinator

    // MARK: - Private properties

    /// How recently an Apple purchase must have ended to count as this account's lapse. Matches
    /// `didAccountSubscriptionEndRecently`: the backend keeps an Apple plan active for 3 days past
    /// expiry, so an older end means the backend is reporting some other subscription.
    private static let recentExpiryWindow = GlacierPhoneNumberSubscriptionPlan.recentAppleExpiryWindow

    /// Last StoreKit answer. Starts empty and non-definitive so the cached render makes no claims
    /// StoreKit hasn't backed.
    private var apple = AppleSubscriptionSnapshot(isDefinitive: false)
    /// Whether this device's App Store account is on the US storefront; see `GlacierWebsite`.
    /// Starts `false` so the link never shows before StoreKit has said so.
    private var websiteLinkAllowed = false
    private var refreshTask: Task<Void, Never>?

    // MARK: - Initializer

    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        render()
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Public methods

    /// Re-reads StoreKit and `mobile/status`, re-rendering after each. Opening this screen is an
    /// explicit request to see the current state, so it's worth the round trip.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            async let linkAllowed = GlacierWebsite.canLinkToWebsite()
            let snapshot = await Self.appleSnapshot()
            let websiteLinkAllowed = await linkAllowed
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.apple = snapshot
                self.websiteLinkAllowed = websiteLinkAllowed
                self.render()
            }
            // Same call the foreground refresh makes; it persists the sources and renewal fields
            // this screen reads, and falls back to the cache when the request fails.
            await GlacierApplicationDelegate.shared?.queryAndApplyBackendSubscription()
            guard !Task.isCancelled else { return }
            await MainActor.run { self.render() }
        }
    }

    /// Opens the same renew paywall as the grace popup's "Renew now".
    @MainActor
    func renewGlacierPlan() {
        NotificationCenter.default.post(name: .glacierPresentRenewPaywall, object: nil)
    }

    /// Opens the phone-line plans directly. `presentPhoneNumberPlanPurchase`'s guard is skipped on
    /// purpose: this is only offered when the lines were this device's Apple Account's own and have
    /// ended, so a purchase here can't double-bill, and the guard would wrongly read the backend's
    /// 3-day Apple grace as "billed to another Apple Account".
    @MainActor
    func renewPhoneLines() {
        presentSheet(.phoneNumberPlanPurchase)
    }

    @MainActor
    func changePhoneLinePlan() {
        presentPhoneNumberPlanPurchase(orWarnManagedElsewhere: {
            self.presentSheet(.phoneNumberPlanPurchase)
        })
    }

    @MainActor
    func manageInAppStore() {
        Task { @MainActor in
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            do {
                guard let scene else { throw CancellationError() }
                try await AppStore.showManageSubscriptions(in: scene)
            } catch {
                if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                    await UIApplication.shared.open(url)
                }
            }
            // The user may have changed or cancelled something in the sheet.
            refresh()
        }
    }

    @MainActor
    func manageOnWebsite() {
        GlacierWebsite.openManageSubscription()
    }

    /// Syncs the App Store's transactions to this device, re-reads them, and re-reconciles with
    /// the backend, the same steps the paywall's restore takes. `AppStore.sync()` may ask the user
    /// to sign in to their Apple Account.
    @MainActor
    func restorePurchases() {
        presentProgressIndicator()
        Task { @MainActor in
            do {
                try await AppStore.sync()
            } catch StoreKitError.userCancelled {
                dismissProgressIndicator()
                return
            } catch {
                // Keep going: what's already on the device and the backend can still be re-read.
                Log.general.notice("[SubscriptionSettings] AppStore.sync failed: \(error)")
            }
            // Writes the account flags and fires the usual purchase-verified handlers.
            async let baseRefresh = SKGlacierPlanPurchaseService().refreshEntitlements()
            async let phoneRefresh = SKGlacierPhoneNumberPlanPurchaseService().refreshEntitlements()
            _ = await (baseRefresh, phoneRefresh)
            let snapshot = await Self.appleSnapshot()
            await GlacierApplicationDelegate.shared?.queryAndApplyBackendSubscription()
            apple = snapshot
            render()
            dismissProgressIndicator()

            let account = GlacierAccountModel.getGlacierAccount()
            let foundNothing = snapshot.basePlan == nil && snapshot.phonePlan == nil
                && account?.hasActiveSubscription != true
                && account?.hasActivePhoneNumberSubscription != true
            if foundNothing {
                presentAlertWith(
                    title: NSLocalizedString("No Purchases Found", comment: "Restore purchases found nothing title"),
                    description: NSLocalizedString(
                        "We couldn't find an active subscription for this Apple Account or your Glacier account.",
                        comment: "Restore purchases found nothing description"
                    )
                )
            }
        }
    }

    // MARK: - Rendering

    /// Rebuilds every published value from the persisted account state, the grace window, and the
    /// last StoreKit answer. Reads only local values, so it's cheap; always called on the main thread.
    private func render() {
        let account = GlacierAccountModel.getGlacierAccount()
        let graceEndsAt = BaseSubscriptionLifecycleHandler.shared.gracePeriodEndsAt
        let hasBasePlan = account?.hasActiveSubscription == true || apple.basePlan != nil
        let lines = max(
            apple.phonePlan?.maxPhoneNumbers ?? 0,
            account?.hasActivePhoneNumberSubscription == true
                ? (GlacierPhoneNumberSubscriptionPlan.activePlan?.maxPhoneNumbers ?? 1)
                : 0
        )

        let baseOrigin = hasBasePlan ? origin(
            heldByStoreKit: apple.basePlan != nil,
            lastAppleExpiry: apple.basePlanLastExpiry,
            backendSource: account?.lastKnownBackendSubscriptionSource,
            backendReportsIt: account?.lastKnownBackendSubscribed == true,
            familyMember: account?.lastKnownBackendFamilyMember == true
        ) : nil
        let linesOrigin = lines > 0 ? origin(
            heldByStoreKit: apple.phonePlan != nil,
            lastAppleExpiry: apple.phonePlanLastExpiry,
            backendSource: account?.lastKnownBackendPhoneLineSource,
            backendReportsIt: (account?.lastKnownBackendPhoneNumbers ?? 0) > 0,
            familyMember: account?.lastKnownBackendFamilyMember == true
        ) : nil

        // The base plan has expired when this device's App Store purchase ended, or when the app
        // has opened its grace window (which only happens on a confirmed lapse) — whatever the
        // backend's own grace still says.
        let baseExpired = baseOrigin?.isExpired == true || (baseOrigin != nil && graceEndsAt != nil)
        let linesExpired = linesOrigin?.isExpired == true

        // Glacier plan: the term when StoreKit knows it, otherwise just "Active".
        if let baseOrigin {
            let status: String
            if baseExpired {
                status = NSLocalizedString("Expired", comment: "Subscription settings expired plan")
            } else {
                switch apple.basePlan {
                case .yearly?: status = NSLocalizedString("Yearly", comment: "Subscription settings yearly plan")
                case .monthly?: status = NSLocalizedString("Monthly", comment: "Subscription settings monthly plan")
                case nil: status = NSLocalizedString("Active", comment: "Subscription settings active plan")
                }
            }
            glacierPlanValue = [status, baseOrigin.storeLabel].compactMap { $0 }.joined(separator: " · ")
        } else {
            glacierPlanValue = NSLocalizedString("None", comment: "Subscription settings no plan")
        }

        // Phone lines: a family member's lines read as just the count, as on Android.
        if let linesOrigin {
            let count = linesExpired
                // Its own key for the same reason as "None (phone lines)" below.
                ? NSLocalizedString("Expired (phone lines)", value: "Expired", comment: "Subscription settings expired phone lines")
                : "\(lines)"
            let storeLabel = linesOrigin == .family ? nil : linesOrigin.storeLabel
            phoneLinesValue = [count, storeLabel].compactMap { $0 }.joined(separator: " · ")
        } else {
            // Its own key: some languages agree "None" with the noun ("líneas", "lignes" are feminine).
            phoneLinesValue = NSLocalizedString("None (phone lines)", value: "None", comment: "Subscription settings no phone lines")
        }

        renewsValue = baseExpired ? nil : renewalDate(baseOrigin: baseOrigin, account: account).map {
            $0.formatted(.dateTime.month(.wide).day().year())
        }

        canRenewGlacierPlan = baseExpired
        canRenewPhoneLines = linesExpired
        canManageInAppStore = (baseOrigin == .appStoreHere && !baseExpired) || linesOrigin == .appStoreHere
        canChangePhoneLinePlan = linesOrigin == .appStoreHere
        // Offered for an expired website plan too: the website is where it's renewed.
        canManageOnWebsite = websiteLinkAllowed && (baseOrigin == .website || linesOrigin == .website)

        var notices: [SubscriptionManagedNotice] = []
        if baseExpired, let baseOrigin {
            notices.append(Self.baseExpiredNotice(origin: baseOrigin, graceEndsAt: graceEndsAt))
        }
        if case .appStoreExpired(let endedAt)? = linesOrigin {
            notices.append(Self.linesExpiredNotice(endedAt: endedAt))
        }
        // Expired halves have their own card above; this one covers what's active elsewhere.
        if let notice = Self.managedElsewhereNotice(
            baseOrigin: baseExpired ? nil : baseOrigin,
            linesOrigin: linesExpired ? nil : linesOrigin,
            hasBasePlan: baseOrigin != nil,
            hasLines: linesOrigin != nil
        ) {
            notices.append(notice)
        }
        self.notices = notices

        let onlyAppStore = [baseOrigin, linesOrigin].compactMap { $0 }.allSatisfy {
            $0 == .appStoreHere || $0.isExpired
        }
        footerText = onlyAppStore
            ? NSLocalizedString(
                "Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period. Manage or cancel anytime in your App Store account settings.",
                comment: "Subscription settings footer for App Store subscriptions")
            : NSLocalizedString(
                "Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period. Manage or cancel wherever you bought it.",
                comment: "Subscription settings footer for subscriptions bought elsewhere")
    }

    /**
     Resolves where one half of the subscription is billed.

     1. StoreKit on this device holds it: the App Store here, whatever else the backend says.
     2. A family member's plan is the organizer's, unless another store bills it to this account.
     3. Otherwise the backend's source. Where that's Apple (or there's no source and the backend
        doesn't report the plan either, so StoreKit is what granted it), this device's purchase
        history decides between "expired here" and "another Apple Account".
     */
    private func origin(heldByStoreKit: Bool,
                        lastAppleExpiry: Date?,
                        backendSource: BillingStore?,
                        backendReportsIt: Bool,
                        familyMember: Bool) -> SubscriptionOrigin {
        if heldByStoreKit { return .appStoreHere }
        switch backendSource {
        case .apple?:
            return appleOrigin(lastExpiry: lastAppleExpiry, otherwise: .appStoreOtherAccount)
        case .googlePlay?:
            return .googlePlay
        case .stripe?:
            return familyMember ? .family : .website
        case nil:
            if familyMember { return .family }
            // A flag the backend doesn't explain came from StoreKit: if it isn't held now, it ended.
            return backendReportsIt ? .unknown : appleOrigin(lastExpiry: lastAppleExpiry, otherwise: .appStoreHere)
        }
    }

    /// Classifies an Apple-billed plan that StoreKit on this device doesn't currently hold.
    ///
    /// Not holding it has two causes that look identical to `currentEntitlements`: this Apple
    /// Account's subscription ended (and the backend's 3-day grace still counts it), or a different
    /// Apple Account bought it. This device's purchase history tells them apart. With no definite
    /// StoreKit answer, it's left as the App Store here, whose own sheet is a safe thing to offer.
    private func appleOrigin(lastExpiry: Date?, otherwise: SubscriptionOrigin) -> SubscriptionOrigin {
        guard apple.isDefinitive else { return .appStoreHere }
        guard let lastExpiry else { return otherwise }
        let now = Date()
        if lastExpiry <= now {
            return now.timeIntervalSince(lastExpiry) <= Self.recentExpiryWindow
                ? .appStoreExpired(endedAt: lastExpiry)
                : otherwise
        }
        // Still running by its dates but not entitled (revoked, or StoreKit catching up): let the
        // App Store's own sheet explain it.
        return .appStoreHere
    }

    /// The date to print as "Renews", only when the plan definitely renews unchanged. StoreKit
    /// answers for an App Store plan on this device; the backend for everything else.
    private func renewalDate(baseOrigin: SubscriptionOrigin?, account: GlacierAccountModel?) -> Date? {
        guard let baseOrigin, baseOrigin != .family else { return nil }
        if baseOrigin == .appStoreHere, apple.basePlan != nil {
            return apple.basePlanWillAutoRenew == true ? apple.basePlanExpiry : nil
        }
        guard account?.lastKnownBackendAutoRenewing == true,
              let expiry = account?.lastKnownBackendExpiry,
              expiry > Date() else { return nil }
        return expiry
    }

    // MARK: - Notices

    private static func baseExpiredNotice(origin: SubscriptionOrigin, graceEndsAt: Date?) -> SubscriptionManagedNotice {
        var sentences: [String] = []
        if case .appStoreExpired(let endedAt) = origin {
            sentences.append(String(
                format: NSLocalizedString(
                    "Your App Store subscription ended on %@.",
                    comment: "Subscription settings expired notice: App Store end date"),
                endedAt.formatted(.dateTime.month(.wide).day().year())
            ))
        } else {
            sentences.append(NSLocalizedString(
                "Your Glacier plan has ended.",
                comment: "Subscription settings expired notice: plan ended, date unknown"))
        }
        if let graceEndsAt {
            sentences.append(String(
                format: NSLocalizedString(
                    "Your VPN and encrypted DNS protection stays on until %@. Renew to keep it.",
                    comment: "Subscription settings expired notice: grace end date and time"),
                graceEndsAt.formatted(date: .long, time: .shortened)
            ))
        } else {
            sentences.append(NSLocalizedString(
                "Renew to keep your VPN and encrypted DNS protection.",
                comment: "Subscription settings expired notice: no grace window"))
        }
        return SubscriptionManagedNotice(
            title: NSLocalizedString("Your subscription has expired", comment: "Subscription settings expired notice title"),
            message: sentences.joined(separator: " ")
        )
    }

    private static func linesExpiredNotice(endedAt: Date) -> SubscriptionManagedNotice {
        SubscriptionManagedNotice(
            title: NSLocalizedString("Your phone lines have expired", comment: "Subscription settings expired phone lines title"),
            message: String(
                format: NSLocalizedString(
                    "Your App Store subscription for phone lines ended on %@. Choose a phone-line plan to keep using your numbers.",
                    comment: "Subscription settings expired phone lines message: end date"),
                endedAt.formatted(.dateTime.month(.wide).day().year())
            )
        )
    }

    /**
     The card explaining active parts of the subscription that can't be managed here, or `nil`
     when there are none.

     - Parameters:
       - baseOrigin: The base plan's origin, or `nil` when there's none or another card covers it.
       - linesOrigin: Same for the phone lines.
       - hasBasePlan: Whether the account holds a base plan at all, to name the right subject.
       - hasLines: Same for the phone lines.
     */
    private static func managedElsewhereNotice(baseOrigin: SubscriptionOrigin?,
                                               linesOrigin: SubscriptionOrigin?,
                                               hasBasePlan: Bool,
                                               hasLines: Bool) -> SubscriptionManagedNotice? {
        let base = baseOrigin.flatMap { $0 == .appStoreHere ? nil : $0 }
        let lines = linesOrigin.flatMap { $0 == .appStoreHere ? nil : $0 }
        guard base != nil || lines != nil else { return nil }

        if base == .family || (base == nil && lines == .family) {
            return SubscriptionManagedNotice(
                title: NSLocalizedString("Shared through a family plan", comment: "Subscription settings family plan title"),
                message: NSLocalizedString(
                    "Your subscription is active and shared with you through a Glacier family plan. The person who manages the family plan can change it.",
                    comment: "Subscription settings family plan message")
            )
        }

        // Two different stores outside this device's App Store: name both.
        if let base, let lines, base != lines {
            let format = NSLocalizedString(
                "Your subscription is active. Your Glacier plan was bought %1$@ and your phone lines %2$@, so neither can be changed here. Manage each one where it was bought.",
                comment: "Subscription settings split-store message: base plan store, phone lines store")
            return SubscriptionManagedNotice(
                title: NSLocalizedString("Managed outside the App Store", comment: "Subscription settings managed elsewhere title"),
                message: String(format: format, base.boughtPhrase, lines.boughtPhrase)
            )
        }

        guard let store = base ?? lines else { return nil }
        // The whole subscription, unless the other half exists and is handled separately.
        let status: String
        if base != nil, lines == nil, hasLines {
            status = NSLocalizedString("Your Glacier plan is active.", comment: "Subscription settings notice status: base plan")
        } else if lines != nil, base == nil, hasBasePlan {
            status = NSLocalizedString("Your phone lines are active.", comment: "Subscription settings notice status: phone lines")
        } else {
            status = NSLocalizedString("Your subscription is active.", comment: "Subscription settings notice status: whole subscription")
        }

        let title: String
        let detail: String
        switch store {
        case .appStoreOtherAccount:
            title = NSLocalizedString("Bought with a different Apple Account", comment: "Subscription settings other Apple Account title")
            detail = NSLocalizedString(
                "The purchase was made with a different Apple Account than the one this iPhone uses for App Store purchases, so its details can't be shown or changed here. To manage it, sign in with that Apple Account under Settings → your name → Media & Purchases, or tap Restore purchases.",
                comment: "Subscription settings other Apple Account message")
        case .googlePlay:
            title = NSLocalizedString("Managed in Google Play", comment: "Subscription settings Google Play title")
            detail = NSLocalizedString(
                "Plans bought through Google Play can't be changed here. To change or cancel, open the Google Play Store on an Android device signed in to the Google account that made the purchase.",
                comment: "Subscription settings Google Play message")
        case .website:
            title = NSLocalizedString("Managed on the Glacier website", comment: "Subscription settings website title")
            detail = NSLocalizedString(
                "Plans bought on the Glacier website can't be changed here. Sign in on the Glacier website to change or cancel.",
                comment: "Subscription settings website message")
        case .unknown, .family, .appStoreHere, .appStoreExpired:
            title = NSLocalizedString("Managed outside the App Store", comment: "Subscription settings managed elsewhere title")
            detail = NSLocalizedString(
                "Plans bought outside the App Store can't be changed here. Manage or cancel where you made the purchase.",
                comment: "Subscription settings unknown store message")
        }
        return SubscriptionManagedNotice(title: title, message: status + " " + detail)
    }

    // MARK: - StoreKit

    /**
     Reads this device's App Store state for the base plan and the phone-line add-on: what's
     entitled now (`Transaction.currentEntitlements`) and the latest purchase of each for this
     Glacier account (`Transaction.all`). Both passes are raced against `timeout` so a slow
     StoreKit can't hold the screen; a timeout returns a non-definitive empty snapshot.

     History matches `didAccountSubscriptionEndRecently`: base-plan purchases must carry this
     account's `appAccountToken`, so another Glacier account's purchase on the same Apple Account
     doesn't count. Phone add-ons follow `GlacierPhoneNumberSubscriptionPlan.latestAppleExpiry`,
     the same rule the Phone tab's upgrade guard uses.
     */
    private static func appleSnapshot(timeout: TimeInterval = 5) async -> AppleSubscriptionSnapshot {
        let accountToken = await SKGlacierPlanPurchaseService().resolveAppAccountToken()
        let storeKitTask = Task.detached(priority: .userInitiated) { () -> AppleSubscriptionSnapshot in
            var snapshot = AppleSubscriptionSnapshot(isDefinitive: true)
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result,
                      transaction.revocationDate == nil else { continue }
                if let plan = GlacierSubscriptionPlan(rawValue: transaction.productID) {
                    snapshot.basePlan = plan
                    snapshot.basePlanExpiry = transaction.expirationDate
                    if let status = await transaction.subscriptionStatus,
                       case .verified(let renewal) = status.renewalInfo {
                        snapshot.basePlanWillAutoRenew = renewal.willAutoRenew
                    }
                } else if let plan = GlacierPhoneNumberSubscriptionPlan(rawValue: transaction.productID),
                          plan.rank > (snapshot.phonePlan?.rank ?? 0) {
                    snapshot.phonePlan = plan
                }
            }
            for await result in Transaction.all {
                guard case .verified(let transaction) = result,
                      GlacierSubscriptionPlan(rawValue: transaction.productID) != nil,
                      !transaction.isUpgraded,
                      let accountToken, transaction.appAccountToken == accountToken,
                      let expiration = transaction.expirationDate,
                      expiration > (snapshot.basePlanLastExpiry ?? .distantPast) else { continue }
                snapshot.basePlanLastExpiry = expiration
            }
            snapshot.phonePlanLastExpiry = await GlacierPhoneNumberSubscriptionPlan.latestAppleExpiry(accountToken: accountToken)
            return snapshot
        }

        return await withTaskGroup(of: AppleSubscriptionSnapshot.self) { group in
            group.addTask { await storeKitTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return AppleSubscriptionSnapshot(isDefinitive: false)
            }
            let result = await group.next() ?? AppleSubscriptionSnapshot(isDefinitive: false)
            group.cancelAll()
            storeKitTask.cancel()
            return result
        }
    }
}
