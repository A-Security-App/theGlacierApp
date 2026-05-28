//
//  GlacierBackground.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 18/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierBackground is used to set screen background with adaptive color based on light/dark color scheme.
 */
struct GlacierBackground: View {
    
    // MARK: - Environment objects
    
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    
    // MARK: - Private properties
    
    @State private var backgroundColor: Color = .grey10
    @State private var isAppearing = false
    
    private var cornerRadius: CGFloat = 0
    
    // MARK: - Initialzer
    
    init(cornerRadius: CGFloat = 0) {
        self.cornerRadius = cornerRadius
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(backgroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        backgroundColor = scheme == .dark ? .grey95 : .grey10
    }
}
