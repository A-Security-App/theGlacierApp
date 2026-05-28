//
//  VoicemailItemDetailsView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 01/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 VoicemailItemDetailsView shows name, phone number, avatar image, time stamp and other details for the given voicemail record.
 */
struct VoicemailItemDetailsView: View {
    
    // MARK: - Public properties
    
    var voiceMail: VoicemailRecord
    @Binding var backgroundColor: Color?
    @Binding var secondaryTextColor: Color?
    @Binding var avatarForegroundColor: Color?
    @Binding var avatarBackgroundColor: Color?
    var action: () -> Void
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @State private var hasValidName = true
    
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
                        
                        if voiceMail.status == "unread" || voiceMail.status == "new" {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.highlight)
                                .frame(width: 8, height: 8)
                                .offset(x: 20, y: -20)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(glacierColorScheme.activeScheme == .light ? .white : .black, lineWidth: 1)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 20, y: -20)
                                }
                        }
                        
                        if let contact = voiceMail.contact {
                            if let image = contact.avatar {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 48, height: 48)
                                    .cornerRadius(16)
                            } else if let initial = getInitials(from: contact.name) {
                                GlacierLabel(
                                    text: initial,
                                    font: .bodySmallThick,
                                    customTextColor: $avatarForegroundColor
                                )
                            }
                        } else {
                            Image("user-icon")
                                .resizable()
                                .renderingMode(.template)
                                .foregroundColor(avatarForegroundColor ?? .grey20)
                                .scaledToFit()
                                .frame(width: 15, height: 15)
                            
                        }
                    }
                    
                    // Name and phone number
                    VStack(alignment: .leading, spacing: 8) {
                        if let contact = voiceMail.contact, contact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            GlacierLabel(
                                text: contact.name,
                                font: .bodyThick
                            )
                        }
                        
                        if let phoneNumber = voiceMail.from {
                            GlacierLabel(
                                text: phoneNumber,
                                font: .bodyThick,
                                customTextColor: hasValidName ? $secondaryTextColor : .constant(nil)
                            )
                        }
                    }
                    
                    Spacer()
                    
                    // Date and time and voicemail audio length
                    VStack(alignment: .trailing, spacing: 8) {
                        if let date = voiceMail.time {
                            GlacierLabel(
                                text: GlacierDateFormatter.timestamp(for: date, style: .compact),
                                font: .bodyThick
                            )
                        }
                        
                        if let duration = voiceMail.duration, let intDuration = Int(duration) {
                            GlacierLabel(
                                text: getFormattedAudioDuration(for: intDuration),
                                font: .bodyThick,
                                customTextColor: $secondaryTextColor
                            )
                        }
                    }
                }
                
                GlacierLineSeparator()
            }
        }
        .onAppear {
            guard let contact = voiceMail.contact else {
                hasValidName = false
                return
            }
            hasValidName = !contact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    
    // MARK: - Private methods
    
    private func getInitials(from string: String) -> String? {
        guard let initial = GlacierImages.stringInitials(withMaxCharacters: string, maxCharacters: 2) else {
            return nil
        }
        return initial
    }
    
    private func getFormattedAudioDuration(for seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%01d:%02d", minutes, remainingSeconds)
    }
}
