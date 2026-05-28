//
//  PhoneNumberSelectionHomeScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 PhoneNumberSelectionHomeScreen helps users choose phone numbers after successful phone number plan purchase.
 It allows to choose number of phone numbers based on the purchased plan limit.
 */
struct PhoneNumberSelectionHomeScreen<ViewModel: PhoneNumberSelectionHomeViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @StateObject private var viewModel: ViewModel
    @State private var visibleIndices: Set<Int> = []
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
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
                            text: NSLocalizedString("You're all set.", comment: "Phone number selection screen header"),
                            font: .headerOne,
                            customTextColor: .constant(.grey50)
                        )
                        .opacity(visibleIndices.contains(0) ? 1 : 0)
                        .padding(.top, 8)
                        
                        GlacierLabel(
                            text: viewModel.subHeaderText,
                            font: .headerOne,
                            shouldReverseColor: true
                        )
                        .opacity(visibleIndices.contains(1) ? 1 : 0)
                        
                        Spacer()
                        
                        HStack(alignment: .bottom) {
                            GlacierLabel(
                                text: NSLocalizedString("Choose your number.", comment: "Phone number selection screen overview"),
                                font: .headerOne,
                                shouldReverseColor: true
                            )
                            
                            Spacer(minLength: 32)
                            
                            GlacierImageButton(name: "right-arrow-icon", imageWidth: 16, imageHeight: 16, backgroundOpacity: 0, shouldReverseColor: true) {
                                viewModel.presentPhoneNumberSelectionView()
                            }
                        }
                        .opacity(visibleIndices.contains(2) ? 1 : 0)
                    }
                }
                .padding(.top, 40)
                
                GlacierButton(style: .tertiary,  title: NSLocalizedString("Skip for Now", comment: "Skip button title")) {
                    viewModel.skip()
                }
                .opacity(visibleIndices.contains(3) ? 1 : 0)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
        }
        .onFirstAppear {
            UserDefaultsService.shared.set(OnboardingScreen.phoneNumberSelectionHome.name, for: \.inProgressUserOnboardingScreen)
        }
        .onAppear {
            animateContentAppearance()
        }
    }
    
    // MARK: - Private methods
    
    private func animateContentAppearance() {
        Task {
            let duration: UInt64 = 500_000_000 // 0.5s
            for index in 0...3 {
                let _ = withAnimation(.easeOut(duration: 0.4)) {
                    visibleIndices.insert(index)
                }
                try? await Task.sleep(nanoseconds: duration)
            }
        }
    }
}
