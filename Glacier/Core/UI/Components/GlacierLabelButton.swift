//
//  GlacierLabelButton.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 22/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierLabelButton is used for plain text based buttons without background or icon.
 It is used for links like privacy policy, terms and conditions, forgot password, etc.
 */
struct GlacierLabelButton: View {
    
    // MARK: - Environment objects
    
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    
    // MARK: - Public properties
    /**
     Custom text color can be provided by the parent view, like GlacierButton where title color changes based on button styles.
     If `customTextColor` is provided, it is used for text color. Else, text color is set based on current color scheme.
     */
    @Binding var customTextColor: Color?
    
    // MARK: - Private properties
    
    @Binding private var isEnabled: Bool
    
    @State private var backgroundColor: Color = .white
    @State private var textColor: Color = .black
    @State private var isAppearing = false
    
    private var text: String
    private var font: Font
    private var alignment: Alignment
    private var width: CGFloat
    private var height: CGFloat
    private var isUnderlined: Bool
    private var action: () -> Void
    
    // MARK: - Initializer
    
    init(
        text: String,
        font: Font,
        alignment: Alignment = .center,
        width: CGFloat = CGFloat.infinity,
        height: CGFloat = 24,
        isUnderlined: Bool = true,
        customTextColor: Binding<Color?> = .constant(nil),
        isEnabled: Binding<Bool> = .constant(true),
        action: @escaping () -> Void
    ) {
        self.text = text
        self.font = font
        self.alignment = alignment
        self.width = width
        self.height = height
        self.isUnderlined = isUnderlined
        self.action = action
        self._customTextColor = customTextColor
        self._isEnabled = isEnabled
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        Button(
            action: {
                guard isEnabled else { return }
                action()
            },
            label: {
                ZStack(alignment: alignment) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.clear)
                        .frame(maxWidth: width)
                        .frame(height: height)
                        .onTapGesture {
                            guard isEnabled else { return }
                            action()
                        }
                    
                    Text(text)
                        .font(font)
                        .underline(isUnderlined)
                        .foregroundColor(textColor)
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
        .onChange(of: customTextColor) { _ in
            setupColors(for: glacierColorScheme.activeScheme)
        }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        backgroundColor = scheme == .dark ? .grey90 : .white
        guard let customTextColor = customTextColor else {
            textColor = scheme == .dark ? .grey40 : .grey60
            return
        }
        textColor = customTextColor
    }
}
