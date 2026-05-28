//
//  CallHistoryScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 01/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 CallHistoryScreen displays call log details for incoming and outgoing calls.
 Users can see name, phone number, date/time stamp, avatar image, incoming/outgoing indicator and other details for the
 call logs. Users can tap on the call button to initiate a new phone call with the caller/reciever.
 */
struct CallHistoryScreen<ViewModel: HistoryViewModel & ObservableObject>: View, PhoneNumberMenuCoordinator {
    
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
            
            if viewModel.callHistory.isEmpty {
                if !viewModel.isLoadingData {
                    GlacierLabel(
                        text: NSLocalizedString("No call history", comment: "Call history screen no history"),
                        font: .bodyRegular
                    )
                    .offset(y: -70)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(viewModel.callHistory, id: \.uniqueId) { record in
                            CallHistoryItemDetailsView(
                                callRecord: record,
                                backgroundColor: $backgroundColor,
                                secondaryTextColor: $secondaryTextColor,
                                avatarForegroundColor: $avatarForegroundColor,
                                avatarBackgroundColor: $avatarBackgroundColor
                            ) {
                                // This is called when user taps on the call button for contact
                                viewModel.startCall(with: record.phoneNumber, personName: record.name)
                            }
                            .onTapGesture {
                                hidePhoneNumberMenu()
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
