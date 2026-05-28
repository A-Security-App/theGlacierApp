//
//  UserPermissionsScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 UserPermissionsScreen presents user permission prompts for seeking,
 - Push notification permission
 - Contacts access permission
 */
struct UserPermissionsScreen<ViewModel: UserPermissionsViewModel>: View {
    
    // MARK: - Private properties
    
    @State private var visibleIndices: Set<Int> = []
    private var viewModel: ViewModel
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
            
            VStack(alignment: .leading, spacing: 20) {
                GlacierViewContainer(shouldReverseColor: true, darkColor: .grey95, lightColor: .white) {
                    VStack(alignment: .leading, spacing: 16) {
                        GlacierLabel(
                            text: NSLocalizedString("Enable permissions.", comment: "User permissions screen header"),
                            font: .headerOne,
                            shouldReverseColor: true
                        )
                        .opacity(visibleIndices.contains(0) ? 1 : 0)
                        .padding(.top, 8)
                        
                        Spacer()
                        
                        HStack(alignment: .bottom) {
                            GlacierLabel(
                                text: NSLocalizedString("Notifications help you receive calls in real time.\n\nContact access is only used to help identify or start calls. Your contacts never leave your phone.", comment: "User permissions screen overview"),
                                font: .headerOne,
                                customTextColor: .constant(.grey50)
                            )
                            
                            Spacer(minLength: 32)
                            
                            GlacierImageButton(name: "right-arrow-icon", imageWidth: 16, imageHeight: 16, backgroundOpacity: 0, shouldReverseColor: true) {
                                viewModel.presentContactsAccessPrompt()
                            }
                        }
                        .opacity(visibleIndices.contains(1) ? 1 : 0)
                    }
                }
                .padding(.top, 40)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
        }
        .onFirstAppear {
            UserDefaultsService.shared.set(OnboardingScreen.userPermissions.name, for: \.inProgressUserOnboardingScreen)
            
            animateContentAppearance()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                viewModel.presentSuccessfulPurchaseAlert()
            }
        }
    }
    
    // MARK: - Private methods
    
    private func animateContentAppearance() {
        Task {
            let duration: UInt64 = 500_000_000 // 0.5s
            for index in 0...1 {
                let _ = withAnimation(.easeOut(duration: 0.4)) {
                    visibleIndices.insert(index)
                }
                try? await Task.sleep(nanoseconds: duration)
            }
        }
    }
}
