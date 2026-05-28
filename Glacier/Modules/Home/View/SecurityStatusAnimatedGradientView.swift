//
//  SecurityStatusAnimatedGradientView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 19/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 SecurityStatusAnimatedGradientView shows linear grandient animation for,
 - Device securite scanning state
 - All clear from security risks state
 - Security risks found state
 */
struct SecurityStatusAnimatedGradientView: View {
    
    // MARK: - Public properties
    
    var height: CGFloat
    @Binding var isScanningForSecurityStatus: Bool
    @Binding var isSecured: Bool
    
    // MARK: - Private properties
    
    @State private var gradientOffset: CGFloat
    private let gradientHeight: CGFloat
    
    
    // MARK: - Initializer
    
    init(height: CGFloat, isScanningForSecurityStatus: Binding<Bool>, isSecured: Binding<Bool>) {
        self.height = height
        self._isScanningForSecurityStatus = isScanningForSecurityStatus
        self._isSecured = isSecured
        
        self.gradientOffset = 0
        self.gradientHeight = height * 3
    }
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .purple10,
                    .purple25,
                    .purple50,
                    .purpleMixedWithEmber,
                    .ember50,
                    .ember25,
                    .ember10
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: gradientHeight)
            .offset(y: gradientOffset)
            .clipped()
            .frame(height: height)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 24,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 24
                )
            )
            .drawingGroup()
        }
        .onChange(of: isScanningForSecurityStatus) { isScanning in
            if isScanning {
                withAnimation(.easeOut(duration: 0.5)) {
                    gradientOffset = 0
                }
            } else {
                withAnimation(.easeOut(duration: 0.5)) {
                    gradientOffset = isSecured ?  height : -height
                }
            }
        }
        // Belt-and-suspenders: animate to the correct color whenever the security
        // result changes without a full scan cycle (e.g. after a foreground resume
        // where onAppBecameActive sets isSecured but never toggles isScanningDevice).
        .onChange(of: isSecured) { secured in
            guard !isScanningForSecurityStatus else { return }
            withAnimation(.easeOut(duration: 0.5)) {
                gradientOffset = secured ? height : -height
            }
        }
    }
}
