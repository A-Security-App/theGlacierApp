//
//  CallHistoryItemDetailsView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 01/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 CallHistoryItemDetailsView shows name, phone number, avatar image, time stamp and other details for the given call history record.
 */
struct CallHistoryItemDetailsView: View {
    
    // MARK: - Public properties
    
    var callRecord: CallRecord
    @Binding var backgroundColor: Color?
    @Binding var secondaryTextColor: Color?
    @Binding var avatarForegroundColor: Color?
    @Binding var avatarBackgroundColor: Color?
    var action: () -> Void
    
    // MARK: - Private properties
    
    @State private var hasValidName = true
    
    private var initials: String {
        var initials = GlacierImages.stringInitials(withMaxCharacters: callRecord.name, maxCharacters: 2) ?? ""
        if initials.isEmpty {
            initials = GlacierImages.stringInitials(withMaxCharacters: callRecord.phoneNumber, maxCharacters: 2) ?? ""
        }
        return initials
    }
    
    private var avatarImage: UIImage? {
        let phoneNumber = callRecord.isIncoming ? callRecord.from : callRecord.to
        guard let matchingContact = ContactsManager.shared.matchContact(for: phoneNumber) else {
            return nil
        }
        return matchingContact.avatar
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor ?? .grey10)
                .frame(height: 80)
            
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 16) {
                    
                    // Avatar image or name initials
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(avatarBackgroundColor ?? .grey10)
                            .frame(width: 48, height: 48)
                        
                        if let image = avatarImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                                .cornerRadius(16)
                            
                        } else {
                            GlacierLabel(
                                text: initials,
                                font: .neueHassGroteskThickFont(ofSize: 12),
                                customTextColor: $avatarForegroundColor
                            )
                        }
                    }
                    
                    // Name and phone number
                    VStack(alignment: .leading, spacing: 8) {
                        if !callRecord.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            GlacierLabel(
                                text: callRecord.name,
                                font: .bodyThick
                            )
                        }
                        
                        HStack(alignment: .center, spacing: 2) {
                            GlacierImage(
                                name: .constant(callRecord.isIncoming ? "incoming-call-icon" : "outgoing-call-icon"),
                                width: 16, height: 16,
                                shouldAdaptToColorSchemeChange: false,
                                customTintColor: $secondaryTextColor
                            )
                            
                            GlacierLabel(
                                text: callRecord.phoneNumber,
                                font: .bodyThick,
                                customTextColor: hasValidName ? $secondaryTextColor : .constant(nil)
                            )
                        }
                    }
                    
                    Spacer()
                    
                    
                    HStack(alignment: .center, spacing: 8) {

                        // Timestamp
                        GlacierLabel(
                            text: GlacierDateFormatter.timestamp(for: callRecord.startTime, style: .compact),
                            font: .bodySmallThick,
                            customTextColor: $secondaryTextColor
                        )

                        // Call button
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
                }
                
                GlacierLineSeparator()
            }
        }
        .onAppear {
            hasValidName = !callRecord.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
