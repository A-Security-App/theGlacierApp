//
//  GlacierButton.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 18/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierButtonStyle defines button types and their specific color scheme based on the Figma design specs.
 */
enum GlacierButtonSyle {
    case primary, secondary, tertiary
    
    func backgroundColor(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .primary: .highlight
        case .secondary: colorScheme == .dark ? .white : .grey95
        case .tertiary: colorScheme == .dark ? .grey90 : .white
        }
    }
    
    func titleColor(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .primary: .white
        case .secondary: colorScheme == .dark ? .black : .white
        case .tertiary: colorScheme == .dark ? .white : .black
        }
    }
    
    func borderColor(for colorScheme: ColorScheme) -> Color? {
        switch self {
        case .primary: nil
        case .secondary: nil
        case .tertiary: colorScheme == .dark ? .grey70 : .grey20
        }
    }
}

/**
 Glacier button makes it super simple to add button with basic data like title, style and action. It takes care of rest of the things internally like,
 - Setting the correct font style, color and size based on the given style
 - Updating title, background and border color/style based on active dark/light color scheme.
 - Enabling/disabling button action
 
 Additional properties like size, padding, radius, icon, etc can be passed for more customization.
 */
struct GlacierButton: View {
    
    // MARK: - Environment objects
    
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    
    // MARK: - Private properties
    
    @Binding private var isEnabled: Bool
    
    @State private var backgroundColor: Color = .white
    @State private var titleColor: Color? = .black
    @State private var borderColor: Color? = nil
    @State private var shadowColor: Color? = nil
    @State private var isAppearing = false
    
    private var style: GlacierButtonSyle
    private var title: String
    private var customTitleColor: Color?
    private var icon: String?
    private var height: CGFloat
    private var width: CGFloat
    private var cornerRadius: CGFloat
    private var padding: CGFloat
    private var action: () -> Void
    
    // MARK: - Initializer
    
    init(
        style: GlacierButtonSyle = .tertiary,
        title: String,
        customTitleColor: Color? = nil,
        icon: String? = nil,
        height: CGFloat = 72,
        width: CGFloat = CGFloat.infinity,
        cornerRadius: CGFloat = 16,
        padding: CGFloat = 24,
        shadowColor: Color? = nil,
        isEnabled: Binding<Bool> = .constant(true),
        action: @escaping @MainActor () -> Void
    ) {
        self.style = style
        self.title = title
        self.customTitleColor = customTitleColor
        self.icon = icon
        self.height = height
        self.width = width
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.shadowColor = shadowColor
        self._isEnabled = isEnabled
        self.action = action
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            Button(
                action: {
                    guard isEnabled else { return }
                    action()
                },
                label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(backgroundColor)
                            .frame(maxWidth: width)
                            .frame(height: height)
                        
                        if let bColor = borderColor {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .stroke(lineWidth: 1)
                                .stroke(bColor)
                                .frame(maxWidth: width)
                                .frame(height: height)
                        }
                            
                        HStack(alignment: .center, spacing: 8) {
                            if let icon = self.icon {
                                GlacierImage(name: .constant(icon), width: 16, height: 16)
                            }
                            
                            GlacierLabel(
                                text: title,
                                font: .bodyLargeThick,
                                customTextColor: $titleColor
                            )
                        }
                        .padding(.all, padding)
                    }
                }
            )
            .disabled(!isEnabled)
        }
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
        .onChange(of: isEnabled) { _ in
            setupColors(for: glacierColorScheme.activeScheme)
        }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        guard isEnabled else {
            backgroundColor = scheme == .dark ? .grey70 : .grey30
            if let custTitleColor = customTitleColor {
                titleColor = custTitleColor
            } else {
                titleColor = scheme == .dark ? .grey40 : .grey60
            }
            
            borderColor = style.borderColor(for: scheme)
            return
        }
        backgroundColor = style.backgroundColor(for: scheme)
        
        if let custTitleColor = customTitleColor {
            titleColor = custTitleColor
        } else {
            titleColor = style.titleColor(for: scheme)
        }
        
        borderColor = style.borderColor(for: scheme)
    }
}
