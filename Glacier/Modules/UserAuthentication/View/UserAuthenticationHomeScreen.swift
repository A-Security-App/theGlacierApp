//
//  UserAuthenticationHomeScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 11/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 UserAuthenticationHomeScreen presents home view for user authentication module.
 Users can choose to either signup for new user account or login with existing user account.
 */
struct UserAuthenticationHomeScreen<ViewModel: UserAuthenticationHomeViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @StateObject private var viewModel: ViewModel
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack(alignment: .bottom) {
            SlidingCardScreen()
                .ignoresSafeArea()
            
            VStack(alignment: .center, spacing: 8) {
                Spacer()
                
                // Signup button
                Button(
                    action: {
                        viewModel.presentUserRegistrationScreen()
                    },
                    label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white)
                                .frame(height: 72)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.grey20, lineWidth: 1)
                                }
                            
                            GlacierLabel(
                                text: NSLocalizedString("Sign Up", comment: "User authentication home screen signup button title"),
                                font: .bodyLargeThick,
                                customTextColor: .constant(.black)
                            )
                        }
                    }
                )
                
                // Login button
                Button(
                    action: {
                        viewModel.presentUserLoginScreen()
                    },
                    label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.clear)
                                .frame(height: 72)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.grey20, lineWidth: 1)
                                }
                            
                            GlacierLabel(
                                text: NSLocalizedString("Log In", comment: "User authentication home screen login button title"),
                                font: .bodyLargeThick,
                                customTextColor: .constant(.white)
                            )
                        }
                    }
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .ignoresSafeArea()
    }
}
