//
//  GlacierProgressIndicator.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierProgressIndicator prsents SwiftUI's internal ProgressView and updates background color, progress indicator color based on
 active dark/light color mode.
 */
struct GlacierProgressIndicator: View {
    
    // MARK: - Private properties
    
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var glacierColorScheme = GlacierColorScheme()
    
    @State private var backgroundColor: Color = .white
    @State private var primaryColor: Color = .grey95
    @State private var secondaryColor: Color = .grey30
    @State private var isAppearing = false
    
    private var size: CGFloat
    
    // MARK: - Initializer
    
    init(size: CGFloat) {
        self.size = size
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            backgroundColor.opacity(0.6)
                .edgesIgnoringSafeArea(.all)
            
            SpinnerCircle(
                primaryColor: $primaryColor,
                secondaryColor: $secondaryColor,
                size: size
            )
        }
        .onAppear {
            isAppearing = true
            setupColors(for: glacierColorScheme.activeScheme)
        }
        .onDisappear {
            isAppearing = false
        }
        .onChange(of: colorScheme) { newScheme in
            glacierColorScheme.setScheme(newScheme)
        }
        .onChange(of: glacierColorScheme.activeScheme) { newScheme in
            guard isAppearing else { return }
            setupColors(for: newScheme)
        }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        backgroundColor = scheme == .dark ? .grey95 : .white
        primaryColor = scheme == .dark ? .grey70 : .grey95
        secondaryColor = scheme == .dark ? .white : .grey30
    }
}

struct SpinnerCircle: View {
    
    // MARK: - Public properties
    
    @Binding var primaryColor: Color
    @Binding var secondaryColor: Color
    let size: CGFloat
    
    // MARK: - Private properties
    
    @State private var rotation: Double = 0
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            // Static circle
            Circle()
                .stroke(
                    secondaryColor,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            
            // Moving arc
            Circle()
                .trim(from: 0.0, to: 0.28)
                .stroke(
                    primaryColor,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(
                .linear(duration: 1.2)
                .repeatForever(autoreverses: false)
            ) {
                rotation = 360
            }
        }
    }
}
