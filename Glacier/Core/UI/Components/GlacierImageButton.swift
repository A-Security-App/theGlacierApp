//
//  GlacierImageButton.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 20/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierImageButton works as a button with just an icon image.
 It provides common UI/UX like background size, color, etc and workflows like adopting to dark/light color scheme change, etc.
 */
struct GlacierImageButton: View {
    
    // MARK: - Environment objects
    
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    
    // MARK: - Private properties
    
    @Binding private var isEnabled: Bool
    
    @State private var backgroundColor: Color = .grey70
    @State private var imageTintColor: Color = .white
    @State private var isAppearing = false
    
    private var name: String
    private var imageWidth: CGFloat
    private var imageHeight: CGFloat
    private var backgroundWidth: CGFloat
    private var backgroundHeight: CGFloat
    private var backgroundCornerRadius: CGFloat
    private var backgroundOpacity: Double
    private let shouldReverseColor: Bool
    private var action: () -> Void
    
    // MARK: - Initializer
    
    init(
        name: String,
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        backgroundWidth: CGFloat = 0,
        backgroundHeight: CGFloat = 0,
        backgroundCornerRadius: CGFloat = 0,
        backgroundOpacity: Double = 1.0,
        shouldReverseColor: Bool = false,
        isEnabled: Binding<Bool> = .constant(true),
        action: @escaping () -> Void
    ){
        self.name = name
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.backgroundWidth = backgroundWidth
        self.backgroundHeight = backgroundHeight
        self.backgroundCornerRadius = backgroundCornerRadius
        self.backgroundOpacity = backgroundOpacity
        self.shouldReverseColor = shouldReverseColor
        self.action = action
        self._isEnabled = isEnabled
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        Button(
            action: { action() },
            label: {
                ZStack {
                    RoundedRectangle(cornerRadius: backgroundCornerRadius)
                        .fill(backgroundColor)
                        .frame(width: backgroundWidth, height: backgroundHeight)
                        .opacity(backgroundOpacity)
                    
                    Image(name)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(imageTintColor)
                        .frame(width: imageWidth, height: imageHeight)
                }
            }
        )
        .disabled(!isEnabled)
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
            backgroundColor = scheme == .dark ? .grey30 : .grey70
            imageTintColor = scheme == .dark ? .black : .white
        } else {
            backgroundColor = scheme == .dark ? .grey70 : .grey30
            imageTintColor = scheme == .dark ? .white : .black
        }
    }
}
