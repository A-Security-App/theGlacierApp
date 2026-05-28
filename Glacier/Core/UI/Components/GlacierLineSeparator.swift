//
//  GlacierLineSeparator.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 24/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierLineSeparator draws a horizontal separator line with given label text (optional).
 It updates line and label colors based on dark/light color scheme change.
 */
struct GlacierLineSeparator: View {
    
    // MARK: - Environment objects
    
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    
    // MARK: - Private properties
    
    @State private var lineColor: Color
    @State private var labelBackgroundColor: Color
    @State private var isAppearing = false
    
    private var label: String?
    private var labelColor: Color
    private var labelWidth: CGFloat
    private var lineThickness: Double
    
    // MARK: - Initializer
    
    init(
        label: String? = nil,
        labelColor: Color = .grey60,
        labelWidth: CGFloat = .infinity,
        lineThickness: Double = 1,
        lineColor: Color = .grey20
    ) {
        self.label = label
        self.labelColor = labelColor
        self.labelWidth = labelWidth
        self.labelBackgroundColor = .grey20
        self.lineColor = lineColor
        self.lineThickness = lineThickness
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack(alignment: .center) {
            Rectangle()
                .fill(lineColor)
                .frame(height: lineThickness)
                .frame(maxWidth: .infinity)
            
            if let label, !label.isEmpty {
                GlacierLabel(
                    text: label,
                    font: .bodyThick,
                    customTextColor: .constant(labelColor)
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
                .background {
                    Rectangle()
                        .fill(labelBackgroundColor)
                }
            }
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
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        labelBackgroundColor = scheme == .dark ? .grey95 : .grey10
        lineColor = scheme == .dark ? .grey90 : .grey20
    }
}
