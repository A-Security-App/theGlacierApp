//
//  HeaderView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 24/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 HeaderView provides a dynamics and reusable header view for the main screens - Home, Phone, Contact, History.
 
 It shows dynamic content based on the active main screen. Like for Home, it shows plain title text along with settings button.
 For Phone screen, it first shows plain title with settings button but once user has phone number subscription and phoe number selected,
 it shows a link to present phone number selection popup.
 */
struct HeaderView: View {
    
    // MARK: - Public properties
    
    var titleText: String?
    var shouldShowPhoneNumberLink: Bool = false
    var activePhoneNumber: PhoneAccountModel?
    var height: CGFloat = 0
    var onPhoneNumberTapped: (() -> Void)
    var onSettingsButtonTapped: (() -> Void)
    
    // MARK: - Private properties
    
    private var phoneIdentity: String? {
        guard let phoneNumber = activePhoneNumber else { return nil }
        guard phoneNumber.hasValidDisplayName else {
            return phoneNumber.grdbRecord?.phoneNumber
        }
        return phoneNumber.grdbRecord?.displayName
    }
    
    private var gradientColorStops: [Color] {
        guard let number = activePhoneNumber,
              let avatarName = number.grdbRecord?.gradientAvatar,
              let avatar = PhoneNumberGradientAvatar(rawValue: avatarName) else {
            return [.blue100, .blue20]
        }
        return avatar.colorStops
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack(alignment: .bottom) {
            GlacierBackground()
                .frame(height: height)
            
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    ZStack {
                        if shouldShowPhoneNumberLink, activePhoneNumber != nil {
                            HStack(alignment: .center, spacing: 6) {
                                
                                // Gradient color pattern
                                LinearGradient(
                                    colors: gradientColorStops,
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(width: 16, height: 16)
                                .cornerRadius(2)
                                
                                // Phone display name or number
                                if let id = phoneIdentity {
                                    GlacierLabel(
                                        text: id,
                                        font: .headerTwo
                                    )
                                }
                                
                                // Right arrow icon
                                GlacierImage(
                                    name: .constant("right-arrow-small-icon"),
                                    width: 12,
                                    height: 12,
                                    shouldAdaptToColorSchemeChange: true
                                )
                            }
                            .onTapGesture {
                                onPhoneNumberTapped()
                            }
                            
                        }
                        else if let title = titleText {
                            GlacierLabel(
                                text: title,
                                font: .headerTwo
                            )
                        }
                    }
                    
                    Spacer()
                    
                    GlacierImageButton(
                        name: "settings-icon",
                        imageWidth: 16,
                        imageHeight: 16,
                        backgroundOpacity: 0
                    ) {
                        onSettingsButtonTapped()
                    }
                }
                .padding(.horizontal, 16)
                
                GlacierLineSeparator()
                    .padding(.top, 24)
            }
        }
    }
}
