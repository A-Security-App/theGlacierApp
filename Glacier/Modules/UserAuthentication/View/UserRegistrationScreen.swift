//
//  UserRegistrationScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 11/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 UserRegistrationScreen presents UI/UX and interation for new user registration with,
 - Email and password
 - Google SSO
 - Apple SSO
 */
struct UserRegistrationScreen<ViewModel: UserRegistrationViewModel & ObservableObject>: View {
    
    // MARK: - Environment objects
    
    @SwiftUI.Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    
    // MARK: - Private properties
    
    @StateObject private var viewModel: ViewModel
    
    private var subHeaderText: String {
        if viewModel.shouldShowPasswordTextField {
            NSLocalizedString("Set your Password.", comment: "User registration screen sub header password")
        } else {
            NSLocalizedString("You’ll use this email to log in.", comment: "User registration screen sub header email")
        }
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
                
                if viewModel.isUserAccountCreated && viewModel.isUserAccountConfirmationPending {
                    UserRegistrationConfirmationScreen(viewModel: viewModel)
                }
                
                VStack(alignment: .center, spacing: 16) {
                    if !viewModel.isUserAccountCreated {
                        VStack(alignment: .center, spacing: 8) {
                            GlacierLabel(
                                text: NSLocalizedString("Create your account", comment: "User registration screen header"),
                                font: .headerTwo,
                                textAlignment: .center
                            )
                            
                            GlacierLabel(
                                text: subHeaderText,
                                font: .headerTwo,
                                textAlignment: .center,
                                customTextColor: .constant(.grey60)
                            )
                        }
                        .padding(.top, 24)
                        
                        GlacierTextField(
                            placeholder: NSLocalizedString("Email", comment: "User registration screen email place holder"),
                            text: $viewModel.email
                        )
                        .padding(.top, 24)
                        
                        VStack(alignment: .center, spacing: 0) {
                            if viewModel.shouldShowPasswordTextField {
                                GlacierTextField(
                                    placeholder: NSLocalizedString("Password", comment: "User registration screen password place holder"),
                                    isSecured: true,
                                    text: $viewModel.password,
                                    state: $viewModel.passwordTextFieldState
                                )
                                
                                // Password validation checklist status
                                HStack{
                                    GlacierLabel(attributedString: viewModel.passwordValidationChecklistStatus, font: .bodySmall)
                                        .frame(height: 80)
                                        .padding(.horizontal, 16)
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        
                        GlacierButton(
                            style: .secondary,
                            title: NSLocalizedString("Continue", comment: "Continue button title"),
                            isEnabled: $viewModel.isContinueButtonEnabled,
                            action: {
                                UIApplication.shared.dismissKeyboard()
                                viewModel.signInWithEmail()
                            }
                        )
                        
                        if !viewModel.shouldShowPasswordTextField {
                            GlacierLineSeparator(label: NSLocalizedString("or", comment:  "Or text"))
                                .padding(.top, 24)
                            
                            GlacierButton(
                                style: .tertiary,
                                title: NSLocalizedString("Continue with Google", comment: "User registration screen Google auth button title"),
                                icon: "google-logo",
                                action: {
                                    viewModel.signInWith(.google)
                                }
                            )
                            .padding(.top, 24)
                            
                            GlacierButton(
                                style: .tertiary,
                                title: NSLocalizedString("Continue with Apple", comment: "User registration screen Apple auth button title"),
                                icon: "apple-logo",
                                action: {
                                    viewModel.signInWith(.apple)
                                }
                            )
                        }
                    }
                    
                    Spacer()
                    
                    HStack(alignment: .center, spacing: 24) {
                        GlacierLabelButton(
                            text: NSLocalizedString("Terms of Use", comment: "Terms of use button title"),
                            font: .bodySmall,
                            width: 80,
                            isUnderlined: true, action: {
                                viewModel.openTermsOfUseURL()
                            }
                        )
                        GlacierLabelButton(
                            text: NSLocalizedString("Privacy Policy", comment: "Privacy policy button title"),
                            font: .bodySmall,
                            width: 80,
                            isUnderlined: true, action: {
                                viewModel.openPrivacyPolicyURL()
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
            }
            .toolbar {
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
        }
        .onFirstAppear {
            viewModel.colorScheme = glacierColorScheme.activeScheme
        }
        .onChange(of: glacierColorScheme.activeScheme) { colorScheme in
            viewModel.colorScheme = colorScheme
        }
    }
}
