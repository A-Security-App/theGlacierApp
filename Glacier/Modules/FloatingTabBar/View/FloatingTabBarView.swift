//
//  FloatingTabBarView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 23/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 FloatingTabBarView presents the application tabs (Home, Phone, Contacts, History) for quick navigation across
 different app screens.
 
 It presents dynamic, fluid and animated UI/UX with the possibility to add and remove tabs at runtime.
 It also shows a indicator above the history tab for unread voice mails.
 */
struct FloatingTabBarView: View {
    
    // MARK: - Public properties
    
    @Binding var tabs: [FloatingTab]
    @Binding var selectedTab: FloatingTab
    @Binding var hasNewVM: Bool
    
    // MARK: - Private properties
    
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    @Namespace private var animation
    
    @State private var isAppearing = false
    @State private var backgroundColor: Color = .grey90
    @State private var tintColor: Color?
    
    // MARK: - UI/UX
    
    var body: some View {
        HStack(spacing: 8) {
            
            // Dynamic list of tabs
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { tab in
                    FloatingTabView(
                        selectedTab: $selectedTab,
                        tab: tab,
                        shouldShowVoiceMailIndicator: tab == .history && hasNewVM,
                        namespace: animation
                    ) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            selectedTab = tab
                        }
                    }
                }
            }
            .padding(.all, 8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(backgroundColor)
            )
            
            // Search Button
            if selectedTab == .contacts {
                Button(
                    action: {
                        NotificationCenter.default.post(name: .didTapOnFloatingTabBarSearchButton, object: nil)
                    },
                    label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(backgroundColor)
                                .frame(width: 56, height: 56)
                            
                            Image("search-tab-icon")
                                .resizable()
                                .renderingMode(.template)
                                .foregroundColor(tintColor)
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                        }
                    }
                )
                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .blur(radius: 12)
        )
        .shadow(color: backgroundColor.opacity(0.15), radius: 6, x: 0, y: 0)
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
        backgroundColor = scheme == .dark ? .white : .grey95
        tintColor = scheme == .dark ? .black : .white
    }
}
