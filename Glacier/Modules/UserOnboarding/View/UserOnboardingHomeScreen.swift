//
//  UserOnboardingHomeScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 UserOnboardingHomeScreen presents the welcome message and initiates onboarding flow as user taps on `Get Started` button.
 */
struct UserOnboardingHomeScreen: View {
    
    // MARK: - Environment objects
    
    @EnvironmentObject private var rootCoordinator: GlacierAppRootCoordinator
    @EnvironmentObject private var userOnboardingCoordinator: UserOnboardingCoordinator
    
    // MARK: - Private properties
    
    @State private var shouldShowHomeScreenContent: Bool = false
    @State private var visibleIndices: Set<Int> = []
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
            
            // Onboarding home screen content
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    GlacierLabel(
                        text: NSLocalizedString("Glacier", comment: "Glacier text"),
                        font: .headerTwo
                    )
                    Spacer()
                    GlacierImageButton(name: "settings-icon", imageWidth: 16, imageHeight: 16, backgroundOpacity: 0) {
                        rootCoordinator.presentScreen(.settings)
                    }
                }
                
                GlacierViewContainer(shouldReverseColor: true, darkColor: .grey95, lightColor: .white) {
                    VStack(alignment: .leading, spacing: 16) {
                        GlacierLabel(
                            text: NSLocalizedString("Welcome.", comment: "User onboarding screen header"),
                            font: .headerOne,
                            shouldReverseColor: true
                        )
                        .opacity(visibleIndices.contains(0) ? 1 : 0)
                        .padding(.top, 8)
                        
                        GlacierLabel(
                            text: NSLocalizedString("Browse, call, and work with confidence.", comment: "User onboarding screen sub header"),
                            font: .headerOne,
                            customTextColor: .constant(.grey50)
                        )
                        .opacity(visibleIndices.contains(1) ? 1 : 0)
                        
                        Spacer(minLength: 32)
                        
                        GlacierButton(style: .tertiary,  title: NSLocalizedString("Get Started", comment: "User onboarding get started button title")) {
                            let account = GlacierAccountModel.getGlacierAccount()
                            if account?.hasActiveSubscription == true {
                                userOnboardingCoordinator.setScreen(.dnsSetup)
                            } else {
                                rootCoordinator.presentSheet(.glacierPlanPurchase)
                            }
                        }
                        .opacity(visibleIndices.contains(2) ? 1 : 0)
                    }
                }
                .padding(.top, 40)
            }
            .opacity(shouldShowHomeScreenContent ? 1 : 0)
            .padding(.top, 16)
            .padding(.horizontal, 16)
            
            // Welcome screen content
            UserOnboardingWelcomeScreen {
                shouldShowHomeScreenContent = true
                animateContentAppearance()
            }
            .opacity(shouldShowHomeScreenContent ? 0 : 1)
            .ignoresSafeArea()
        }
        .onFirstAppear {
            UserDefaultsService.shared.set(OnboardingScreen.userOnboardingHome.name, for: \.inProgressUserOnboardingScreen)
        }
        .onReceive(NotificationCenter.default.publisher(for: .glacierPlanPurchaseSuccessful)) { notification in
            // Let's dismiss glacier plan purchase sheet
            rootCoordinator.dismissSheet()
            
            // Let's take user to the DNS setup screen
            userOnboardingCoordinator.setScreen(.dnsSetup)
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

/**
 It shows glacier logo and welcome text with a subtle animation and lets the host view know when the welcome is completed.
 */
struct UserOnboardingWelcomeScreen: View {
    
    // MARK: - Public properties
    
    var onWelcomeComplete: () -> Void
    
    // MARK: - Private properties
    
    @State private var moveLogoUp = false
    @State private var showTitle = false
    
    private let logoMoveOffset: CGFloat = 70
    private let animationDuration: Double = 0.4
    private let animationStartDelay: Double = 0.5
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                GlacierImage(
                    name: .constant("glacier-logo"),
                    width: 90,
                    height: 90,
                    shouldAdaptToColorSchemeChange: true
                )
                .offset(y: moveLogoUp ? -logoMoveOffset : 0)
                .animation(.easeIn(duration: animationDuration), value: moveLogoUp)
                
                GlacierLabel(
                    text: NSLocalizedString("Welcome to Glacier", comment: "User onboarding home screen welcome text"),
                    font: .neueHassGroteskThickFont(ofSize: 25)
                )
                .opacity(showTitle ? 1 : 0)
                .animation(.easeIn(duration: animationDuration), value: showTitle)
            }
        }
        .onAppear {
            startAnimation()
        }
    }
    
    // MARK: - Animation Sequence
    
    private func startAnimation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + animationStartDelay) {
            moveLogoUp = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (animationStartDelay + animationDuration/2)) {
            showTitle = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            onWelcomeComplete()
        }
    }
}
