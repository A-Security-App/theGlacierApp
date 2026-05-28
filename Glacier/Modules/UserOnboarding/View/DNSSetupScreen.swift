//
//  DNSSetupScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 DNSSetupScreen helps users set DNS settings via iOS settings app.
 */
struct DNSSetupScreen<ViewModel: DNSSetupViewModel>: View {
    
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
                            text: NSLocalizedString("You’re in.", comment: "DNS setup screen header"),
                            font: .headerOne,
                            customTextColor: .constant(.grey50)
                        )
                        .opacity(visibleIndices.contains(0) ? 1 : 0)
                        .padding(.top, 8)
                        
                        GlacierLabel(
                            text: NSLocalizedString("Setup DNS.", comment: "DNS setup screen sub header"),
                            font: .headerOne,
                            shouldReverseColor: true
                        )
                        .opacity(visibleIndices.contains(1) ? 1 : 0)
                        
                        Spacer()
                        
                        HStack(alignment: .bottom) {
                            GlacierLabel(
                                text: NSLocalizedString("Hides which sites you're visiting.\n\nFaster connection, no ads, and enough privacy for everyday use.", comment: "DNS setup screen overview"),
                                font: .headerOne,
                                customTextColor: .constant(.grey50)
                            )
                            
                            Spacer(minLength: 32)
                            
                            GlacierImageButton(name: "right-arrow-icon", imageWidth: 16, imageHeight: 16, backgroundOpacity: 0, shouldReverseColor: true) {
                                viewModel.presentDNSSetupConfirmationPrompt()
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
            UserDefaultsService.shared.set(OnboardingScreen.dnsSetup.name, for: \.inProgressUserOnboardingScreen)
            viewModel.prefetchAndStoreDNSProfile()
        }
        .onAppear {
            animateContentAppearance()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background, viewModel.didShowDeviceSettings {
                viewModel.presentVPNSetupView()
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
