//
//  ManagePhoneNumbersViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 27/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import UIKit
import Foundation

/**
 ManagePhoneNumbersViewModel defines requirements for ManagePhoneNumbersScreen view models
 */
protocol ManagePhoneNumbersViewModel: GlacierViewModelWithRootCoordinator {
    var phoneNumbers: [PhoneAccountModel] { get }
    var activePhoneNumberPlan: GlacierPhoneNumberSubscriptionPlan? { get }
    var canUpgradeToHigherPhoneNumberPlan: Bool { get }
    
    init(rootCoordinator: any GlacierRootCoordinator)
    
    func initialize()
    func getUserPhoneNumbers()
    func presentPhoneNumberSelectionView()
    func presentPhoneNumberPlanPurchaseView()
    
    @MainActor
    func presentEditPhoneNumberNamePrompt(for phoneNumber: PhoneAccountModel)
    
    @MainActor
    func presentBurnNumberConfirmationPrompt(for phoneNumber: PhoneAccountModel)
    func copyPhoneNumber(_ phoneNumber: PhoneAccountModel)
}

/**
 ManagePhoneNumbersVM defines data/state and business logic for ManagePhoneNumbersScreen
 */
final class ManagePhoneNumbersVM: ManagePhoneNumbersViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var phoneNumbers: [PhoneAccountModel] = []
    
    @Published var activePhoneNumberPlan: GlacierPhoneNumberSubscriptionPlan? {
        didSet {
            guard let activePlan = activePhoneNumberPlan else {
                canUpgradeToHigherPhoneNumberPlan = false
                return
            }
            canUpgradeToHigherPhoneNumberPlan = activePlan != .fiveNumbers
        }
    }
    
    @Published var canUpgradeToHigherPhoneNumberPlan: Bool = false
    
    let rootCoordinator: any GlacierRootCoordinator
    
    // MARK: - Intializer
    
    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public methods
    
    func initialize() {
        registerForNotifications()
        activePhoneNumberPlan = GlacierPhoneNumberSubscriptionPlan.activePlan
    }
    
    func getUserPhoneNumbers() {
        phoneNumbers.removeAll()
        phoneNumbers = PhoneAccountModel.allAccountsSortedByDisplayName()
    }
    
    func presentPhoneNumberSelectionView() {
        presentSheet(.phoneNumberSelection(true))
    }
    
    func presentPhoneNumberPlanPurchaseView() {
        presentSheet(.phoneNumberPlanPurchase)
    }
    
    @MainActor
    func presentEditPhoneNumberNamePrompt(for phoneNumber: PhoneAccountModel) {
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
                "Edit name",
                comment: "Manage phone numbers screen edit name title"
            ),
            description: NSLocalizedString(
                "This name is just for you and won’t be saved after logout.",
                comment: "Phone number selection screen add name popup description"
            ),
            inputTextConfiguration: inputTextConfiguration,
            buttons: [
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Update", comment: "Update button title"),
                    onTap: {
                        guard let number = phoneNumber.grdbRecord?.phoneNumber, let name = displayName else { return }
                        self.dismissPopup()
                        self.editDisplayName(for: number, name: name)
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                    onTap: {
                        self.dismissPopup()
                    }
                )
            ],
            buttonsAlignment: .vertical
        )
        presentPopup(with: configuration)
    }
    
    func presentBurnNumberConfirmationPrompt(for phoneNumber: PhoneAccountModel) {
        guard let number = phoneNumber.grdbRecord?.phoneNumber else { return }

        // Tell the user whether adding a replacement number later will cost money.
        let freeSlots = GlacierAccountModel.getGlacierAccount()?.freePhoneNumberSlotsRemaining ?? 0
        let description: String
        if freeSlots > 0 {
            description = String(
                format: NSLocalizedString(
                    "%@ will be permanently removed. You can select a replacement number at no additional charge.",
                    comment: "Manage phone number screen burn number prompt description — free replacement available"
                ),
                number
            )
        } else {
            description = String(
                format: NSLocalizedString(
                    "%@ will be permanently removed. To add a new number this month, a one-time %@ fee will apply.",
                    comment: "Manage phone number screen burn number prompt description — replacement requires payment"
                ),
                number, GlacierExtraPhoneNumberProduct.displayPrice
            )
        }

        let configuration = PopupConfiguration(
            title: NSLocalizedString(
                "Burn this number",
                comment: "Manage phone numbers screen burn number prompt title"
            ),
            description: description,
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Burn number", comment: "Manage phone number screen burn phone number menu item"),
                    titleColor: .ember,
                    onTap: {
                        self.dismissPopup()
                        self.burnNumber(number)
                    }
                ),
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                    onTap: {
                        self.dismissPopup()
                    }
                )
            ],
            buttonsAlignment: .vertical
        )
        presentPopup(with: configuration)

    }
    
    func copyPhoneNumber(_ phoneNumber: PhoneAccountModel) {
        UIPasteboard.general.string = phoneNumber.grdbRecord?.phoneNumber
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
    }
    
    @MainActor
    private func editDisplayName(for phoneNumber: String, name: String) {
        TwilioBackendManager.sharedMgr().nameANumber(phoneNumber, selectedName: name) { didEditName in
            guard didEditName else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.presentAlertWith(
                        title: .errorText,
                        description: NSLocalizedString(
                            "Something went wrong while updating name for the number. Please try again.",
                            comment: "Manage phone numbers screen update name error"
                        )
                    )
                }
                return
            }
            
            DispatchQueue.main.async {
                self.getUserPhoneNumbers()
                
                NotificationCenter.default.post(
                    name: .userPhoneNumberDetailsUpdated,
                    object: nil,
                    userInfo: nil
                )
            }
        }
    }
    
    @MainActor
    private func burnNumber(_ phoneNumber: String) {
        presentProgressIndicator()
        TwilioBackendManager.sharedMgr().releaseNumber(phoneNumber) { didReleaseNumber in
            DispatchQueue.main.async {
                self.dismissProgressIndicator()
            }
            
            guard didReleaseNumber else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.presentAlertWith(
                        title: .errorText,
                        description: NSLocalizedString(
                            "Something went wrong while burning number. Please try again.",
                            comment: "Manage phone numbers screen burn number error"
                        )
                    )
                }
                return
            }
            
            DispatchQueue.main.async {
                self.getUserPhoneNumbers()
                
                NotificationCenter.default.post(
                    name: .userPhoneNumberDetailsUpdated,
                    object: nil,
                    userInfo: nil
                )
            }
        }
    }
    
    @MainActor
    @objc private func onPhoneNumberPlanPurchaseSuccessful() {
        DispatchQueue.main.async {
            self.activePhoneNumberPlan = GlacierPhoneNumberSubscriptionPlan.activePlan
            self.getUserPhoneNumbers()
            self.dismissSheet()
        }
    }
    
    @MainActor
    @objc private func onNewPhoneNumberAdded() {
        DispatchQueue.main.async {
            self.getUserPhoneNumbers()
        }
    }
}
