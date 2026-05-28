//
//  GlacierViewContainer.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 18/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierViewContainer is used to provide common UI/UX like,
 - Background view with corner rounding
 - Border styles
 - Auto color change based on dark/light mode color change
 - Effects like shadow, etc
 
 It serves as a generic container to which child views could be added.
 */
struct GlacierViewContainer<Content: View>: View {
    
    // MARK: - Environment objects
    
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    
    // MARK: - Private properties
    
    @State private var backgroundColor: Color = .white
    @State private var borderColor: Color?
    @State private var dhadowColor: Color?
    @State private var isAppearing = false
    
    private let content: Content
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let darkColor: Color
    private let lightColor: Color
    
    /**
     shouldReverseColor flag tells the container to reverse the color used for dark/light scheme.
     User onboarding screens need to show reverse colors then other screen home, user authentication, etc.
     */
    private let shouldReverseColor: Bool
    
    // MARK: - Initializer
    
    init(
        cornerRadius: CGFloat = 24,
        padding: CGFloat = 24,
        shouldReverseColor: Bool = false,
        darkColor: Color = .grey90,
        lightColor: Color = .white,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.darkColor = darkColor
        self.lightColor = lightColor
        self.shouldReverseColor = shouldReverseColor
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        content
            .padding(.all, padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor)
            )
            .onAppear {
                isAppearing = true
                setupColors(for: glacierColorScheme.activeScheme)
            }
            .onDisappear {
                isAppearing = false
            }
            .onChange(of: glacierColorScheme.activeScheme) { newScheme in
                guard isAppearing else { return }
                setupColors(for: newScheme)
            }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        if shouldReverseColor {
            backgroundColor = scheme == .dark ? lightColor : darkColor
        } else {
            backgroundColor = scheme == .dark ? darkColor : lightColor
        }
    }
}
