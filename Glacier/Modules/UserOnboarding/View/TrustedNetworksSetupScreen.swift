//
//  TrustedNetworksSetupScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 TrustedNetworksSetupScreen helps users add wifi networks to list of trusted networks so that VPN connection is not
 activated for those trusted networks.
 */
struct TrustedNetworksSetupScreen<ViewModel: TrustedNetworksSetupViewModel>: View {
    
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
                            text: NSLocalizedString("VPN is ready.", comment: "Trusted networks setup screen header"),
                            font: .headerOne,
                            customTextColor: .constant(.grey50)
                        )
                        .opacity(visibleIndices.contains(0) ? 1 : 0)
                        .padding(.top, 8)
                        
                        GlacierLabel(
                            text: NSLocalizedString("Add wi-fi to trusted network list.", comment: "Trusted networks setup screen sub header"),
                            font: .headerOne,
                            shouldReverseColor: true
                        )
                        .frame(width: 200, alignment: .leading)
                        .opacity(visibleIndices.contains(1) ? 1 : 0)
                        
                        Spacer()
                        
                        HStack(alignment: .bottom) {
                            GlacierLabel(
                                text: NSLocalizedString("VPN will automatically turn off on this network. \nUpdate anytime.", comment: "Trusted networks setup screen overview"),
                                font: .headerOne,
                                customTextColor: .constant(.grey50)
                            )
                            
                            Spacer(minLength: 32)
                            
                            GlacierImageButton(name: "right-arrow-icon", imageWidth: 16, imageHeight: 16, backgroundOpacity: 0, shouldReverseColor: true) {
                                viewModel.addTrustedNetwork()
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
            UserDefaultsService.shared.set(OnboardingScreen.trustedNetworksSetup.name, for: \.inProgressUserOnboardingScreen)
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
