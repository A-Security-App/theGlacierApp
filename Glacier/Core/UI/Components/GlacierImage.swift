//
//  GlacierImage.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 20/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierImage sets up SwiftUI image elemenet based on the given properties.
 */
struct GlacierImage: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    
    @Binding private var name: String?
    @Binding private var systemName: String?
    @Binding private var customTintColor: Color?
    
    @State private var isAppearing = false
    @State private var tintColor: Color = .black
    
    private var contentMode: ContentMode = .fit
    private var width: CGFloat
    private var height: CGFloat
    private var shouldAdaptToColorSchemeChange: Bool = false
    
    // MARK: - Initializer
    
    init(
        name: Binding<String?> = .constant(nil),
        systemName: Binding<String?> = .constant(nil),
        contentMode: ContentMode = .fit,
        width: CGFloat,
        height: CGFloat,
        shouldAdaptToColorSchemeChange: Bool = false,
        customTintColor: Binding<Color?> = .constant(nil)
    ) {
        self._name = name
        self._systemName = systemName
        self.contentMode = contentMode
        self.width = width
        self.height = height
        self.shouldAdaptToColorSchemeChange = shouldAdaptToColorSchemeChange
        self._customTintColor = customTintColor
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        Group {
            if let name = name {
                Image(name)
                    .resizable()
                    .renderingMode(shouldAdaptToColorSchemeChange ? .template : customTintColor == nil ? .original : .template)
                    .foregroundColor(tintColor)
                    .aspectRatio(contentMode: contentMode)
                    
            } else if let systemName = systemName {
                Image(systemName: systemName)
                    .resizable()
                    .renderingMode(shouldAdaptToColorSchemeChange ? .template : customTintColor == nil ? .original : .template)
                    .foregroundColor(tintColor)
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .frame(width: width, height: height)
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
        .onChange(of: customTintColor) { _ in
            guard isAppearing else { return }
            setupColors(for: glacierColorScheme.activeScheme)
        }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        guard shouldAdaptToColorSchemeChange else {
            guard let cTintColor = customTintColor else {
                tintColor = .black
                return
            }
            tintColor = cTintColor
            return
        }
        tintColor = scheme == .dark ? .white : .black
    }
}
