//
//  MainViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 MainViewModel defines requirements for main screen view models.
 */
protocol MainViewModel: GlacierViewModelWithRootCoordinator {
    var tabs: [FloatingTab] { get set }
    var selectedTab: FloatingTab { get set }
    var hasUnreadVoiceMail: Bool { get set }
    var headerViewTitle: String? { get }
    var shouldShowPhoneNumberMenu: Bool { get set }
    
    var hasPhoneNumberSubscription: Bool { get }
    var phoneNumbers: [PhoneAccountModel] { get }
    var activePhoneNumber: PhoneAccountModel? { get set }
    
    var phoneCallVM: PhoneCallVM? { get set }
    
    init(rootCoordinator: any GlacierRootCoordinator)
    
    func setPhoneNumbersMenuVisibility(_ isVisible: Bool)
    func presentPhoneNumberSelectionLimitationPrompt()
    func presentPhoneNumberSelectionView()
    func presentPhoneNumberPlanPurchaseView()
    func presentManagePhoneNumbersView()
    func presentSettingsScreen()
}

/**
 MainViewModel defines data/state and business logic for main screen.
 */
final class MainVM: MainViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var tabs: [FloatingTab] = []
    @Published var selectedTab: FloatingTab = .home {
        didSet {
            setPhoneNumbersMenuVisibility(false)
            updateHeaderViewTitle()
        }
    }
    @Published var hasUnreadVoiceMail: Bool = false
    
    @Published var headerViewTitle: String?
    @Published var hasPhoneNumberSubscription: Bool = false
    @Published var phoneNumbers: [PhoneAccountModel] = []
    @Published var activePhoneNumber: PhoneAccountModel? {
        didSet {
            if shouldShowPhoneNumberMenu {
                setPhoneNumbersMenuVisibility(false)
            }
        }
    }
    
    @Published var shouldShowPhoneNumberMenu: Bool = false
    var phoneCallVM: PhoneCallVM?
    
    let rootCoordinator: any GlacierRootCoordinator
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        initializeBasedOnUserSubscriptionStatus()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public methods
    
    private func initializeBasedOnUserSubscriptionStatus() {
        guard let userAccount = GlacierAccountModel.getGlacierAccount() else {
            // No account record at all — genuine unrecoverable auth state.
            // Route back to login. (Subscription lapse is handled separately via
            // .glacierBaseSubscriptionLapsed, not here, to avoid the "session expired"
            // false positive caused by the refreshBackendSubscription race at launch.)
            NotificationCenter.default.post(
                name: .userAuthenticationVerified,
                object: nil,
                userInfo: [GlacierNotificationProperties.isAuthSessionValid: false]
            )
            return
        }

        // Do NOT check hasActiveSubscription here. GlacierAppRootScreen navigates to .main
        // only after setting hasActiveSubscription = true (benefit of doubt), and
        // resolveSubscriptionStatus() runs concurrently and resets the value to false during
        // its StoreKit/backend checks. Reading the value here races against that reset and
        // causes false-positive lapse paywall flashes on cold launch. The authoritative lapse
        // check is in GlacierAppRootScreen via resolveSubscriptionStatus() (requires live
        // StoreKit + backend) and refreshBackendSubscription() (foreground transitions).

        hasUnreadVoiceMail = TwilioBackendManager.sharedMgr().hasNewVM
        TwilioBackendManager.sharedMgr().setPhoneDelegate(self)
        
        registerForNotifications()
        
        hasPhoneNumberSubscription = userAccount.hasActivePhoneNumberSubscription
        setTabs(userHasPhoneLineSubscription: userAccount.hasActivePhoneNumberSubscription)
        
        guard userAccount.hasActivePhoneNumberSubscription else {
            return
        }
        getUserPhoneNumbers()
        queryForNewVoiceMails()
    }
    
    func setPhoneNumbersMenuVisibility(_ isVisible: Bool) {
        withAnimation(.easeIn(duration: 0.2)) {
            self.shouldShowPhoneNumberMenu = isVisible
        }
    }
    
    func presentPhoneNumberSelectionLimitationPrompt() {
        presentAlertWith(
            title: nil,
            description: "You're using a test version of the app, so you can only add 1 phone number."
        )
    }
    
    func presentPhoneNumberSelectionView() {
        if shouldShowPhoneNumberMenu {
            setPhoneNumbersMenuVisibility(false)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.presentSheet(.phoneNumberSelection(true))
        }
    }
    
    func presentPhoneNumberPlanPurchaseView() {
        if shouldShowPhoneNumberMenu {
            setPhoneNumbersMenuVisibility(false)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.presentSheet(.phoneNumberPlanPurchase)
        }
    }
    
    func presentManagePhoneNumbersView() {
        if shouldShowPhoneNumberMenu {
            setPhoneNumbersMenuVisibility(false)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.presentScreen(.managePhoneNumbers)
        }
    }
    
    func presentSettingsScreen() {
        presentScreen(.settings)
    }
    
    // MARK: - Private methods
    
    private func registerForNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPhoneNumberPlanPurchaseSuccessful),
            name: .phoneNumberPlanPurchaseSuccessful,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onNewPhoneNumberAdded),
            name: .newPhoneNumberAdded,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onUserPhoneNumberDetailsUpdated),
            name: .userPhoneNumberDetailsUpdated,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onStartPhoneCallNotification(_:)),
            name: .startPhoneCall,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPhoneSubscriptionStateDidChange),
            name: .phoneSubscriptionStateDidChange,
            object: nil
        )

    }
    
    @objc private func onStartPhoneCallNotification(_ notification: Notification) {
        guard let phoneVM = phoneCallVM,
              let userInfo = notification.userInfo,
              let phoneNumber = userInfo[GlacierNotificationProperties.phoneNumber] as? String,
              let personName = userInfo[GlacierNotificationProperties.personName] as? String else {
            return
        }

        var phoneContact: PhoneContact? = ContactsManager.shared.matchContact(for: phoneNumber)
        if phoneContact == nil {
            phoneContact = PhoneContact(
                id: UUID().uuidString,
                name: personName,
                initials: GlacierImages.stringInitials(withMaxCharacters: personName, maxCharacters: 2) ?? "",
                phoneNumber: phoneNumber
            )
        }

        guard let contact = phoneContact else {
            return
        }

        let isIncoming = userInfo[GlacierNotificationProperties.isIncomingCall] as? Bool ?? false
        phoneVM.setIsIncomingCall(isIncoming)
        phoneVM.setPhoneContact(contact)
        presentScreen(.phoneCall(phoneVM))
    }
    
    private func setTabs(userHasPhoneLineSubscription: Bool) {
        guard userHasPhoneLineSubscription else {
            tabs = [.home, .phone]
            selectedTab = .home
            return
        }
        tabs = [.home, .phone, .contacts, .history]
        selectedTab = .home
    }
    
    private func getUserPhoneNumbers() {
        phoneNumbers.removeAll()
        phoneNumbers.append(contentsOf: PhoneAccountModel.allAccountsSortedByDisplayName())
        
        guard !phoneNumbers.isEmpty else {
            activePhoneNumber = nil
            UserDefaultsService.shared.set("", for: \.activePhoneNumber)
            TwilioBackendManager.sharedMgr().selectedAccount = nil
            return
        }
        
        if let activeNumber: String = UserDefaultsService.shared.get(for: \.activePhoneNumber),
           let number = phoneNumbers.first(where: { $0.grdbRecord?.phoneNumber == activeNumber }) {
            activePhoneNumber = number
        } else {
            guard let firstNumber = phoneNumbers.first else { return }
            UserDefaultsService.shared.set(firstNumber.grdbRecord?.phoneNumber, for: \.activePhoneNumber)
            activePhoneNumber = firstNumber
        }
        
        // Let's set selected phone number as TwilioBackendManager selectedAccount
        TwilioBackendManager.sharedMgr().selectedAccount = activePhoneNumber
    }
    
    private func queryForNewVoiceMails() {
        TwilioBackendManager.sharedMgr().queryForVMInfo { [weak self] _ in
            guard let strongSelf = self else {
                return
            }
            
            DispatchQueue.main.async {
                strongSelf.hasUnreadVoiceMail = TwilioBackendManager.sharedMgr().hasNewVM
            }
        }
    }
    
    private func updateHeaderViewTitle() {
        switch selectedTab {
        case .home: headerViewTitle = NSLocalizedString("Glacier", comment: "Glacier text")
        case .phone: headerViewTitle = NSLocalizedString("Phone", comment: "Floating tab bar phone tab title")
        case .contacts: headerViewTitle = NSLocalizedString("Contacts", comment: "Floating tab bar contacts tab title")
        case .history: headerViewTitle = NSLocalizedString("History", comment: "Floating tab bar history tab title")
        }
    }
    
    private func giveHapticFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
    
    @MainActor
    @objc private func onPhoneNumberPlanPurchaseSuccessful() {
        DispatchQueue.main.async {
            self.dismissSheet()
            
            self.hasPhoneNumberSubscription = true
            self.setTabs(userHasPhoneLineSubscription: true)
        }
    }
    
    /// Re-syncs phone subscription UI state after `applyBackendSubscription` writes the
    /// reconciled value. Handles both the launch race (MainVM may initialize before
    /// resolveSubscriptionStatus completes) and foreground-refresh transitions.
    @MainActor
    @objc private func onPhoneSubscriptionStateDidChange() {
        guard let userAccountModel = GlacierAccountModel.getGlacierAccount() else {
            hasPhoneNumberSubscription = false
            setTabs(userHasPhoneLineSubscription: false)
            return
        }
        let hasSubscription = userAccountModel.hasActivePhoneNumberSubscription
        guard hasSubscription != hasPhoneNumberSubscription else { return }
        hasPhoneNumberSubscription = hasSubscription
        setTabs(userHasPhoneLineSubscription: hasSubscription)
        if hasSubscription {
            getUserPhoneNumbers()
            queryForNewVoiceMails()
        }
    }
    
    @MainActor
    @objc private func onNewPhoneNumberAdded() {
        DispatchQueue.main.async {
            self.getUserPhoneNumbers()
        }
    }
    
    @MainActor
    @objc private func onUserPhoneNumberDetailsUpdated() {
        DispatchQueue.main.async {
            self.getUserPhoneNumbers()
        }
    }
}

// MARK: - TwilioAccountDelegateProtocol delegate methods

extension MainVM: TwilioAccountDelegateProtocol {
    
    // It is called, when new phone number is selected via PhoneNumberMenuView
    public func setSelectedAccount(_ account: PhoneAccountModel?) {
        activePhoneNumber = account
    }

    // It is called, when TwilioBackendManager is done with loading/processing VoicemailRecord
    public func voicemailUpdated() {
        DispatchQueue.main.async {
            self.hasUnreadVoiceMail = TwilioBackendManager.sharedMgr().hasNewVM
        }
    }
}
