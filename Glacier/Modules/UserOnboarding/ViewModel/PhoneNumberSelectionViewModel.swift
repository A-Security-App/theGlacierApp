//
//  PhoneNumberSelectionViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 09/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 PhoneNumberSelectionViewModel defines requirements for PhoneNumberSelectionScreen view models.
 */
protocol PhoneNumberSelectionViewModel: GlacierViewModelWithRootCoordinator {
    var isPresentedFromPhoneScreen: Bool { get }
    var isKeyboardVisible: Bool { get }
    var searchText: String { get set }
    
    var isLoadingPhoneNumbers: Bool { get }
    var glacierPhoneNumbersAll: [GlacierPhoneNumber] { get }
    var glacierPhoneNumbersFiltered: [GlacierPhoneNumber] { get }
    
    init(rootCoordinator: any GlacierRootCoordinator, isPresentedFromPhoneScreen: Bool)
    
    @MainActor
    func loadPhoneNumbers()

    @MainActor
    func searchForAvailableNumbers()

    @MainActor
    func presentAddNumberConfirmationPrompt(for phoneNumber: String)
}

/**
 PhoneNumberSelectionVM defines data/state and business logic for PhoneNumberSelectionScreen.
 */
final class PhoneNumberSelectionVM: PhoneNumberSelectionViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published private(set) var isKeyboardVisible = false
    
    @Published var searchText: String = "" {
        didSet {
            if searchText.count >= 3 {
                searchDebounceTimer?.invalidate()
                searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.searchForAvailableNumbers()
                    }
                }
            } else {
                searchDebounceTimer?.invalidate()
                filterPhoneNumbers(with: searchText)
            }
        }
    }
    
    @Published private(set) var isLoadingPhoneNumbers: Bool = true
    @Published private(set) var glacierPhoneNumbersAll: [GlacierPhoneNumber] = []
    @Published private(set) var glacierPhoneNumbersFiltered: [GlacierPhoneNumber] = []
    
    let rootCoordinator: any GlacierRootCoordinator
    private(set) var isPresentedFromPhoneScreen: Bool
    
    // MARK: - Private properties

    private var addPhoneNumbersCount: Int = 0
    private var isPerformingSearch = false
    private var searchDebounceTimer: Timer?

    /// Bumped on every lookup so a timeout armed for an earlier request cannot tear
    /// down the spinner belonging to a later one. The search field debounces at 0.5s,
    /// so several lookups can be in flight at once.
    private var lookupGeneration = 0
    private var lookupTimeoutTask: Task<Void, Never>?
    /// Failsafe only — the request itself is capped at 20s inside TwilioBackendManager.
    /// This exists so the overlay still comes down if some future exit path forgets to
    /// report back, which is the bug this whole path is being fixed for.
    private static let lookupTimeoutNanoseconds: UInt64 = 30_000_000_000
    
    private var maxAllowedPhoneNumbers: Int {
        guard let plan = GlacierPhoneNumberSubscriptionPlan.activePlan else {
            return 0
        }
        return plan.maxPhoneNumbers
    }
    
    private var hasAddedMaxAllowedPhoneNumbers: Bool {
        let userAddedPhoneNumbers = TwilioBackendManager.sharedMgr().getExistingAccounts()
        return userAddedPhoneNumbers.count == maxAllowedPhoneNumbers
    }
    
    // MARK: - Initializer
    
    required init(rootCoordinator: any GlacierRootCoordinator, isPresentedFromPhoneScreen: Bool = false) {
        self.rootCoordinator = rootCoordinator
        self.isPresentedFromPhoneScreen = isPresentedFromPhoneScreen
        
        observeKeyboardEvents()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        searchDebounceTimer?.invalidate()
        lookupTimeoutTask?.cancel()
    }
    
    // MARK: - Public methods
    
    @MainActor
    func loadPhoneNumbers() {
        isPerformingSearch = false
        beginLookup()

        TwilioBackendManager.sharedMgr().setPhoneDelegate(self)
        TwilioBackendManager.sharedMgr().queryForAvailableNumbers(areaCode: nil, contains: nil)
    }

    @MainActor
    func searchForAvailableNumbers() {
        guard !searchText.isEmpty else { return }
        isPerformingSearch = true
        beginLookup()

        TwilioBackendManager.sharedMgr().setPhoneDelegate(self)
        if searchText.count == 3 {
            TwilioBackendManager.sharedMgr().queryForAvailableNumbers(areaCode: searchText, contains: nil)
        } else {
            TwilioBackendManager.sharedMgr().queryForAvailableNumbers(areaCode: nil, contains: searchText)
        }
    }

    @MainActor
    func presentAddNumberConfirmationPrompt(for phoneNumber: String) {
        // Guard 1: user has reached their plan’s concurrent-number cap — suggest upgrading.
        guard !hasAddedMaxAllowedPhoneNumbers else {
            let alertText = NSLocalizedString(
                "Your current subscription allows up to %@ phone numbers. You may upgrade your plan later to purchase more.",
                comment: "Phone number selection screen max phone number added popup description"
            )
            presentAlertWith(
                title: NSLocalizedString("Upgrade to add phone lines", comment: "Phone number selection screen max phone number added popup title"),
                description: String(format: alertText, arguments: ["\(maxAllowedPhoneNumbers)"])
            )
            return
        }

        // Guard 2: user has consumed all free number slots — show the $2.99 paywall.
        let account = GlacierAccountModel.getGlacierAccount()
        guard (account?.freePhoneNumberSlotsRemaining ?? 0) > 0 else {
            presentExtraNumberPurchasePrompt(for: phoneNumber)
            return
        }

        // Free slot available — show the standard (no-charge) confirmation.
        presentFreeAddConfirmationPrompt(for: phoneNumber)
    }

    // MARK: - Lookup lifecycle

    /// Raises the progress overlay and arms the failsafe timeout for a new lookup.
    @MainActor
    private func beginLookup() {
        isLoadingPhoneNumbers = true
        presentProgressIndicator()

        lookupGeneration += 1
        let generation = lookupGeneration
        lookupTimeoutTask?.cancel()
        lookupTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.lookupTimeoutNanoseconds)
            guard !Task.isCancelled, let self else { return }
            await self.handleLookupTimeout(generation: generation)
        }
    }

    @MainActor
    private func handleLookupTimeout(generation: Int) {
        // A newer lookup has already taken over, or one came back — nothing to clear.
        guard generation == lookupGeneration, isLoadingPhoneNumbers else { return }
        finishLookup(with: .requestFailed)
    }

    /// Deliberately not @MainActor: it touches only a private stored property, and
    /// the delegate callback that calls it arrives on the main *queue* without the
    /// compiler knowing that. Isolating it would force an `assumeIsolated` that traps
    /// if the assumption is ever wrong.
    private func cancelLookupTimeout() {
        lookupTimeoutTask?.cancel()
        lookupTimeoutTask = nil
    }

    /// Single exit point for a lookup that produced no numbers. Always lowers the
    /// overlay before saying anything, so the user is never left with a blocking
    /// spinner and no way out.
    @MainActor
    private func finishLookup(with failure: PhoneNumberLookupFailure) {
        cancelLookupTimeout()
        isLoadingPhoneNumbers = false
        dismissProgressIndicator()
        presentLookupFailurePrompt(for: failure)
    }

    @MainActor
    private func retryLookup() {
        if isPerformingSearch, !searchText.isEmpty {
            searchForAvailableNumbers()
        } else {
            loadPhoneNumbers()
        }
    }

    @MainActor
    private func presentLookupFailurePrompt(for failure: PhoneNumberLookupFailure) {
        // The cause is deliberately kept out of the copy. Naming the proxy check
        // alarms anyone sitting behind a legitimate corporate proxy, and "check your
        // signal" asserts a cause we only inferred. It goes to the log instead, where
        // it is the only breadcrumb this failure leaves.
        Log.calls.error(
            "Available-number lookup failed: \(String(describing: failure), privacy: .public)"
        )

        let configuration = PopupConfiguration(
            title: NSLocalizedString(
                "Couldn’t load numbers",
                comment: "Phone number selection screen lookup failure popup title"
            ),
            description: NSLocalizedString(
                "Glacier couldn’t load available numbers. Check your connection, then try again.",
                comment: "Phone number selection screen lookup failure popup description"
            ),
            buttons: [
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString(
                        "Try Again",
                        comment: "Phone number selection screen lookup retry button title"
                    ),
                    onTap: { [weak self] in
                        guard let self else { return }
                        self.dismissPopup()
                        Task { @MainActor in
                            self.retryLookup()
                        }
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: .cancelText,
                    onTap: { [weak self] in
                        self?.dismissPopup()
                    }
                )
            ],
            buttonsAlignment: .vertical
        )
        presentPopup(with: configuration)
    }

    // MARK: - Private methods

    /// Standard confirmation shown when the user still has a free number slot available.
    @MainActor
    private func presentFreeAddConfirmationPrompt(for phoneNumber: String) {
        let description = NSLocalizedString(
            "Are you sure you want to add %@?",
            comment: "Phone number selection screen confirm popup description"
        )
        let formattedDescription = String(format: description, arguments: [phoneNumber])

        let configuration = PopupConfiguration(
            title: NSLocalizedString(
                "Confirm new number",
                comment: "Phone number selection screen confirm popup title"
            ),
            description: formattedDescription,
            buttons: [
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Add", comment: "Add button title"),
                    onTap: {
                        self.dismissPopup()
                        self.presentProgressIndicator()
                        TwilioBackendManager.sharedMgr().purchaseNumber(phoneNumber, selectedName: nil) { isPurchaseSuccessful in
                            self.dismissProgressIndicator()
                            guard isPurchaseSuccessful else {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    self.presentAlertWith(
                                        title: NSLocalizedString(
                                            "Your number wasn’t added",
                                            comment: "Phone number selection screen number not added error"
                                        ),
                                        description: .tryAginText
                                    )
                                }
                                return
                            }

                            if let account = GlacierAccountModel.getGlacierAccount() {
                                let usingMonthlyFreeAdd = account.freePhoneNumberSlotsRemaining == 1
                                    && (GlacierPhoneNumberSubscriptionPlan.activePlan.map { account.phoneNumbersEverAdded >= $0.maxPhoneNumbers } ?? false)
                                account.phoneNumbersEverAdded += 1
                                if usingMonthlyFreeAdd {
                                    account.phoneNumbersAddedThisCalendarMonth += 1
                                }
                            }

                            self.markPhoneNumberAsUnavailable(phoneNumber)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self.presentAddDisplayNamePrompt(for: phoneNumber)
                            }
                        }
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: .cancelText,
                    onTap: {
                        self.dismissPopup()
                    }
                )
            ],
            buttonsAlignment: .vertical
        )
        presentPopup(with: configuration)
    }

    /// Shown in TestFlight builds to users not on the allow list.
    @MainActor
    private func presentPilotPhoneNumbersPrompt() {
        let configuration = PopupConfiguration(
            title: NSLocalizedString(
                "Coming Soon",
                comment: "Phone number selection screen pilot restriction popup title"
            ),
            description: NSLocalizedString(
                "Acquiring numbers and calling is currently not supported in this pilot.",
                comment: "Phone number selection screen pilot restriction popup description"
            ),
            buttons: [
                PopupButton(
                    style: .primary,
                    title: .okText,
                    onTap: {
                        self.dismissPopup()
                        self.dismissSheet()

                        // Let's take user to main screen, if user was under user onboarding flow.
                        // Use ?? false so that nil (key never written on a first-ever install) is
                        // treated the same as false — both mean onboarding is not yet complete.
                        let isOnboardingCompleted = UserDefaultsService.shared.get(for: \.isUserOnboardingCompleted) ?? false
                        if !isOnboardingCompleted {
                            UserDefaultsService.shared.set(true, for: \.isUserOnboardingCompleted)
                            self.connectDNSIfSetUpDuringOnboarding()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                self.setRootScreen(.main)
                            }
                        }
                    }
                )
            ],
            buttonsAlignment: .vertical
        )
        presentPopup(with: configuration)
    }

    /// Paywall shown when the user has used all free slots included with their plan.
    @MainActor
    private func presentExtraNumberPurchasePrompt(for phoneNumber: String) {
        let descriptionText = NSLocalizedString(
            "You’ve used all the free number slots included with your plan. Add %@ for a one-time charge of %@?",
            comment: "Phone number selection screen extra number paywall popup description"
        )
        let formattedDescription = String(
            format: descriptionText,
            arguments: [phoneNumber, GlacierExtraPhoneNumberProduct.displayPrice]
        )

        let configuration = PopupConfiguration(
            title: String(
                format: NSLocalizedString(
                    "Add a new number — %@",
                    comment: "Phone number selection screen extra number paywall popup title"
                ),
                GlacierExtraPhoneNumberProduct.displayPrice
            ),
            description: formattedDescription,
            buttons: [
                PopupButton(
                    style: .primary,
                    title: String(
                        format: NSLocalizedString(
                            "Purchase for %@",
                            comment: "Phone number selection screen extra number purchase button title"
                        ),
                        GlacierExtraPhoneNumberProduct.displayPrice
                    ),
                    onTap: {
                        self.dismissPopup()
                        self.purchaseExtraNumberSlot(for: phoneNumber)
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: .cancelText,
                    onTap: {
                        self.dismissPopup()
                    }
                )
            ],
            buttonsAlignment: .vertical
        )
        presentPopup(with: configuration)
    }

    /// Runs the consumable StoreKit purchase then provisions the number on the backend.
    @MainActor
    private func purchaseExtraNumberSlot(for phoneNumber: String) {
        presentProgressIndicator()

        Task { @MainActor in
            do {
                try await SKExtraPhoneNumberPurchaseService().purchaseExtraNumber()
            } catch GlacierPlanPurchaseError.userCancelled {
                self.dismissProgressIndicator()
                return
            } catch {
                self.dismissProgressIndicator()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.presentAlertWith(
                        title: .errorText,
                        description: error.localizedDescription.isEmpty ? .tryAginText : error.localizedDescription
                    )
                }
                return
            }

            // StoreKit purchase verified — provision the number on the backend.
            TwilioBackendManager.sharedMgr().purchaseNumber(phoneNumber, selectedName: nil) { isPurchaseSuccessful in
                self.dismissProgressIndicator()
                guard isPurchaseSuccessful else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.presentAlertWith(
                            title: NSLocalizedString(
                                "Your number wasn’t added",
                                comment: "Phone number selection screen number not added error"
                            ),
                            description: .tryAginText
                        )
                    }
                    return
                }

                // Record the paid slot so future free-slot calculations remain accurate.
                if let account = GlacierAccountModel.getGlacierAccount() {
                    account.phoneNumbersEverAdded += 1
                }

                self.markPhoneNumberAsUnavailable(phoneNumber)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.presentAddDisplayNamePrompt(for: phoneNumber)
                }
            }
        }
    }

    // MARK: - Private helpers (existing)
    
    private func observeKeyboardEvents() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }
    
    @MainActor
    private func presentAddDisplayNamePrompt(for phoneNumber: String) {
        var displayName: String?
        
        let inputTextConfiguration = PopupInputTextConfiguration(
            placeholder: NSLocalizedString(
                "Display name",
                comment: "Phone number selection screen add name text input placeholder"
            ),
            onInputTextChange: { text in
                displayName = text
            }
        )
        
        let configuration = PopupConfiguration(
            title: NSLocalizedString(
                "Add display name",
                comment: "Phone number selection screen add name popup title"
            ),
            description: NSLocalizedString(
                "This name is just for you and won’t be saved after logout.",
                comment: "Phone number selection screen add name popup description"
            ),
            inputTextConfiguration: inputTextConfiguration,
            buttons: [
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Add Name", comment: "Phone number selection screen add name button title"),
                    onTap: {
                        guard let name = displayName else { return }
                        self.dismissPopup()
                        self.addDisplayName(to: phoneNumber, name: name)
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Skip", comment: "Skip button title"),
                    onTap: {
                        self.dismissPopup()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.presentAddDisplayNameSuccessPrompt()
                        }
                    }
                )
            ],
            buttonsAlignment: .vertical
        )
        presentPopup(with: configuration)
    }
    
    @MainActor
    private func addDisplayName(to phoneNumber: String, name: String) {
        TwilioBackendManager.sharedMgr().nameANumber(phoneNumber, selectedName: name) { didAddName in
            guard didAddName else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.presentAlertWith(
                        title: .errorText,
                        description: NSLocalizedString(
                            "Something went wrong while adding name to the number. Please try again.",
                            comment: "Phone number selection screen add name error"
                        )
                    )
                }
                return
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.presentAddDisplayNameSuccessPrompt()
            }
        }
    }
    
    @MainActor
    private func presentAddDisplayNameSuccessPrompt() {
        let onboardingDescription = NSLocalizedString(
            "Your phone number is ready to use.",
            comment: "Phone number selection screen add name success popup title"
        )
        let phoneScreenDescription = NSLocalizedString("Your number has been added.", comment: "Phone number selection screen number added description")
        
        let addAnotherNumberButton = PopupButton(
            style: .primary,
            title: NSLocalizedString(
                "Add Another Number",
                comment: "Phone number selection screen add another number button title"
            ),
            onTap: {
                self.dismissPopup()
            }
        )
        
        let notNowButton = PopupButton(
            style: .tertiary,
            title: NSLocalizedString("Not Now", comment: "Phone number selection screen not now button title"),
            onTap: {
                self.dismissPopup()
                self.dismissSheet()

                // Let's take user to main screen, if user was under user onboarding flow.
                // Use ?? false so that nil (key never written on a first-ever install) is
                // treated the same as false — both mean onboarding is not yet complete.
                let isOnboardingCompleted = UserDefaultsService.shared.get(for: \.isUserOnboardingCompleted) ?? false
                if !isOnboardingCompleted {
                    UserDefaultsService.shared.set(true, for: \.isUserOnboardingCompleted)
                    self.connectDNSIfSetUpDuringOnboarding()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.setRootScreen(.main)
                    }
                }
            }
        )

        let continueButton = PopupButton(
            style: .tertiary,
            title: NSLocalizedString("Continue", comment: "Continue button title"),
            onTap: {
                self.dismissPopup()
                self.dismissSheet()

                // Let's take user to main screen, if user was under user onboarding flow.
                // Use ?? false so that nil (key never written on a first-ever install) is
                // treated the same as false — both mean onboarding is not yet complete.
                let isOnboardingCompleted = UserDefaultsService.shared.get(for: \.isUserOnboardingCompleted) ?? false
                if !isOnboardingCompleted {
                    UserDefaultsService.shared.set(true, for: \.isUserOnboardingCompleted)
                    self.connectDNSIfSetUpDuringOnboarding()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.setRootScreen(.main)
                    }
                }
            }
        )
        
        let okButton = PopupButton(
            style: .primary,
            title: .okText,
            onTap: {
                self.dismissPopup()
                self.dismissSheet()
            }
        )
        
        let configuration = PopupConfiguration(
            title: .successText,
            description: isPresentedFromPhoneScreen ? phoneScreenDescription : onboardingDescription,
            buttons: isPresentedFromPhoneScreen ? [okButton] : hasAddedMaxAllowedPhoneNumbers ? [continueButton] : [addAnotherNumberButton, notNowButton],
            buttonsAlignment: .vertical
        )
        
        presentPopup(with: configuration)
        
        NotificationCenter.default.post(
            name: .newPhoneNumberAdded,
            object: nil,
            userInfo: nil
        )
    }
    
    private func filterPhoneNumbers(with searchText: String) {
        if searchText.isEmpty {
            glacierPhoneNumbersFiltered = glacierPhoneNumbersAll
        } else {
            glacierPhoneNumbersFiltered = glacierPhoneNumbersAll.filter { $0.number.contains(searchText) }
        }
    }
    
    private func markPhoneNumberAsUnavailable(_ phoneNumber: String) {
        guard let index = glacierPhoneNumbersAll.firstIndex(where: { $0.number == phoneNumber} ) else {
            return
        }
        glacierPhoneNumbersAll.remove(at: index)
        glacierPhoneNumbersFiltered.removeAll()
        glacierPhoneNumbersFiltered.append(contentsOf: glacierPhoneNumbersAll)
    }
    
    @MainActor
    @objc private func keyboardWillShow(_ notification: Notification) {
        Task { @MainActor in
            let isPresentingPopup = await isPresentingPopup()
            guard !isPresentingPopup else { return }
            filterPhoneNumbers(with: searchText)
            
            guard isPresentedFromPhoneScreen else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                isKeyboardVisible = true
            }
        }
    }

    @MainActor
    @objc private func keyboardWillHide(_ notification: Notification) {
        Task { @MainActor in
            let isPresentingPopup = await isPresentingPopup()
            guard !isPresentingPopup else { return }

            guard isKeyboardVisible else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                isKeyboardVisible = false
            }
        }
    }
}

extension PhoneNumberSelectionVM: TwilioAccountDelegateProtocol {
    func availableNumbersUpdated(_ availableNumbers: [GlacierPhoneNumber]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.cancelLookupTimeout()
            self.dismissProgressIndicator()
            if !self.isPerformingSearch {
                self.glacierPhoneNumbersAll = availableNumbers
            }
            self.glacierPhoneNumbersFiltered = availableNumbers
            self.isLoadingPhoneNumbers = false
        }
    }

    func availableNumbersLookupFailed(_ failure: PhoneNumberLookupFailure) {
        Task { @MainActor [weak self] in
            self?.finishLookup(with: failure)
        }
    }
}
