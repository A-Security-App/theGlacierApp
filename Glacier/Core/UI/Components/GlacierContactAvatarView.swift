//
//  GlacierContactAvatarView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 27/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierContactAvatarView displays,
 - Contact photo, if available.
 - If photo isn't available, it shows name initials
 - If name isn't available, it shows generic user icon.
 */
struct GlacierContactAvatarView: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject var glacierColorScheme: GlacierColorScheme
    
    @Binding private var foregroundColor: Color?
    @Binding private var backgroundColor: Color?
    
    private var contact: PhoneContact
    private var size: CGFloat
    private var fontSize: CGFloat
    private var defaultAvatarSize: CGFloat
    private var cornerRadius: CGFloat
    
    // MARK: - Initializer
    
    init(
        contact: PhoneContact,
        size: CGFloat = 104,
        fontSize: CGFloat = 32,
        defaultAvatarSize: CGFloat = 28,
        cornerRadius: CGFloat = 32,
        foregroundColor: Binding<Color?> = .constant(nil),
        backgroundColor: Binding<Color?> = .constant(nil)
    ) {
        self.contact = contact
        self.size = size
        self.fontSize = fontSize
        self.defaultAvatarSize = defaultAvatarSize
        self.cornerRadius = cornerRadius
        
        self._foregroundColor = foregroundColor
        self._backgroundColor = backgroundColor
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            
            // Background
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(backgroundColor ?? .white)
                .frame(width: size, height: size)
            
            if let avatarImage = contact.avatar {
                Image(uiImage: avatarImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .cornerRadius(cornerRadius)
                
            } else if !contact.initials.isEmpty {
                GlacierLabel(
                    text: contact.initials,
                    font: .neueHassGroteskThickFont(ofSize: fontSize),
                    customTextColor: $foregroundColor
                )
            }
        }
    }
}
