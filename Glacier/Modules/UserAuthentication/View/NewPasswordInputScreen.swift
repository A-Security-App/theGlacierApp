//
//  NewPasswordInputScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 29/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 NewPasswordInputScreen presents UI/UX for updating user password with new one.
 */
struct NewPasswordInputScreen<ViewModel: NewPasswordInputViewModel & ObservableObject>: View {
    
    // MARK: - Environment objects
    
    @SwiftUI.Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    
    // MARK: - Private properties
    
    @StateObject private var viewModel: ViewModel
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
                .onTapGesture {
                    UIApplication.shared.dismissKeyboard()
                }
            
            VStack(alignment: .center, spacing: 16) {
                VStack(alignment: .center, spacing: 8) {
                    GlacierLabel(
                        text: NSLocalizedString("Update password", comment: "New password input screen header"),
                        font: .headerTwo,
                        textAlignment: .center
                    )
                    
                    GlacierLabel(
                        text: NSLocalizedString("Enter a new password.", comment: "New password input screen sub header"),
                        font: .headerTwo,
                        textAlignment: .center,
                        customTextColor: .constant(.grey60)
                    )
                }
                .padding(.top, 24)
                
                VStack(alignment: .center, spacing: 0) {
                    GlacierTextField(
                        placeholder: NSLocalizedString("Password", comment: "New password input screen password one place holder"),
                        isSecured: true,
                        text: $viewModel.passwordOne,
                        state: $viewModel.passwordOneTextFieldState,
                        onSubmit: {
                            viewModel.passwordTwoTextFieldState = .active
                        }
                    )
                    
                    // Password one validation checklist status
                    if !viewModel.isValidPasswordOne {
                        HStack{
                            GlacierLabel(attributedString: viewModel.passwordValidationChecklistStatus, font: .bodySmall)
                                .frame(height: 80)
                                .padding(.leading, 16)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 24)
                
                
                if viewModel.isValidPasswordOne {
                    VStack(alignment: .center, spacing: 8) {
                        GlacierTextField(
                            placeholder: NSLocalizedString("Re-enter Password", comment: "New password input screen password two place holder"),
                            isSecured: true,
                            text: $viewModel.passwordTwo,
                            state: $viewModel.passwordTwoTextFieldState
                        )
                        
                        // Password validation checklist status
                        if let validationError = viewModel.passwordTwoValidationError {
                            HStack{
                                GlacierLabel(
                                    text: validationError,
                                    font: .bodySmall,
                                    customTextColor: .constant(.ember)
                                )
                                .padding(.leading, 16)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                
                GlacierButton(
                    style: .secondary,
                    title: NSLocalizedString("Continue", comment: "Continue button title"),
                    isEnabled: $viewModel.isContinueButtonEnabled,
                    action: {
                        UIApplication.shared.dismissKeyboard()
                        viewModel.resetPassword()
                    }
                )
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
        }
        .onFirstAppear {
            viewModel.colorScheme = glacierColorScheme.activeScheme
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                viewModel.passwordOneTextFieldState = .active
            }
        }
        .onChange(of: glacierColorScheme.activeScheme) { colorScheme in
            viewModel.colorScheme = colorScheme
        }
    }
}
