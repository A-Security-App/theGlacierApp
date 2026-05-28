//
//  ConnectionTypeSelectionScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 ConnectionTypeSelectionScreen presents UI/UX for DNS or VPN connection selection.
 It also lets users add DNS and VPN configuration, if not already added during user onboarding flows.
 */
struct ConnectionTypeSelectionScreen<ViewModel: ConnectionTypeSelectionViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @SwiftUI.Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    
    @StateObject private var viewModel: ViewModel
    
    @State private var connectionDescriptionTextColor: Color?
    
    // MARK: - Intializer
    
    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        NavigationStack {
            ZStack {
                GlacierBackground()
                    .ignoresSafeArea()
                
                VStack(alignment: .center, spacing: 16) {
                    ForEach(viewModel.connectionTypes, id: \.self) { connectionType in
                        GlacierViewContainer {
                            VStack(alignment: .leading, spacing: 40) {
                                HStack(alignment: .center, spacing: 8) {
                                    GlacierLabel(
                                        text: connectionType.title,
                                        font: .bodyThick
                                    )
                                    
                                    HStack(spacing: 6) {
                                        if connectionType == .vpn {
                                            GlacierLabel(
                                                text: SecuredConnectionType.dns.label,
                                                font: .bodySmallThick
                                            )
                                            .padding(.all, 10)
                                            .background {
                                                GlacierBackground(cornerRadius: 8)
                                            }
                                        }
                                        GlacierLabel(
                                            text: connectionType.label,
                                            font: .bodySmallThick
                                        )
                                        .padding(.all, 10)
                                        .background {
                                            GlacierBackground(cornerRadius: 8)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    GlacierImage(
                                        name: .constant(viewModel.selectedConnectionType?.label == connectionType.label ? "radioButton-selected-icon" : "radioButton-deselected-icon"),
                                        width: 16,
                                        height: 16,
                                        shouldAdaptToColorSchemeChange: true
                                    )
                                    .frame(width: 16, height: 16)
                                }
                                
                                GlacierLabel(
                                    text: connectionType.description,
                                    font: .bodyRegular,
                                    lineSpacing: 5,
                                    customTextColor: $connectionDescriptionTextColor
                                )
                                .padding(.trailing, 60)
                            }
                        }
                        .onTapGesture {
                            viewModel.selectedConnectionType = connectionType
                        }
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 28)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    GlacierLabel(
                        text: NSLocalizedString("Choose protection", comment: "Protection type selection screen header"),
                        font: .headerTwo
                    )
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        GlacierImage(
                            name: .constant("cross-icon"),
                            contentMode: .fit,
                            width: 24,
                            height: 24,
                            shouldAdaptToColorSchemeChange: true
                        )
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.75)])
        .onAppear {
            connectionDescriptionTextColor = glacierColorScheme.activeScheme == .light ? .grey60 : .grey40
        }
        .onChange(of: glacierColorScheme.activeScheme) { colorScheme in
            connectionDescriptionTextColor = colorScheme == .light ? .grey60 : .grey40
        }
    }
}
