//
//  VoicemailsScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 01/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 VoicemailsScreen displays voice mail details. Users can see name, phone number, date/time stamp, avatar image and other related
 details for the voicemails. Users can tap on the call button to initiate a new phone call with the sender of the voicemail.
 */
struct VoicemailsScreen<ViewModel: HistoryViewModel & ObservableObject>: View, PhoneNumberMenuCoordinator{
    
    // MARK: - Private properties
    
    @ObservedObject private var viewModel: ViewModel
    
    @Binding private var backgroundColor: Color?
    @Binding private var secondaryTextColor: Color?
    @Binding private var avatarForegroundColor: Color?
    @Binding private var avatarBackgroundColor: Color?
    
    // MARK: - Initializer
    
    init(
        viewModel: ViewModel,
        backgroundColor: Binding<Color?> = .constant(nil),
        secondaryTextColor: Binding<Color?> = .constant(nil),
        avatarForegroundColor: Binding<Color?> = .constant(nil),
        avatarBackgroundColor: Binding<Color?> = .constant(nil)
    ) {
        self.viewModel = viewModel
        self._backgroundColor = backgroundColor
        self._secondaryTextColor = secondaryTextColor
        self._avatarForegroundColor = avatarForegroundColor
        self._avatarBackgroundColor = avatarBackgroundColor
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
                .onTapGesture {
                    hidePhoneNumberMenu()
                }
            
            if viewModel.voiceMails.isEmpty {
                if !viewModel.isLoadingData {
                    GlacierLabel(
                        text: NSLocalizedString("No voicemails", comment: "Voicemail screen no voicemails"),
                        font: .bodyRegular
                    )
                    .onTapGesture {
                        hidePhoneNumberMenu()
                    }
                    .offset(y: -70)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(viewModel.voiceMails, id: \.id) { voiceMail in
                            VoicemailItemDetailsView(
                                voiceMail: voiceMail,
                                backgroundColor: $backgroundColor,
                                secondaryTextColor: $secondaryTextColor,
                                avatarForegroundColor: $avatarForegroundColor,
                                avatarBackgroundColor: $avatarBackgroundColor
                            ) {
                                // This is called when user taps on the call button for contact
                                guard let mailFrom = voiceMail.from else { return }
                                viewModel.startCall(with: mailFrom, personName: nil)
                            }
                            .onTapGesture {
                                hidePhoneNumberMenu()
                                viewModel.presentVoicemailDetailsView(for: voiceMail)
                            }
                        }
                    }
                    .padding(.top, 32)
                    
                    // This bottom padding is required to bypass floating tab bar blur area so that
                    // content are fully visible
                    .padding(.bottom, 100)
                }
                
                Spacer()
            }
        }
    }
}
