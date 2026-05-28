//
//  UserLoginScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 11/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 UserLoginScreen presents UI/UX and user interactions for login with these authentication flows,
 - Registered email and password
 - Google SSO
 - Apple SSO
 */
struct UserLoginScreen<ViewModel: UserLoginViewModel & ObservableObject, Coordinator: PasswordResetCoordinator>: View {
    
    // MARK: - Environment objects
    
    @SwiftUI.Environment(\.presentationMode) private var presentationMode
    
    // MARK: - Private properties
    
    @StateObject private var viewModel: ViewModel
    @StateObject private var passwordResetCoordinator: Coordinator
    
    private var subHeaderText: String {
        if viewModel.shouldShowPasswordTextField {
            NSLocalizedString("Enter your password.", comment: "User login screen sub header password")
        } else {
            NSLocalizedString("Enter your email.", comment: "User login screen sub header email")
        }
    }
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel, coordinator: Coordinator) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self._passwordResetCoordinator = StateObject(wrappedValue: coordinator)
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        NavigationStack(path: $passwordResetCoordinator.path) {
            ZStack {
                GlacierBackground()
                    .ignoresSafeArea()
                    .onTapGesture {
                        UIApplication.shared.dismissKeyboard()
                    }
                
                VStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .center, spacing: 8) {
                        GlacierLabel(
                            text: NSLocalizedString("Log in", comment: "User login screen header"),
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
                        placeholder: NSLocalizedString("Email", comment: "User login screen email place holder"),
                        text: $viewModel.email
                    )
                    .padding(.top, 24)
                    
                    if viewModel.shouldShowPasswordTextField {
                        GlacierTextField(
                            placeholder: NSLocalizedString("Password", comment: "User login screen password place holder"),
                            isSecured: true,
                            text: $viewModel.password,
                            error: $viewModel.passwordValidationError,
                            state: $viewModel.passwordTextFieldState
                        )
                    }
                    
                    VStack(alignment: .leading, spacing: 16) {
                        GlacierButton(
                            style: .secondary,
                            title: NSLocalizedString("Continue", comment: "Continue button title"),
                            isEnabled: $viewModel.isContinueButtonEnabled,
                            action: {
                                UIApplication.shared.dismissKeyboard()
                                viewModel.signInWithEmail()
                            }
                        )
                        
                        GlacierLabelButton(
                            text: NSLocalizedString("Forgot password?", comment: "User login screen forgot password button title"),
                            font: .bodyThick,
                            alignment: .leading,
                            isEnabled: .constant(true),
                            action: {
                                viewModel.presentPasswordResetScreen()
                            }
                        )
                    }
                    
                    if !viewModel.shouldShowPasswordTextField {
                        GlacierLineSeparator(label: NSLocalizedString("or", comment: "Or text"))
                            .padding(.top, 24)
                        
                        GlacierButton(
                            style: .tertiary,
                            title: NSLocalizedString("Continue with Google", comment: "User login screen Google auth button title"),
                            icon: "google-logo",
                            action: {
                                viewModel.signInWith(.google)
                            }
                        )
                        .padding(.top, 24)
                        
                        GlacierButton(
                            style: .tertiary,
                            title: NSLocalizedString("Continue with Apple", comment: "User login screen Apple auth button title"),
                            icon: "apple-logo",
                            action: {
                                viewModel.signInWith(.apple)
                            }
                        )
                    }
                    
                    Spacer()
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
            .navigationDestination(for: PasswordResetScreens.self) { screen in
                passwordResetCoordinator.build(screen)
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
        }
    }
}
