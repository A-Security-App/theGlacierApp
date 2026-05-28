//
//  PhoneScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 24/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 PhoneScreen is the home for adding/removing phone numbers after the user onboarding flow. Users see the list of selected phone numbers
 here and set them as active phone number for making and recieveing phone calls.
 */
struct PhoneScreen<ViewModel: PhoneViewModel & ObservableObject>: View, PhoneNumberMenuCoordinator {
    
    // MARK: - Private properties
    
    @ObservedObject private var viewModel: ViewModel
    @StateObject private var phoneDialPadViewModel: PhoneDialPadVM
    
    // MARK: - Initilizer
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel
        self._phoneDialPadViewModel = StateObject(wrappedValue: PhoneDialPadVM(rootCoordinator: viewModel.rootCoordinator))
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
                .onTapGesture {
                    hidePhoneNumberMenu()
                }
            
            Group {
                if !viewModel.hasPhoneNumberSubscription {
                    phoneNumberSubscriptionIntroView
                } else if viewModel.hasPhoneNumberSubscription, viewModel.phoneNumbers.isEmpty {
                    noPhoneNumbersView
                } else if viewModel.hasPhoneNumberSubscription, !viewModel.phoneNumbers.isEmpty {
                    phoneDialPadView
                }
            }
            .padding(.top, 4)
        }
        .onFirstAppear {
            viewModel.initialize()
        }
    }
    
    // MARK: - Screen elements
    
    private var phoneDialPadView: some View {
        PhoneDialPadScreen(viewModel: phoneDialPadViewModel)
            .padding(.bottom, 96)
    }
    
    private var phoneNumberSubscriptionIntroView: some View {
        VStack(alignment: .leading, spacing: 20) {
            GlacierViewContainer(shouldReverseColor: true, darkColor: .grey95, lightColor: .white) {
                VStack(alignment: .leading, spacing: 16) {
                    GlacierLabel(
                        text: NSLocalizedString("Purchase external phone lines.", comment: "Phone number purchase home screen header"),
                        font: .headerOne,
                        shouldReverseColor: true
                    )
                    .frame(width: 200, alignment: .leading)
                    .padding(.top, 8)
                    
                    Spacer()
                    
                    HStack(alignment: .bottom) {
                        GlacierLabel(
                            text: NSLocalizedString("For conversations that never point back to you.", comment: "Phone number purchase home screen overview"),
                            font: .headerOne,
                            customTextColor: .constant(.grey50)
                        )
                        
                        Spacer(minLength: 32)
                        
                        GlacierImageButton(name: "right-arrow-icon", imageWidth: 16, imageHeight: 16, backgroundOpacity: 0, shouldReverseColor: true) {
                            viewModel.presentPhoneNumberPlanPurchaseView()
                        }
                    }
                }
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 96)
    }
    
    private var noPhoneNumbersView: some View {
        VStack(alignment: .center, spacing: 24) {
            Button(
                action: {
                    viewModel.presentPhoneNumberSelectionView()
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
                text: NSLocalizedString("Add phone number", comment: "Phone screen add phone number"),
                font: .bodyRegular
            )
        }
        .offset(y: -75)
    }
}
