//
//  SecuritySettingsProgressView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 20/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 SecuritySettingsProgressView shows the percentage of required device settings set to enabled.
 When all of the required device settings are enabled, it shows full progress with highlight colored know. Else,
 it shows the relavent progress with ember colored knob so that users could be aware of the missing settings.
 */
struct SecuritySettingsProgressView: View {
    
    // MARK: - Public properties
    
    @Binding var securitySettings: [DeviceSecuritySetting]
    let width: CGFloat
    let height: CGFloat
    
    // MARK: - Private properties
    
    @State private var enabledSettingsCount: Int = 0
    
    private var totalCount: Int {
        securitySettings.count
    }
    
    private var progress: Double {
        guard totalCount > 0 else { return 0 }
        return min(Double(enabledSettingsCount) / Double(totalCount), 1.0)
    }
    
    private var areAllSettingsEnabled: Bool {
        enabledSettingsCount >= totalCount && totalCount > 0
    }
    
    private var trackHeight: CGFloat {
        return height
    }
    
    private var knobDiameter: CGFloat {
        return height - knobStrokeWidth * 2
    }
    
    private var knobStrokeWidth: CGFloat {
        return 1
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack(alignment: .leading) {
            // Background
            Capsule()
                .fill(Color.grey20)
                .frame(height: trackHeight)
            
            // Progress indicator
            Circle()
                .fill(areAllSettingsEnabled ? Color.highlight : Color.ember)
                .frame(width: knobDiameter, height: knobDiameter)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: knobStrokeWidth)
                )
                .offset(x: knobOffset(for: width))
        }
        .frame(width: width, height: height)
        .clipped()
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: progress)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: areAllSettingsEnabled)
        .onChange(of: securitySettings) { _ in
            updateEnabledSettingsCount()
        }
        .onAppear {
            updateEnabledSettingsCount()
        }
    }
    
    // MARK: - Private methods
    
    private func updateEnabledSettingsCount() {
        let enabledSettings = securitySettings.filter({ $0.isEnabled })
        enabledSettingsCount = enabledSettings.count
    }
    private func knobOffset(for trackWidth: CGFloat) -> CGFloat {
        // Center of knob follows progress but we clamp so knob never goes outside the track
        let availableTravel = trackWidth - (knobDiameter + knobStrokeWidth)
        let rawPosition = availableTravel * progress
        let clampedPosition = max(knobStrokeWidth, min(rawPosition, availableTravel))
        return clampedPosition
    }
}
