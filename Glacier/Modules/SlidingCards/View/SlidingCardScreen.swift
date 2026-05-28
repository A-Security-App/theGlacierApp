//
//  SlidingCardScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 02/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 SlidingCardScreen presents horizontally scrollable cards that explain core app features.
 It uses video, image assets along with Lottie animation JSON for custom drawing.
 
 Users can swipe left/right to see previous and next cards.
 */
struct SlidingCardScreen: View {
    
    // MARK: - Private properties
    
    @State private var selectedTab = 0
    
    // MARK: - Initializer
    
    init() {
        UIScrollView.appearance().bounces = false
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                ForEach(SlidingCard.allCases) { card in
                    SlidingCardView(card: card)
                        .tag(card.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    ForEach(SlidingCard.allCases) { card in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(selectedTab == card.id ? .white : .white.opacity(0.4))
                            .frame(width: selectedTab == card.id ? 24 : 8, height: 8)
                            .animation(.spring(), value: selectedTab)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 208)
        }
    }
}
