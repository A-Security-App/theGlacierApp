//
//  PhoneNumberMenuItemView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 26/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 PhoneNumberMenuItemView shows details like display name, number, active number state, etc.  for a given phone number.
 */
struct PhoneNumberMenuItemView: View {
    
    // MARK: - Public properties
    
    var number: PhoneAccountModel
    var activePhoneNumber: String?
    var shouldShowCopyNumberButton: Bool = false
    var shouldShowMenuButton: Bool = false
    var height: CGFloat = 70
    var cornerRadius: CGFloat = 16
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 16
    
    @Binding var primaryTextColor: Color?
    @Binding var secondaryTextColor: Color?
    @Binding var activePhoneNumberBackgroundColor: Color
    @Binding var backgroundColor: Color
    
    var onCopyNumberButtonTap: (() -> Void)?
    var onMenuButtonTap: ((CGRect) -> Void)?
    
    // MARK: - Private properties
    
    private var displayName: String? {
        number.grdbRecord?.displayName
    }
    
    private var phoneNumber: String? {
        number.grdbRecord?.phoneNumber
    }
    
    private var isActiveNumber: Bool {
        guard let phoneNumber = activePhoneNumber else { return false }
        return number.grdbRecord?.phoneNumber == phoneNumber
    }
    
    private var gradientColorStops: [Color] {
        guard let avatarName = number.grdbRecord?.gradientAvatar,
              let avatar = PhoneNumberGradientAvatar(rawValue: avatarName) else {
            return [.blue100, .blue20]
        }
        return avatar.colorStops
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(isActiveNumber ? activePhoneNumberBackgroundColor : backgroundColor)
                .frame(maxWidth: .infinity)
                .frame(height: height)
            
            HStack(alignment: .center, spacing: 12) {
                
                LinearGradient(
                    colors: gradientColorStops,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: 16, height: 16)
                .cornerRadius(2)
                
                VStack(alignment: .leading, spacing: 8) {
                    if number.hasValidDisplayName, let name = displayName {
                        GlacierLabel(
                            text: name,
                            font: .bodyThick,
                            customTextColor: $primaryTextColor
                        )
                    }
                    if let pNumber = phoneNumber {
                        HStack(alignment: .center, spacing: 4) {
                            GlacierLabel(
                                text: pNumber,
                                font: .bodyThick,
                                customTextColor: !number.hasValidDisplayName ? $primaryTextColor : $secondaryTextColor
                            )
                            
                            if shouldShowCopyNumberButton {
                                Button(
                                    action: {
                                        onCopyNumberButtonTap?()
                                    },
                                    label: {
                                        GlacierImage(
                                            name: .constant("copy-icon"),
                                            width: 16,
                                            height: 18,
                                            shouldAdaptToColorSchemeChange: false,
                                            customTintColor: $secondaryTextColor
                                        )
                                    }
                                )
                                .frame(width: 24, height: 24)
                            }
                        }
                    }
                }
                
                Spacer()
                
                if shouldShowMenuButton {
                    GeometryReader { proxy in
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isActiveNumber ? activePhoneNumberBackgroundColor : backgroundColor)
                                .frame(width: 40, height: 40)
                            
                            GlacierImage(
                                name: .constant("three-dot-icon"),
                                width: 24,
                                height: 8,
                                shouldAdaptToColorSchemeChange: false,
                                customTintColor: .constant(.grey60)
                            )
                            .frame(width: 24, height: 24)
                        }
                        .onTapGesture {
                            let frame = proxy.frame(in: .named("container"))
                            onMenuButtonTap?(frame)
                        }
                    }
                    .frame(width: 40, height: 40)
                } else {
                    if isActiveNumber {
                        GlacierImage(
                            name: .constant("tick-icon"),
                            width: 11,
                            height: 11,
                            shouldAdaptToColorSchemeChange: false,
                            customTintColor: $primaryTextColor
                        )
                    }
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        }
    }
}
