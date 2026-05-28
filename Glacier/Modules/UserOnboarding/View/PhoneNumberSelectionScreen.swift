//
//  PhoneNumberSelectionScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 PhoneNumberSelectionScreen presents list of available Glacier phone numbers that users can add to their profile
 for secured calls and messaging.
 */
struct PhoneNumberSelectionScreen<ViewModel: PhoneNumberSelectionViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @SwiftUI.Environment(\.presentationMode) private var presentationMode
    @StateObject private var viewModel: ViewModel
    
    @FocusState private var isSearchFieldFocused: Bool
    
    private var noSearchResultsDescription: String {
        let text = NSLocalizedString("There were no results for '%@'. Try a new search.", comment: "Phone number selection screen no results description")
        return String(format: text, arguments: [viewModel.searchText])
    }
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        NavigationStack {
            ZStack {
                GlacierBackground()
                    .ignoresSafeArea()
                    .onTapGesture {
                        UIApplication.shared.dismissKeyboard()
                    }
                
                VStack(alignment: .center, spacing: 4) {
                    VStack(alignment: .leading, spacing: 16) {
                        
                        if !viewModel.isPresentedFromPhoneScreen {
                            GlacierLineSeparator(lineThickness: 1)
                        }
                        
                            GlacierSearchBar(
                                searchText: $viewModel.searchText,
                                placeholder: NSLocalizedString(
                                    "Search area code or number",
                                    comment: "Phone number selection screen search bar placeholder text"
                                ),
                                height: 50,
                                keyboardType: .phonePad,
                                onSearchTapped: {
                                    viewModel.searchForAvailableNumbers()
                                }
                            )
                        .padding(.horizontal, 16)
                        
                        GlacierLineSeparator(lineThickness: 1)
                    }
                    .padding(.top, viewModel.isPresentedFromPhoneScreen ? 6 : 0)
                    .padding(.horizontal, 0)
                    
                    ZStack {
                        if !viewModel.isLoadingPhoneNumbers, !viewModel.searchText.isEmpty, viewModel.glacierPhoneNumbersFiltered.isEmpty {
                            VStack(alignment: .center, spacing: 12) {
                                GlacierLabel(
                                    text: NSLocalizedString("No results", comment: "Phone number selection screen no results title"),
                                    font: .bodyThick
                                )
                                
                                GlacierLabel(
                                    text: noSearchResultsDescription,
                                    font: .bodyRegular
                                )
                                
                                Spacer()
                            }
                            .padding(.top, 125)
                        } else {
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(alignment: .leading, spacing: 16) {
                                    ForEach(viewModel.glacierPhoneNumbersFiltered, id: \.id) { number in
                                        GlacierViewContainer(padding: 30) {
                                            HStack(alignment: .center) {
                                                GlacierLabel(text: number.number, font: .bodyThick)
                                                Spacer()
                                                GlacierImage(
                                                    name: .constant("plus-icon"),
                                                    width: 16,
                                                    height: 16,
                                                    shouldAdaptToColorSchemeChange: true
                                                )
                                            }
                                        }
                                        .frame(maxWidth: .infinity)
                                        .onTapGesture {
                                            UIApplication.shared.dismissKeyboard()
                                            viewModel.presentAddNumberConfirmationPrompt(for: number.number)
                                        }
                                    }
                                }
                                .padding(.top, 12)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 10)
                .onTapGesture {
                    UIApplication.shared.dismissKeyboard()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(viewModel.isKeyboardVisible ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    GlacierLabel(
                        text: NSLocalizedString("Add number", comment: "Phone number selection screen title"),
                        font: .headerTwo
                    )
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        GlacierImage(
                            name: .constant("cross-icon"),
                            contentMode: .fit,
                            width: 24,
                            height: 24,
                            shouldAdaptToColorSchemeChange: true
                        )
                    }
                }
            }
            .onFirstAppear {
                UserDefaultsService.shared.set(Sheet.phoneNumberSelection(false).name, for: \.inProgressUserOnboardingScreen)
                viewModel.loadPhoneNumbers()
            }
        }
    }
}
