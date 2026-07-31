//
//  SlidingCardView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 03/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI
import Lottie

/**
 SlidingCardView presents UI/UX for individual swiping cards.
 */
struct SlidingCardView: View {
    
    // MARK: - Public properties
    
    let card: SlidingCard
    
    // MARK: UI/UX
    
    var body: some View {
        ZStack {
            
            // Video or Image background
            if card.isVideo {
                ZStack {
                    SlidingCardBackgroundVideoPlayerView(
                        fileName: card.mediaName
                    )
                    .ignoresSafeArea()
                    
                    if card == .protection {
                        Rectangle()
                            .fill(Color.black.opacity(0.1))
                            .blur(radius: 10)
                            .ignoresSafeArea()
                    }
                }
                
                
            } else {
                GeometryReader { geo in
                    Image(card.mediaName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width,
                               height: geo.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
            }
            
            // Title, subtitle and lottie graphics/animation
            VStack(spacing: 0) {
                GlacierLabel(
                    text: card.title,
                    font: .neueHassGroteskFont(ofSize: 32),
                    textAlignment: .center,
                    allowsVerticalGrowth: true,
                    customTextColor: .constant(.white)
                )
                .padding(.horizontal, 40)

                GlacierLabel(
                    text: card.subtitle,
                    font: .bodyRegular,
                    textAlignment: .center,
                    allowsVerticalGrowth: true,
                    customTextColor: .constant(.white)
                )
                .padding(.top, 26)
                .padding(.horizontal, 75)

                if let animation = card.lottieAnimationName {
                    LottieView(animation: .named(animation))
                        .playing(loopMode: .loop)
                        .padding(.top, 24)
                        .padding(.horizontal, card.horizontalPadding)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if let graphics = card.graphicsName {
                    // Unlike the Lottie cards (which fill their frame), this is a static
                    // image constrained by .scaledToFit, so it can't grow vertically to
                    // fill the media area. Center it so the unavoidable leftover space is
                    // split above/below rather than all dumped between it and the buttons.
                    Image(graphics)
                        .resizable()
                        .scaledToFit()
                        .padding(.top, 24)
                        .padding(.horizontal, card.horizontalPadding)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .padding(.top, 90)
            // Reserve the bottom area occupied by the overlaid Sign Up / Log In buttons
            // (see UserAuthenticationHomeScreen) so the media never renders behind them.
            // At large Dynamic Type the media shrinks to fit the space above the buttons.
            .padding(.bottom, 200)
            .padding(.horizontal, 0)
        }
    }
}
