//
//  ContactsViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 28/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import UIKit
import Foundation
import Contacts

/**
 ContactsViewModel defines requirements for ContactsScreen view models
 */
protocol ContactsViewModel: GlacierViewModelWithRootCoordinator {
    
    var hasContactsAccessPermission: Bool { get }
    var allContacts: [PhoneContact] { get }
    var filteredContacts: [PhoneContact] { get }
    var searchText: String { get set }
    var noSearchResultDescription: String? { get }
    var didLoadContactDetails: Bool { get }
    
    init(rootCoordinator: any GlacierRootCoordinator)
    
    func requestContactsAccessPermission()
    func getContactDetails()
    func startCall(with contact: PhoneContact)
}

/**
 ContactsVM defines data/state and business logic for ContactsScreen
 */
final class ContactsVM: ContactsViewModel, ObservableObject, PhoneNumberMenuCoordinator {
    
    // MARK: - Public properties
    
    @Published private(set) var hasContactsAccessPermission: Bool = false
    @Published private(set) var filteredContacts: [PhoneContact] = []
    
    @Published var searchText: String = "" {
        didSet {
            filterContacts(with: searchText)
        }
    }
    
    @Published var noSearchResultDescription: String?
    
    private(set) var allContacts: [PhoneContact] = []
    private(set) var didLoadContactDetails: Bool = false
    let rootCoordinator: any GlacierRootCoordinator
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        
        hasContactsAccessPermission = UserPermissionManager.shared.hasContactsPermission
    }
    
    // MARK: - Public methods
    
    func requestContactsAccessPermission() {
        UserPermissionManager.shared.requestContactsPermission { granted in
            guard granted else {
                self.suggestUserToChangeAppSettings()
                return
            }
            self.hasContactsAccessPermission = true
            self.getContactDetails()
        }
    }
    
    func getContactDetails() {
        UserPermissionManager.shared.requestContactsPermission { hasPermission in
            self.hasContactsAccessPermission = hasPermission
            
            guard self.hasContactsAccessPermission else {
                self.didLoadContactDetails = false
                return
            }
            
            guard self.allContacts.isEmpty else {
                self.didLoadContactDetails = true
                return
            }
            
            TwilioBackendManager.sharedMgr().fetchContacts { _ in
                let contacts = TwilioBackendManager.sharedMgr().contacts
                guard !contacts.isEmpty else {
                    DispatchQueue.main.async {
                        self.didLoadContactDetails = true
                    }
                    return
                }
                
                DispatchQueue.main.async {
                    self.allContacts.removeAll()
                    self.allContacts.append(contentsOf: contacts.sorted(by: { $0.name < $1.name }))
                    
                    self.filteredContacts.removeAll()
                    self.filteredContacts.append(contentsOf: self.allContacts)
                    
                    self.didLoadContactDetails = true
                }
            }
        }
    }
    
    func startCall(with contact: PhoneContact) {
        hidePhoneNumberMenu()
        let userPhoneNumbers = TwilioBackendManager.sharedMgr().getExistingAccounts()
        guard !userPhoneNumbers.isEmpty else {
            presentAlertForAddingPhoneNumber()
            return
        }
        presentConfirmationPromptForStartingCall(with: contact)
    }
    
    private func presentAlertForAddingPhoneNumber() {
        let popupConfiguration = PopupConfiguration(
            title: nil,
            description: NSLocalizedString(
                "Looks like you haven’t added a phone number yet. Add one to start making calls.",
                comment: "Contacts screen add phone number alert text"
            ),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: .cancelText,
                    onTap: {
                        self.dismissPopup()
                    }
                ),
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Add number", comment: "Add phone number button title"),
                    onTap: {
                        self.dismissPopup()
                        self.presentSheet(.phoneNumberSelection(true))
                })
            ]
        )
        presentPopup(with: popupConfiguration)
    }
    
    private func presentConfirmationPromptForStartingCall(with contact: PhoneContact) {
        guard !contact.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let popupConfiguration = PopupConfiguration(
            title: nil,
            description: NSLocalizedString("Start call?", comment: "Phone screen call confirmation prompt description"),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: .cancelText,
                    onTap: {
                        self.dismissPopup()
                    }
                ),
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Call", comment: "Call button title"),
                    onTap: {
                        // Let's send notification for call initialization
                        NotificationCenter.default.post(
                            name: .startPhoneCall,
                            object: nil,
                            userInfo: [
                                GlacierNotificationProperties.phoneNumber: contact.phoneNumber,
                                GlacierNotificationProperties.personName: contact.name
                            ]
                        )
                        
                        self.dismissPopup()
                    }
                )
            ],
            buttonsAlignment: .horizontal
        )
        presentPopup(with: popupConfiguration)
    }
    
    // MARK: - Private methods
    
    private func suggestUserToChangeAppSettings() {
        let popupConfiguration = PopupConfiguration(
            description: NSLocalizedString(
                "To help you easily connect with people, please allow access to your contacts by going to, \n\n→ Settings \n→ Apps \n→ Glacier \n→ Contacts",
                comment: "Contacts screen change settings suggestion"
            ),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: .cancelText,
                    onTap: {
                        self.dismissPopup()
                    }
                ),
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Open Settings", comment: "Open settings button title"),
                    onTap: {
                        self.dismissPopup()
                        UIApplication.shared.openURL(UIApplication.openSettingsURLString)
                    }
                )
            ]
        )
        presentPopup(with: popupConfiguration)
    }
    
    private func filterContacts(with searchText: String) {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.filteredContacts.removeAll()
            self.filteredContacts.append(contentsOf: self.allContacts)
            return
        }
        
        filteredContacts.removeAll()
        filteredContacts = allContacts.filter {
            $0.name.lowercased().contains(searchText.lowercased()) ||
            $0.phoneNumber.components(separatedBy: CharacterSet.decimalDigits.inverted).joined().contains(searchText)
        }
        
        let text = NSLocalizedString(
            "There were no results for '%@'. Try a new search.",
            comment: "Contacts screen not search result description"
        )
        noSearchResultDescription = String(format: text, arguments: [searchText])
    }
}
