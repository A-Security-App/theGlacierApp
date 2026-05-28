//
//  ContactsScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 28/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

struct ContactsScreen<ViewModel: ContactsViewModel & ObservableObject>: View, PhoneNumberMenuCoordinator {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @ObservedObject private var viewModel: ViewModel
    
    @State private var shouldShowSearchBar: Bool = false
    @State private var isSearchBarFocused: Bool = false
    
    @State private var isAppearing = false
    @State private var secondaryTextColor: Color?
    @State private var avatarForegroundColor: Color?
    @State private var avatarBackgroundColor: Color?
    @State private var backgroundColor: Color?
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
            
            Group {
                if viewModel.hasContactsAccessPermission, !viewModel.allContacts.isEmpty {
                    contactsListView
                        .onTapGesture {
                            dismissKeyboard()
                            hideSearchBarIfNeeded()
                        }
                    
                } else if viewModel.hasContactsAccessPermission, viewModel.allContacts.isEmpty, viewModel.didLoadContactDetails {
                    GlacierLabel(
                        text: NSLocalizedString("No contacts", comment: "Contacts screen no contacts"),
                        font: .bodyRegular
                    )
                    .offset(y: -75)
                    
                } else if !viewModel.hasContactsAccessPermission {
                    contactsAccessInfoView
                }
            }
            .padding(.top, 4)
        }
        .onAppear {
            isAppearing = true
            shouldShowSearchBar = !viewModel.searchText.isEmpty
            setupColors(for: glacierColorScheme.activeScheme)
            
            viewModel.getContactDetails()
        }
        .onDisappear {
            isAppearing = false
        }
        .onChange(of: glacierColorScheme.activeScheme) { newScheme in
            guard isAppearing else { return }
            setupColors(for: newScheme)
        }
        .onReceive(NotificationCenter.default.publisher(for: .didTapOnFloatingTabBarSearchButton)) { _ in
            withAnimation(.easeIn(duration: 0.2)) {
                shouldShowSearchBar = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isSearchBarFocused = true
                }
            }
        }
    }
    
    // MARK: - Screen elements
    
    private var contactsListView: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
            
            VStack(alignment: .leading, spacing: 4) {
                if shouldShowSearchBar {
                    GlacierSearchBar(
                        searchText: $viewModel.searchText,
                        placeholder: NSLocalizedString("Search contacts", comment: "Contacts screen search bar placeholder text"),
                        height: 50,
                        isFocused: $isSearchBarFocused,
                        onSubmit: {
                            // This is called when user taps on keyboard `return` key
                            dismissKeyboard()
                            hideSearchBarIfNeeded()
                        },
                        onTextCleared: {
                            // This is called when user taps on cross button to clear search text
                            dismissKeyboard()
                            hideSearchBarIfNeeded()
                        }
                    )
                    .padding(.top, 12)
                }
                
                if viewModel.filteredContacts.isEmpty {
                    VStack(alignment: .center, spacing: 12) {
                        GlacierLabel(
                            text: NSLocalizedString("No Results", comment: "Contacts screen no search result"),
                            font: .bodyThick
                        )
                        .frame(maxWidth:.infinity, alignment: .center)
                        
                        if let descriptionText = viewModel.noSearchResultDescription {
                            GlacierLabel(
                                text: descriptionText,
                                font: .bodyRegular,
                                customTextColor: $secondaryTextColor
                            )
                            .frame(maxWidth:.infinity, alignment: .center)
                        }
                        
                        Spacer()
                    }
                    .padding(.top, 82)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(viewModel.filteredContacts, id: \.id) { contact in
                                ContactDetailsView(
                                    contact: contact,
                                    backgroundColor: $backgroundColor,
                                    secondaryTextColor: $secondaryTextColor,
                                    avatarForegroundColor: $avatarForegroundColor,
                                    avatarBackgroundColor: $avatarBackgroundColor
                                ) {
                                    // This is called when user taps on the call button for contact
                                    dismissKeyboard()
                                    hideSearchBarIfNeeded()
                                    
                                    viewModel.startCall(with: contact)
                                }
                                .onTapGesture {
                                    dismissKeyboard()
                                    hideSearchBarIfNeeded()
                                }
                            }
                        }
                        .padding(.top, 12)
                        
                        // This bottom padding is required to bypass floating tab bar blur area so that
                        // content are fully visible
                        .padding(.bottom, 100)
                    }
                    
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
        }
    }
    
    private var contactsAccessInfoView: some View {
        VStack(alignment: .center, spacing: 24) {
            Button(
                action: {
                    viewModel.requestContactsAccessPermission()
                },
                label: {
                    GlacierViewContainer(cornerRadius: 22, padding: 18, darkColor: .grey70, lightColor: .grey30) {
                        GlacierImage(
                            name: .constant("plus-icon"),
                            width: 23,
                            height: 23,
                            shouldAdaptToColorSchemeChange: true
                        )
                    }
                }
            )
            
            GlacierLabel(
                text: NSLocalizedString(
                    "Add contacts by allowing Glacier access",
                    comment: "Contacts screen access permission request"
                ),
                font: .bodyRegular
            )
        }
        .offset(y: -75)
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        backgroundColor = scheme == .dark ? .grey95 : .grey10
        secondaryTextColor = scheme == .dark ? .grey40 : .grey60
        avatarBackgroundColor = scheme == .dark ? .grey20 : .grey90
        avatarForegroundColor = scheme == .dark ? .black : .white
    }
    
    private func dismissKeyboard() {
        hidePhoneNumberMenu()
        
        UIApplication.shared.dismissKeyboard()
        isSearchBarFocused = false
    }
    
    private func hideSearchBarIfNeeded() {
        guard viewModel.searchText.isEmpty else { return }
        withAnimation(.easeIn(duration: 0.2)) {
            shouldShowSearchBar = false
        }
    }
}
