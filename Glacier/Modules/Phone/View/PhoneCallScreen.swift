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
 It lets user perform in call functions like mute/unmute options, change audio route, send DTMF tones, and end call.
 */
struct PhoneCallScreen<ViewModel: PhoneCallViewModel & ObservableObject>: View {
    
    // MARK: - Private properties

    @EnvironmentObject private var appCoordinator: GlacierAppRootCoordinator
    @ObservedObject private var viewModel: ViewModel
    @State private var showAudioRoutePicker = false
    @State private var showKeypad = false
    
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
                
                // Voice call control buttons. Three controls sit on the top row and the end
                // call button gets its own row below — four 72pt circles don't fit across a
                // single row on any current iPhone width.
                VStack(alignment: .center, spacing: 24) {
                    HStack(alignment: .top, spacing: 32) {
                        audioRouteButton
                        keypadButton
                        muteButton
                    }
                    
                    endCallButton
                }
                .padding(.horizontal, 48)
                
            }
            .padding(.horizontal, 0)
            .padding(.top, 8)
            .padding(.bottom, 40)
            
            // In-call DTMF keypad, drawn over the call detail while visible.
            if showKeypad {
                PhoneCallKeypadView(
                    digits: viewModel.dtmfDigits,
                    onDigit: { digit in
                        viewModel.sendDTMF(digit)
                    },
                    onHide: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showKeypad = false
                        }
                    },
                    onEndCall: {
                        viewModel.endCall()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }
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
    
    // MARK: - Call control buttons
    
    private var audioRouteButton: some View {
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
    }
    
    /// Opens the in-call keypad for navigating IVR menus ("press 1 for…"), extensions and PINs.
    private var keypadButton: some View {
        Button(
            action: {
                // Start each visit with an empty readout so digits from an earlier menu
                // don't run together with the ones being entered now.
                viewModel.clearDTMFDigits()
                withAnimation(.easeOut(duration: 0.2)) {
                    showKeypad = true
                }
            },
            label: {
                VStack(alignment: .center, spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.grey90)
                            .frame(width: 72, height: 72)
                        
                        GlacierImage(
                            systemName: .constant("circle.grid.3x3.fill"),
                            width: 32,
                            height: 32,
                            shouldAdaptToColorSchemeChange: false,
                            customTintColor: .constant(.white)
                        )
                    }
                    
                    GlacierLabel(
                        text: NSLocalizedString("Keypad", comment: "Phone call screen keypad button title"),
                        font: .bodyRegular,
                        customTextColor: .constant(.grey40)
                    )
                }
            }
        )
    }
    
    private var muteButton: some View {
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
    
    private var endCallButton: some View {
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
    }
    
    // MARK: - Private methods
    
    private func getInitials(from string: String) -> String? {
        guard let initial = GlacierImages.stringInitials(withMaxCharacters: string, maxCharacters: 2) else {
            return nil
        }
        return initial
    }
}

/**
 PhoneCallKeypadView presents the in-call DTMF keypad shown over PhoneCallScreen.

 Unlike PhoneDialPadScreen — which composes a phone number before dialling — every tap here
 is sent to the far end immediately as a DTMF tone, so there is no delete button and the
 readout above the grid is a record of what was sent rather than an editable field.

 It lives on the permanently dark call screen, so its buttons are pinned to fixed colors
 instead of following the app's light/dark scheme.
 */
struct PhoneCallKeypadView: View {
    
    // MARK: - Private properties
    
    private let columns = [
        GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
    ]
    
    private let digits: String
    private let onDigit: (String) -> Void
    private let onHide: () -> Void
    private let onEndCall: () -> Void
    
    // MARK: - Initializer
    
    init(
        digits: String,
        onDigit: @escaping (String) -> Void,
        onHide: @escaping () -> Void,
        onEndCall: @escaping () -> Void
    ) {
        self.digits = digits
        self.onDigit = onDigit
        self.onHide = onHide
        self.onEndCall = onEndCall
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        GeometryReader { geo in
            let hPad: CGFloat = 54
            let availableWidth = geo.size.width - hPad * 2
            let buttonDiameter = min(74, floor(availableWidth / 3))
            
            VStack(alignment: .center, spacing: 0) {
                Spacer(minLength: 0)
                
                // Tones sent so far on this visit to the keypad
                GlacierLabel(
                    text: digits.isEmpty ? " " : digits,
                    font: .neueHassGroteskFont(ofSize: 35),
                    textAlignment: .center,
                    lineLimit: 1,
                    minimumScaleFactor: 0.3,
                    customTextColor: .constant(.white)
                )
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .padding(.horizontal, 16)
                
                // Alpha-numeric digits
                LazyVGrid(columns: columns, spacing: 20) {
                    keypadButton(title: "1", subTitle: nil, diameter: buttonDiameter)
                    keypadButton(title: "2", subTitle: "ABC", diameter: buttonDiameter)
                    keypadButton(title: "3", subTitle: "DEF", diameter: buttonDiameter)
                    
                    keypadButton(title: "4", subTitle: "GHI", diameter: buttonDiameter)
                    keypadButton(title: "5", subTitle: "JKL", diameter: buttonDiameter)
                    keypadButton(title: "6", subTitle: "MNO", diameter: buttonDiameter)
                    
                    keypadButton(title: "7", subTitle: "PQRS", diameter: buttonDiameter)
                    keypadButton(title: "8", subTitle: "TUV", diameter: buttonDiameter)
                    keypadButton(title: "9", subTitle: "WXYZ", diameter: buttonDiameter)
                    
                    PhoneDialPadButton(
                        icon: "star-icon",
                        diameter: buttonDiameter,
                        fixedBackgroundColor: .grey90,
                        fixedForegroundColor: .white,
                        action: { onDigit("*") }
                    )
                    keypadButton(title: "0", subTitle: nil, diameter: buttonDiameter)
                    keypadButton(title: "#", subTitle: nil, diameter: buttonDiameter)
                }
                .padding(.horizontal, hPad)
                .padding(.top, 24)
                
                ZStack {
                    // End call button, so the call can be hung up without hiding the keypad first
                    Button(
                        action: {
                            onEndCall()
                        },
                        label: {
                            ZStack {
                                Circle()
                                    .fill(Color.ember)
                                    .frame(width: buttonDiameter, height: buttonDiameter)
                                
                                GlacierImage(
                                    name: .constant("end-call-icon"),
                                    width: 32,
                                    height: 32,
                                    shouldAdaptToColorSchemeChange: false,
                                    customTintColor: .constant(.white)
                                )
                            }
                        }
                    )
                    
                    HStack(alignment: .center) {
                        Spacer()
                        
                        Button(
                            action: {
                                onHide()
                            },
                            label: {
                                GlacierLabel(
                                    text: NSLocalizedString("Hide", comment: "In call keypad hide button title"),
                                    font: .bodyRegular,
                                    customTextColor: .constant(.white)
                                )
                                .frame(width: buttonDiameter, height: buttonDiameter)
                                .contentShape(Rectangle())
                            }
                        )
                    }
                }
                .padding(.top, 24)
                .padding(.horizontal, 62)
                
                Spacer(minLength: 0)
            }
        }
        .background(Color.grey95.ignoresSafeArea())
    }
    
    // MARK: - Private methods
    
    private func keypadButton(title: String, subTitle: String?, diameter: CGFloat) -> some View {
        PhoneDialPadButton(
            title: title,
            subTitle: subTitle,
            diameter: diameter,
            fixedBackgroundColor: .grey90,
            fixedForegroundColor: .white,
            action: { onDigit(title) }
        )
    }
}
