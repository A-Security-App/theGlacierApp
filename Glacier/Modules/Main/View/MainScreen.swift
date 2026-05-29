//
//  MainScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 MainScreen presents primary user interface which is presented after successful,
 - User authentication
 - User onboarding
 
 It presents a dynamic floating tab bar (with Home, Phone, Contacts, History tabs), allowing user to navigate to the
 desired screen.
 */
struct MainScreen<ViewModel: MainViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var rootCoordinator: GlacierAppRootCoordinator
    
    @StateObject private var viewModel: ViewModel
    
    @StateObject private var homeVM: HomeVM
    @StateObject private var phoneVM: PhoneVM
    @StateObject private var contactsVM: ContactsVM
    @StateObject private var historyVM: HistoryVM
    
    @StateObject private var phoneCallVM: PhoneCallVM
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator, viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        
        self._homeVM = StateObject(wrappedValue: HomeVM(rootCoordinator: rootCoordinator))
        self._phoneVM = StateObject(wrappedValue: PhoneVM(rootCoordinator: rootCoordinator))
        self._contactsVM = StateObject(wrappedValue: ContactsVM(rootCoordinator: rootCoordinator))
        self._historyVM = StateObject(wrappedValue: HistoryVM(rootCoordinator: rootCoordinator))
        
        self._phoneCallVM = StateObject(wrappedValue: PhoneCallVM(rootCoordinator: rootCoordinator))
        
        // Scroll view bouncing is disabled by the user authentication sliding cards
        // We have to enabled it back, since we are done with the user authentication flow
        UIScrollView.appearance().bounces = true
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack(alignment: .bottom) {
            GlacierBackground()
                .ignoresSafeArea()
            
            VStack(alignment: .center, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    HeaderView(
                        titleText: viewModel.headerViewTitle,
                        shouldShowPhoneNumberLink: viewModel.hasPhoneNumberSubscription && viewModel.activePhoneNumber != nil && viewModel.selectedTab != .home,
                        activePhoneNumber: viewModel.activePhoneNumber,
                        height: 70,
                        onPhoneNumberTapped: {
                            viewModel.setPhoneNumbersMenuVisibility(true)
                        },
                        onSettingsButtonTapped: {
                            viewModel.presentSettingsScreen()
                        }
                    )
                    .padding(.top, 52)
                }
                
                Group {
                    switch viewModel.selectedTab {
                    case .home: homeScreen
                    case .phone: phoneScreen
                    case .contacts: contactsScreen
                    case .history: historyScreen
                    }
                }
            }
            .ignoresSafeArea()
            
            if viewModel.hasPhoneNumberSubscription, viewModel.shouldShowPhoneNumberMenu {
                VStack(alignment: .center, spacing: 0) {
                    phoneNumberMenuView
                        .padding(.top, 54)
                    
                    Spacer()
                }
                .ignoresSafeArea()
            }
            
            FloatingTabBarView(
                tabs: $viewModel.tabs,
                selectedTab: $viewModel.selectedTab,
                hasNewVM: $viewModel.hasUnreadVoiceMail
            )
            .frame(height: 56)
            .padding(.bottom, 24)
        }
        .ignoresSafeArea()
        .onFirstAppear {
            self.viewModel.phoneCallVM = phoneCallVM
            self.viewModel.requestNotificationPermissionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hidePhoneNumberMenuView)) { _ in
            viewModel.setPhoneNumbersMenuVisibility(false)
        }
    }
    
    // MARK: - Private properties
    
    @ViewBuilder
    private var homeScreen: some View {
        HomeScreen(viewModel: homeVM)
    }
    
    @ViewBuilder
    private var phoneScreen: some View {
        PhoneScreen(viewModel: phoneVM)
    }
    
    @ViewBuilder
    private var contactsScreen: some View {
        ContactsScreen(viewModel: contactsVM)
    }
    
    @ViewBuilder
    private var historyScreen: some View {
        HistoryScreen(viewModel: historyVM)
    }
    
    @ViewBuilder
    private var phoneNumberMenuView: some View {
        let viewModel = PhoneNumberMenuVM(delegate: self)
        PhoneNumberMenuView(viewModel: viewModel)
    }
}

// MARK: - PhoneNumberMenuViewModelDelegate delegate methods

extension MainScreen: PhoneNumberMenuViewModelDelegate {
    func presentPhoneNumberSelectionLimitationPrompt() {
        viewModel.presentPhoneNumberSelectionLimitationPrompt()
    }
    
    func presentPhoneNumberSelectionView() {
        viewModel.presentPhoneNumberSelectionView()
    }
    
    func presentPhoneNumberPlanPurchaseView() {
        viewModel.presentPhoneNumberPlanPurchaseView()
    }
    
    func presentManagePhoneNumbersView() {
        viewModel.presentManagePhoneNumbersView()
    }
    
    func setActivePhoneNumber(_ phoneNumber: PhoneAccountModel) {
        viewModel.activePhoneNumber = phoneNumber
    }
}
