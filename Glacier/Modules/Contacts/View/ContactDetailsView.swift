//
//  ContactDetailsView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 28/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 ContactDetailsView shows name, phone number, avatar image and other details for the given contact
 */
struct ContactDetailsView: View {
    
    // MARK: - Public properties
    
    var contact: PhoneContact
    @Binding var backgroundColor: Color?
    @Binding var secondaryTextColor: Color?
    @Binding var avatarForegroundColor: Color?
    @Binding var avatarBackgroundColor: Color?
    var action: () -> Void
    
    // MARK: - Private properties
    
    @State private var hasValidName = true
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor ?? .grey10)
                .frame(height: 80)
            
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 16) {
                    GlacierContactAvatarView(
                        contact: contact,
                        size: 48,
                        fontSize: 12,
                        defaultAvatarSize: 24,
                        cornerRadius: 16,
                        foregroundColor: $avatarForegroundColor,
                        backgroundColor: $avatarBackgroundColor
                    )
                    
                    VStack(alignment: .leading, spacing: 8) {
                        if !contact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            GlacierLabel(
                                text: contact.name,
                                font: .bodyThick
                            )
                        }

                        GlacierLabel(
                            text: contact.phoneNumber,
                            font: .bodyThick,
                            customTextColor: !contact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $secondaryTextColor : .constant(nil)
                        )
                    }

                    Spacer()
                    
                    if !contact.phoneLabel.isEmpty {
                        GlacierLabel(text: contact.phoneLabel, font: .bodySmallThick)
                            .padding(.all, 8)
                            .background(GlacierBackground(cornerRadius: 8))
                    }
                    
                    Button(
                        action: {
                            action()
                        },
                        label: {
                            GlacierViewContainer(cornerRadius: 16, padding: 15, darkColor: .grey70, lightColor: .grey30) {
                                GlacierImage(
                                    name: .constant("dial-icon"),
                                    width: 20,
                                    height: 20,
                                    shouldAdaptToColorSchemeChange: true
                                )
                            }
                        }
                    )
                }
                
                GlacierLineSeparator()
            }
        }
        .onAppear {
            hasValidName = !contact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
