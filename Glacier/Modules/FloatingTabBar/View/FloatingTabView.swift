//
//  FloatingTabView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 23/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 FloatingTabView presents UI/UX for individual tabs.
 It updates tab background, icon and text color based on the selected state.
 */
struct FloatingTabView: View {
    
    // MARK: - Public properties
    
    @Binding var selectedTab: FloatingTab
    let tab: FloatingTab
    let shouldShowVoiceMailIndicator: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @State private var isSelected = false
    @State private var isAppearing = false
    @State private var backgroundColor: Color = .grey90
    @State private var tintColor: Color?
    
    // MARK: - UI/UX
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(tab.icon)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(tintColor)
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                    
                    if shouldShowVoiceMailIndicator {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.highlight)
                            .frame(width: 8, height: 8)
                            .offset(x: 3, y: -3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(.white, lineWidth: 1)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 3, y: -3)
                            }
                    }
                }
                
                if isSelected {
                    GlacierLabel(
                        text: tab.title,
                        font: .bodySmallThick,
                        customTextColor: $tintColor
                    )
                    .matchedGeometryEffect(id: "Text\(tab.rawValue)", in: namespace)
                }
            }
            .padding(.all, 12)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor)
                        .matchedGeometryEffect(id: "ActiveTab", in: namespace)
                }
            }
        }
        .buttonStyle(.plain)
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
        .onChange(of: selectedTab) { _ in
            setupColors(for: glacierColorScheme.activeScheme)
        }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        isSelected = selectedTab.title == tab.title
        if isSelected {
            backgroundColor = scheme == .dark ? .grey20 : .grey90
            tintColor = scheme == .dark ? .black : .white
        } else {
            backgroundColor = scheme == .dark ? .white : .grey95
            tintColor = scheme == .dark ? .grey60 : .grey40
        }
    }
}
