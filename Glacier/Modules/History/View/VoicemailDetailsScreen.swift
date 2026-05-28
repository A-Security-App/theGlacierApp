//
//  VoicemailDetailsScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 01/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 VoicemailDetailsScreen shows voicemail details like sender name, image, phone number, voicemail date/time, etc.
 It presents UI/UX for voicemail playback and deletion.
 */
struct VoicemailDetailsScreen<ViewModel: VoiceMailDetailsViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @StateObject private var viewModel: ViewModel
    
    @State private var isAppearing = false
    @State private var backgroundColor: Color?
    @State private var buttonBackgroundColor: Color = .grey70
    @State private var secondaryTextColor: Color?
    @State private var avatarForegroundColor: Color?
    @State private var avatarBackgroundColor: Color?
    
    @State private var hasValidName = true

    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
            
            VStack(alignment: .leading) {
                GlacierLineSeparator(lineThickness: 1)
                
                VStack(spacing: 16) {
                    
                    // Date and time stamp
                    if let dateAndTime = viewModel.voiceMail.time {
                        GlacierLabel(
                            text: GlacierDateFormatter.timestamp(for: dateAndTime, style: .detailed),
                            font: .bodySmallThick,
                            textAlignment: .center,
                            customTextColor: $secondaryTextColor
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                    }
                    
                    // Playback slider
                    HStack(alignment: .center, spacing: 8) {
                        GlacierLabel(
                            text: viewModel.formatTime(viewModel.currentTime),
                            font: .bodySmallThick,
                            customTextColor: $secondaryTextColor
                        )
                        .frame(width: 40, alignment: .trailing)
                        
                        Slider(
                            value: $viewModel.currentTime,
                            in: 0...(viewModel.duration > 0 ? viewModel.duration : 1),
                            onEditingChanged: { dragging in
                                if dragging {
                                    viewModel.beginScrubbing()
                                } else {
                                    viewModel.endScrubbing(at: viewModel.currentTime)
                                }
                            }
                        )
                        
                        GlacierLabel(
                            text: viewModel.formatTime(viewModel.duration),
                            font: .bodySmallThick,
                            customTextColor: $secondaryTextColor
                        )
                        .frame(width: 40, alignment: .leading)
                    }
                    .padding(.top, 90)
                    
                    // Playback controls
                    HStack(spacing: 0) {
                        
                        Spacer()
                        
                        // Rewind button
                        Button(
                            action: {
                                viewModel.rewind()
                            },
                            label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(buttonBackgroundColor)
                                        .frame(width: 44, height: 44)
                                    
                                    GlacierImage(
                                        name: .constant("rewind-icon"),
                                        width: 20,
                                        height: 20,
                                        shouldAdaptToColorSchemeChange: true
                                    )
                                }
                            }
                        )
                        
                        // Play/Pause button
                        Button(
                            action: {
                                viewModel.togglePlayback()
                            },
                            label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 24)
                                        .fill(viewModel.playButtonBackgroundColor ?? .grey70)
                                        .frame(width: 56, height: 56)
                                    
                                    GlacierImage(
                                        name: .constant(viewModel.isPlaying ? "pause-icon" : "play-icon"),
                                        width: 32,
                                        height: 32,
                                        shouldAdaptToColorSchemeChange: false,
                                        customTintColor: $viewModel.playButtonTintColor
                                    )
                                }
                            }
                        )
                        .padding(.horizontal, 32)
                        
                        // Speaker button
                        Button(
                            action: {
                                viewModel.toggleSpeakerOutput()
                            },
                            label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(viewModel.speakerButtonBackgroundColor ?? .grey70)
                                        .frame(width: 44, height: 44)
                                    
                                    GlacierImage(
                                        name: .constant("speaker-icon"),
                                        width: 20,
                                        height: 20,
                                        shouldAdaptToColorSchemeChange: false,
                                        customTintColor: $viewModel.speakerButtonTintColor
                                    )
                                }
                            }
                        )
                        
                        // Delete button
                        Button(
                            action: {
                                viewModel.presentDeleteVoiceMailConfirmationPopup()
                            },
                            label: {
                                GlacierImage(
                                    name: .constant("trash-icon"),
                                    width: 25,
                                    height: 25,
                                    shouldAdaptToColorSchemeChange: true
                                )
                            }
                        )
                        .padding(.leading, 32)
                    }
                    .padding(.top, 40)
                    .padding(.horizontal, 8)
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, 0)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                senderDetailsView
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                callButton
            }
        }
        .onFirstAppear {
            viewModel.initialize()
        }
        .onAppear {
            isAppearing = true
            viewModel.activeColorScheme = glacierColorScheme.activeScheme
            setupColors(for: glacierColorScheme.activeScheme)
            
            guard let contact = viewModel.voiceMail.contact else {
                hasValidName = false
                return
            }
            hasValidName = !contact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onDisappear {
            isAppearing = false
            viewModel.tearDownPlayer()
        }
        .onChange(of: glacierColorScheme.activeScheme) { newScheme in
            guard isAppearing else { return }
            viewModel.activeColorScheme = newScheme
            setupColors(for: newScheme)
        }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        backgroundColor = scheme == .dark ? .grey95 : .grey10
        buttonBackgroundColor = scheme == .dark ? .grey70 : .grey30
        secondaryTextColor = scheme == .dark ? .grey40 : .grey60
        avatarBackgroundColor = scheme == .dark ? .grey20 : .grey90
        avatarForegroundColor = scheme == .dark ? .black : .white
    }
    
    private func getInitials(from string: String) -> String? {
        guard let initial = GlacierImages.stringInitials(withMaxCharacters: string, maxCharacters: 2) else {
            return nil
        }
        return initial
    }
    
    // MARK: - Screen elements
    
    private var senderDetailsView: some View {
        HStack(alignment: .center, spacing: 16) {
            
            // Avatar image or name initials
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(avatarBackgroundColor ?? .grey10)
                    .frame(width: 32, height: 32)
                
                if let contact = viewModel.voiceMail.contact {
                    if let image = contact.avatar {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
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
                if let contact = viewModel.voiceMail.contact, contact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    GlacierLabel(
                        text: contact.name,
                        font: .bodyThick
                    )
                }
                
                if let phoneNumber = viewModel.voiceMail.from {
                    GlacierLabel(
                        text: phoneNumber,
                        font: .bodyThick,
                        customTextColor: hasValidName ? $secondaryTextColor : .constant(nil)
                    )
                }
            }
            
            Spacer()
        }
    }
    
    private var callButton: some View {
        Button(
            action: {
                viewModel.startCall()
            },
            label: {
                GlacierImage(
                    name: .constant("dial-icon"),
                    width: 20,
                    height: 20,
                    shouldAdaptToColorSchemeChange: true
                )
            }
        )
    }
}
