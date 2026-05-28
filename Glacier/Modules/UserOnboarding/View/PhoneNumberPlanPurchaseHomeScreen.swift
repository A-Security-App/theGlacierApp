//
//  PhoneNumberPlanPurchaseHomeScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 PhoneNumberPlanPurchaseHomeScreen helps user to purchase phone number plans.
 Or to skip to move to the next onboarding screen.
 */
struct PhoneNumberPlanPurchaseHomeScreen<ViewModel: PhoneNumberPlanPurchaseHomeViewModel & ObservableObject>: View {
    
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
                            text: NSLocalizedString("Purchase external phone lines.", comment: "Phone number purchase home screen header"),
                            font: .headerOne,
                            shouldReverseColor: true
                        )
                        .frame(width: 200, alignment: .leading)
                        .opacity(visibleIndices.contains(0) ? 1 : 0)
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
                        .opacity(visibleIndices.contains(1) ? 1 : 0)
                    }
                }
                .padding(.top, 40)
                
                GlacierButton(style: .tertiary,  title: NSLocalizedString("Skip for Now", comment: "Skip button title")) {
                    viewModel.skip()
                }
                .opacity(visibleIndices.contains(2) ? 1 : 0)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
        }
        .onFirstAppear {
            UserDefaultsService.shared.set(OnboardingScreen.phoneNumberPlanPurchaseHome.name, for: \.inProgressUserOnboardingScreen)
        }
        .onAppear {
            animateContentAppearance()
        }
        .onReceive(NotificationCenter.default.publisher(for: .phoneNumberPlanPurchaseSuccessful)) { notification in
            viewModel.presentUserPermissionsView()
        }
    }
    
    // MARK: - Private methods
    
    private func animateContentAppearance() {
        Task {
            let duration: UInt64 = 500_000_000 // 0.5s
            for index in 0...2 {
                let _ = withAnimation(.easeOut(duration: 0.4)) {
                    visibleIndices.insert(index)
                }
                try? await Task.sleep(nanoseconds: duration)
            }
        }
    }
}
