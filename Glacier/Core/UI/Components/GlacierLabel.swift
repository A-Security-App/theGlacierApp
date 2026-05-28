//
//  GlacierLabel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 18/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierLabel makes it super simple to add text elements.
 It requites the text to show, font style (header, subHeader, bodyRegular, bodyThick, etc) and other optional properties and does the remaining stuff like,
 - Setting the correct font style and size.
 - Updating font color based on dark/light mode scheme change.
 */
struct GlacierLabel: View {
    
    // MARK: - Environment objects
    
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    
    // MARK: - Public properties
    /**
     Custom text color can be provided by the parent view, like GlacierButton where title color changes based on button styles.
     If `customTextColor` is provided, it is used for text color. Else, text color is set based on current color scheme.
     */
    @Binding var customTextColor: Color?
    
    // MARK: - Private properties
    
    @State private var textColor: Color = .black
    @State private var isAppearing = false
    
    private var text: String?
    private var attributedString: AttributedString?
    private var font: Font
    private var textAlignment: TextAlignment
    private var isUnderlined: Bool
    private var lineSpacing: CGFloat
    private let shouldReverseColor: Bool
    
    // MARK: - Initializer
    
    init(
        text: String? = nil,
        attributedString: AttributedString? = nil,
        font: Font,
        textAlignment: TextAlignment = .leading,
        isUnderlined: Bool = false,
        lineSpacing: CGFloat = 0,
        shouldReverseColor: Bool = false,
        customTextColor: Binding<Color?> = .constant(nil)
    ) {
        self.text = text
        self.attributedString = attributedString
        self.font = font
        self.textAlignment = textAlignment
        self.isUnderlined = isUnderlined
        self.lineSpacing = lineSpacing
        self.shouldReverseColor = shouldReverseColor
        self._customTextColor = customTextColor
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        Group {
            if let txt = text {
                Text(txt)
            } else if let aStr = attributedString {
                Text(aStr)
            }
        }
        .underline(isUnderlined)
        .lineSpacing(lineSpacing)
        .font(font)
        .foregroundColor(textColor)
        .multilineTextAlignment(textAlignment)
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
        guard let customTextColor = customTextColor else {
            if shouldReverseColor {
                textColor = scheme == .dark ? .black : .white
            } else {
                textColor = scheme == .dark ? .white : .black
            }
            return
        }
        textColor = customTextColor
    }
}
