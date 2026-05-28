//
//  VPNSettingsScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 21/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 VPNSettingsScreen presents UI/UX and funcionality for setting various VPN related configurations. Like,
 - Displaying VPN connection and active status
 - Setting how VPN connection activates/deactivates for Cellular and Wifi networks.
 - Switching to other available VPN locations.
 */
struct VPNSettingsScreen<ViewModel: VPNSettingsViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @StateObject private var viewModel: ViewModel
    
    @State private var secondaryTextColor: Color?
    @State private var seperatorLineColor: Color = .grey20
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        UISwitch.appearance().onTintColor = UIColor(Color.green50)
    }
    
    // UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
            
            VStack(alignment: .leading, spacing: 0) {
                GlacierLineSeparator(lineThickness: 1)
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        
                        // VPN connection and active status
                        GlacierViewContainer(padding: 0) {
                            VStack(alignment: .leading) {
                                VStack(alignment: .leading) {
                                    HStack(alignment: .center) {
                                        GlacierLabel(
                                            text: NSLocalizedString("VPN Connection", comment: "VPN settings screen VPN connection title"),
                                            font: .bodyThick
                                        )
                                        
                                        Spacer()
                                        
                                        Toggle(isOn: $viewModel.isConnectedToVPN, label: { Text("") })
                                            .toggleStyle(SwitchToggleStyle(tint: .green50))
                                    }
                                    
                                    GlacierLabel(
                                        text: NSLocalizedString(
                                            "An extra layer of encryption. Ideal for public Wi-Fi, travel, or untrusted networks. Learn more.",
                                            comment: "VPN settings screen VPN connection description"),
                                        font: .bodyRegular,
                                        customTextColor: $secondaryTextColor
                                    )
                                    .padding(.top, 40)
                                    .padding(.trailing, 40)
                                }
                                .padding(.all, 24)
                                
                                if viewModel.isConnectedToVPN && viewModel.isVPNActive {
                                    Rectangle()
                                        .fill(seperatorLineColor)
                                        .frame(height: 1)
                                    
                                    VStack(alignment: .leading) {
                                        HStack(alignment: .center) {
                                            GlacierLabel(
                                                text: NSLocalizedString("Status", comment: "VPN settings screen VPN status"),
                                                font: .bodyThick
                                            )
                                            
                                            Spacer()
                                            
                                            GlacierLabel(
                                                text: viewModel.vpnConnectionStatus,
                                                font: .bodySmallThick,
                                                customTextColor: $secondaryTextColor
                                            )
                                            .padding(.all, 8)
                                            .background(
                                                GlacierBackground(cornerRadius: 8)
                                            )
                                        }
                                        
                                        GlacierLabel(
                                            text: viewModel.vpnConnectionStatusDetails,
                                            font: .bodyRegular,
                                            customTextColor: $secondaryTextColor
                                        )
                                        .padding(.top, 40)
                                        .padding(.trailing, 40)
                                    }
                                    .padding(.all, 24)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        
                        if viewModel.isConnectedToVPN {
                            // VPN location selector
                            GlacierLabel(
                                text: NSLocalizedString("Locations", comment: "VPN settings screen locations title"),
                                font: .bodyRegular,
                                customTextColor: $secondaryTextColor
                            )
                            .padding(.top, 30)
                            .padding(.leading, 8)
                            
                            VStack(alignment: .center, spacing: 16) {
                                ForEach(viewModel.vpnLocations, id: \.regionCode) { location in
                                    GlacierViewContainer(padding: 24) {
                                        HStack(alignment: .center, spacing: 0) {
                                            GlacierLabel(
                                                text: location.displayName,
                                                font: .bodyThick
                                            )

                                            Spacer()

                                            GlacierImage(
                                                name: .constant(viewModel.selectedLocation?.regionCode == location.regionCode ? "radioButton-selected-icon" : "radioButton-deselected-icon"),
                                                width: 16,
                                                height: 16,
                                                shouldAdaptToColorSchemeChange: true
                                            )
                                        }
                                        .padding(.vertical, 4)
                                    }
                                    .onTapGesture {
                                        viewModel.selectedLocation = location
                                    }
                                }
                            }
                            
                            // VPN activation
                            GlacierLabel(
                                text: NSLocalizedString("VPN Activation", comment: "VPN settings screen VPN activation title"),
                                font: .bodyRegular,
                                customTextColor: $secondaryTextColor
                            )
                            .padding(.top, 30)
                            .padding(.leading, 8)
                            
                            // VPN activation over cellular network
                            GlacierViewContainer(padding: 24) {
                                VStack(alignment: .leading) {
                                    HStack(alignment: .center) {
                                        GlacierLabel(
                                            text: NSLocalizedString("Cellular", comment: "VPN settings screen activation over cellular title"),
                                            font: .bodyThick
                                        )
                                        
                                        Spacer()
                                        
                                        Toggle(isOn: $viewModel.shouldActivateOnCellular, label: { Text("") })
                                            .toggleStyle(SwitchToggleStyle(tint: .green50))
                                    }
                                    
                                    GlacierLabel(
                                        text: NSLocalizedString(
                                            "Automatically turn on when using cellular data.",
                                            comment: "VPN settings screen activation over cellular description"),
                                        font: .bodyRegular,
                                        customTextColor: $secondaryTextColor
                                    )
                                    .padding(.top, 40)
                                    .padding(.trailing, 40)
                                }
                                .padding(.vertical, 4)
                            }
                            
                            // VPN activation over wifi network
                            GlacierViewContainer(padding: 24) {
                                VStack(alignment: .leading) {
                                    HStack(alignment: .center) {
                                        GlacierLabel(
                                            text: NSLocalizedString("Wi-Fi", comment: "VPN settings screen activation over WiFi title"),
                                            font: .bodyThick
                                        )
                                        
                                        Spacer()
                                        
                                        Toggle(isOn: $viewModel.shouldActivateOnWiFi, label: { Text("") })
                                            .toggleStyle(SwitchToggleStyle(tint: .green50))
                                    }
                                    
                                    GlacierLabel(
                                        text: NSLocalizedString(
                                            "Automatically turn on for Wi-Fi connections.",
                                            comment: "VPN settings screen activation over WiFi description"),
                                        font: .bodyRegular,
                                        customTextColor: $secondaryTextColor
                                    )
                                    .padding(.top, 40)
                                    .padding(.trailing, 40)
                                }
                                .padding(.vertical, 4)
                            }
                            
                            // Wifi network details — only relevant when WiFi auto-activation is on
                            if viewModel.shouldActivateOnWiFi {
                                GlacierViewContainer(padding: 24) {
                                    VStack(alignment: .leading) {
                                        HStack(alignment: .center) {
                                            GlacierLabel(
                                                text: NSLocalizedString("Wi-Fi Networks", comment: "VPN settings screen wifi networks details title"),
                                                font: .bodyThick
                                            )

                                            Spacer()

                                            GlacierImage(
                                                name: .constant("right-arrow-small-icon"),
                                                width: 7,
                                                height: 12,
                                                shouldAdaptToColorSchemeChange: true
                                            )
                                        }

                                        GlacierLabel(
                                            text: viewModel.vpnActivationStatusOverWifiNetwork,
                                            font: .bodyRegular,
                                            customTextColor: $secondaryTextColor
                                        )
                                        .padding(.top, 40)
                                        .padding(.trailing, 40)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .onTapGesture {
                                    viewModel.presentWiFiSettingsScreen()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .padding(.top, 4)
            }
            .padding(.top, 8)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                GlacierLabel(
                    text: NSLocalizedString("VPN", comment: "VPN settings screen title"),
                    font: .headerTwo
                )
            }
        }
        .onFirstAppear {
            setupColors(for: glacierColorScheme.activeScheme)
            viewModel.initialize()
        }
        .onAppear {
            viewModel.refreshNetworkActivationState()
        }
        .onChange(of: glacierColorScheme.activeScheme) { colorScheme in
            setupColors(for: colorScheme)
        }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        secondaryTextColor = scheme == .light ? .grey60 : .grey40
        seperatorLineColor = scheme == .light ? .grey20 : .grey95
    }
}
