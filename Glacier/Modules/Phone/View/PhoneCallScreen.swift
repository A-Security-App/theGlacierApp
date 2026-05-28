//
//  PhoneCallScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 27/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 PhoneCallScreen presents UI/UX for making and recieving phone calls.
 
 On successful phone call connection, it sets the state to `connected` and updates UI with contact details, call duration, etc.
 It lets user perform in call functions like mute/unmute options, change audio route, and end call.
 */
struct PhoneCallScreen<ViewModel: PhoneCallViewModel & ObservableObject>: View {
    
    // MARK: - Private properties

    @EnvironmentObject private var appCoordinator: GlacierAppRootCoordinator
    @ObservedObject private var viewModel: ViewModel
    @State private var showAudioRoutePicker = false
    
    private var contactId: String? {
        guard let contact = viewModel.phoneContact else {
            return nil
        }
        
        guard !contact.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return contact.phoneNumber
        }
        return contact.name
    }
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            Color.grey95
                .ignoresSafeArea()
            
            VStack(alignment: .center, spacing: 0) {
                Spacer()
                
                // Contact detail
                VStack(alignment: .center, spacing: 24) {
                    
                    // Avatar image or name initials or default user icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 32)
                            .fill(Color.grey20)
                            .frame(width: 104, height: 104)
                        
                        if let contact = viewModel.phoneContact {
                            
                            // Show contact image, if available
                            if let image = contact.avatar {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 104, height: 104)
                                    .cornerRadius(32)
                                
                            }
                            // Else, show user name, if available
                            else if !contact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let initial = getInitials(from: contact.name) {
                                GlacierLabel(
                                    text: initial,
                                    font: .neueHassGroteskThickFont(ofSize: 32),
                                    customTextColor: .constant(.black)
                                )
                            }
                            // Else, show default user icon for this unknown contact
                            else {
                                Image("user-icon")
                                    .resizable()
                                    .renderingMode(.template)
                                    .foregroundColor(.black)
                                    .scaledToFit()
                                    .frame(width: 44, height: 44)
                            }
                        }
                    }
                    
                    // Contact name or phone number
                    if let id = contactId {
                        GlacierLabel(
                            text: id,
                            font: .headerOne,
                            customTextColor: .constant(.white)
                        )
                    }
                }
                .padding(.horizontal, 24)
                
                Spacer()
                
                // Voice call control buttons
                HStack(alignment: .center, spacing: 32) {
                    
                    // Change audio route button
                    Button(
                        action: {
                            showAudioRoutePicker = true
                        },
                        label: {
                            VStack(alignment: .center, spacing: 8) {
                                ZStack {
                                    Circle()
                                        .fill(Color.grey90)
                                        .frame(width: 72, height: 72)

                                    GlacierImage(
                                        name: .constant(viewModel.activeAudioRoute.icon),
                                        width: 32,
                                        height: 32,
                                        shouldAdaptToColorSchemeChange: false,
                                        customTintColor: .constant(.white)
                                    )
                                }

                                GlacierLabel(
                                    text: viewModel.activeAudioRoute.label,
                                    font: .bodyRegular,
                                    customTextColor: .constant(.grey40)
                                )
                            }
                        }
                    )
                    .confirmationDialog(
                        NSLocalizedString("Audio Route", comment: "Phone call screen audio route picker title"),
                        isPresented: $showAudioRoutePicker,
                        titleVisibility: .visible
                    ) {
                        Button(NSLocalizedString("Speaker", comment: "Phone call screen audio route speaker option")) {
                            viewModel.selectAudioRoute(.speaker)
                        }
                        Button(NSLocalizedString("Microphone", comment: "Phone call screen audio route microphone option")) {
                            viewModel.selectAudioRoute(.microphone)
                        }
                        if viewModel.isBluetoothAvailable {
                            Button(NSLocalizedString("Bluetooth", comment: "Phone call screen audio route bluetooth option")) {
                                viewModel.selectAudioRoute(.bluetooth)
                            }
                        }
                        Button(NSLocalizedString("Cancel", comment: "Cancel button title"), role: .cancel) {}
                    }
                    
                    // End call button
                    Button(
                        action: {
                            viewModel.endCall()
                        },
                        label: {
                            VStack(alignment: .center, spacing: 8) {
                                ZStack {
                                    Circle()
                                        .fill(Color.ember)
                                        .frame(width: 72, height: 72)
                                    
                                    GlacierImage(
                                        name: .constant("end-call-icon"),
                                        width: 32,
                                        height: 32,
                                        shouldAdaptToColorSchemeChange: false,
                                        customTintColor: .constant(.white)
                                    )
                                }
                                
                                GlacierLabel(
                                    text: NSLocalizedString("End", comment: "Phone call screen end button title"),
                                    font: .bodyRegular,
                                    customTextColor: .constant(.grey40)
                                )
                            }
                        }
                    )
                    
                    // Mute/unmute toggle button
                    Button(
                        action: {
                            viewModel.toggleMuteAudio()
                        },
                        label: {
                            VStack(alignment: .center, spacing: 8) {
                                ZStack {
                                    Circle()
                                        .fill(viewModel.muteButtonBGColor)
                                        .frame(width: 72, height: 72)
                                    
                                    GlacierImage(
                                        name: .constant(viewModel.isMuted ? "muted-mic-icon" : "mic-icon"),
                                        width: 32,
                                        height: 32,
                                        shouldAdaptToColorSchemeChange: false,
                                        customTintColor: .constant(viewModel.muteButtonTintColor)
                                    )
                                }
                                
                                GlacierLabel(
                                    text: viewModel.isMuted ? NSLocalizedString("Unmute", comment: "Phone call screen unmute button title") : NSLocalizedString("Mute", comment: "Phone call screen mute button title"),
                                    font: .bodyRegular,
                                    customTextColor: .constant(.grey40)
                                )
                            }
                        }
                    )
                }
                .padding(.horizontal, 48)
                
            }
            .padding(.horizontal, 0)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let callStatus = viewModel.callStatus {
                ToolbarItem(placement: .principal) {
                    GlacierLabel(
                        text: callStatus == .connected ? viewModel.callDurationLabel : callStatus.label,
                        font: .headerTwo,
                        customTextColor: .constant(.grey60)
                    )
                }
            }
        }
        .onAppear {
            appCoordinator.isViewingPhoneCallScreen = true
        }
        .onFirstAppear {
            viewModel.startCall()
        }
        .onDisappear {
            appCoordinator.isViewingPhoneCallScreen = false
        }
    }
    
    // MARK: - Private methods
    
    private func getInitials(from string: String) -> String? {
        guard let initial = GlacierImages.stringInitials(withMaxCharacters: string, maxCharacters: 2) else {
            return nil
        }
        return initial
    }
}

