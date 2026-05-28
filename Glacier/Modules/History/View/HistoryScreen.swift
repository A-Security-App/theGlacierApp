//
//  HistoryScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 01/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 HistoryScreen presents the history module home view.
 It lets user switch to call history and voicemails screens for viewing specific history logs.
 */
struct HistoryScreen<ViewModel: HistoryViewModel & ObservableObject>: View, PhoneNumberMenuCoordinator {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @ObservedObject private var viewModel: ViewModel
    
    @State private var isAppearing = false
    @State private var tabSelectedColor: Color = .grey30
    @State private var tabBorderColor: Color = .grey20
    
    @State private var secondaryTextColor: Color?
    @State private var avatarForegroundColor: Color?
    @State private var avatarBackgroundColor: Color?
    @State private var backgroundColor: Color?
    
    private let horizontalPadding: CGFloat = 16
    private var tabWidth: CGFloat {
        let width = (UIScreen.main.bounds.width - horizontalPadding * 2) / 2
        return width
    }
    
    // MARK: - Initilizer
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
                .onTapGesture {
                    hidePhoneNumberMenu()
                }
            
            VStack(alignment: .center, spacing: 4) {
                
                // Tab bar
                HStack(alignment: .center, spacing: 0) {
                    ForEach([HistoryScreenTab.callHistory, HistoryScreenTab.voicemail], id: \.id) { tab in
                        Button(
                            action: {
                                viewModel.selectedTab = tab
                            },
                            label: {
                                ZStack {
                                    Rectangle()
                                        .fill(viewModel.selectedTab == tab ? tabSelectedColor : .clear)
                                        .frame(width: tabWidth, height: 45)
                                    
                                    HStack(alignment: .center, spacing: 8) {
                                        GlacierLabel(
                                            text: tab.title,
                                            font: .bodyThick
                                        )
                                        
                                        if case .voicemail = tab, viewModel.hasNewVM {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(Color.highlight)
                                                .frame(width: 8, height: 8)
                                                .overlay {
                                                    RoundedRectangle(cornerRadius: 2)
                                                        .stroke(glacierColorScheme.activeScheme == .light ? .white : .black, lineWidth: 1)
                                                        .frame(width: 8, height: 8)
                                                }
                                        }
                                    }
                                }
                            }
                        )
                    }
                }
                .cornerRadius(16)
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(tabBorderColor, lineWidth: 1)
                }
                
                // Call history and Voicemail screens
                Group {
                    switch viewModel.selectedTab {
                    case .callHistory:
                        callHistoryScreen
                    case .voicemail:
                        voicemailScreen
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .onFirstAppear {
            viewModel.initialize()
        }
        .onAppear {
            isAppearing = true
            setupColors(for: glacierColorScheme.activeScheme)
            
            viewModel.getHistoricalData()
        }
        .onDisappear {
            isAppearing = false
        }
        .onChange(of: glacierColorScheme.activeScheme) { newScheme in
            guard isAppearing else { return }
            setupColors(for: newScheme)
        }
    }
    
    // MARK: - Screen elements
    
    private var callHistoryScreen: some View {
        CallHistoryScreen(
            viewModel: viewModel,
            backgroundColor: $backgroundColor,
            secondaryTextColor: $secondaryTextColor,
            avatarForegroundColor: $avatarForegroundColor,
            avatarBackgroundColor: $avatarBackgroundColor
        )
    }
    
    private var voicemailScreen: some View {
        VoicemailsScreen(
            viewModel: viewModel,
            backgroundColor: $backgroundColor,
            secondaryTextColor: $secondaryTextColor,
            avatarForegroundColor: $avatarForegroundColor,
            avatarBackgroundColor: $avatarBackgroundColor
        )
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        tabSelectedColor = scheme == .dark ? .grey70 : .grey30
        tabBorderColor = scheme == .dark ? .grey90 : .grey20
        backgroundColor = scheme == .dark ? .grey95 : .grey10
        secondaryTextColor = scheme == .dark ? .grey40 : .grey60
        avatarBackgroundColor = scheme == .dark ? .grey20 : .grey90
        avatarForegroundColor = scheme == .dark ? .black : .white
    }
}
