//
//  VPNSetupScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 VPNSetupScreen helps users add/configure Glacier VPN configuration.
 */
struct VPNSetupScreen<ViewModel: VPNSetupViewModel>: View {
    
    // MARK: - Private properties
    
    @Environment(\.scenePhase) private var scenePhase
    
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
                            text: NSLocalizedString("DNS is setup.", comment: "VPN setup screen header"),
                            font: .headerOne,
                            customTextColor: .constant(.grey50)
                        )
                        .opacity(visibleIndices.contains(0) ? 1 : 0)
                        .padding(.top, 8)
                        
                        GlacierLabel(
                            text: NSLocalizedString("Setup your VPN.", comment: "VPN setup screen sub header"),
                            font: .headerOne,
                            shouldReverseColor: true
                        )
                        .opacity(visibleIndices.contains(1) ? 1 : 0)
                        
                        Spacer()
                        
                        HStack(alignment: .bottom) {
                            GlacierLabel(
                                text: NSLocalizedString("Hides where you're going and everything you do along the way.\n\nIdeal for public Wi-Fi, travel, or untrusted networks.\n\nHeads up - can sometimes slow your connection or limit browsing.", comment: "VPN setup screen overview"),
                                font: .headerOne,
                                customTextColor: .constant(.grey50)
                            )
                            
                            Spacer(minLength: 32)
                            
                            GlacierImageButton(name: "right-arrow-icon", imageWidth: 16, imageHeight: 16, backgroundOpacity: 0, shouldReverseColor: true) {
                                viewModel.presentAddVPNConfirmationPrompt()
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
            UserDefaultsService.shared.set(OnboardingScreen.vpnSetup.name, for: \.inProgressUserOnboardingScreen)
        }
        .onAppear {
            animateContentAppearance()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background, viewModel.didShowVPNConfigurationPrompt {
                viewModel.presentTrustedNetworksSetupView()
            }
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
