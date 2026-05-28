//
//  WiFiSettingsScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 21/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 WiFiSettingsScreen presents UI/UX and functionality for configuring WiFi networks. Like,
 - VPN connection activation over all wifi networks or deactivation over trusted networks.
 - Adding and removint trusted networks.
 */
struct WiFiSettingsScreen<ViewModel: WiFiSettingsViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @StateObject private var viewModel: ViewModel
    
    @State private var secondaryTextColor: Color?
    
    @State private var selectedWiFiNetwork: TrustedNetwork?
    @State private var menuFrame: CGRect = .zero
    @State private var showMenu = false
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }
    
    // UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
            
            VStack(alignment: .leading, spacing: 0) {
                GlacierLineSeparator(lineThickness: 1)
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .center, spacing: 16) {
                        
                        //VPN activation target
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(VPNActivationOverWiFiPolicy.allCases, id: \.hashValue) { policy in
                                GlacierViewContainer(padding: 24) {
                                    VStack(alignment: .leading) {
                                        HStack(alignment: .center, spacing: 0) {
                                            GlacierLabel(
                                                text: policy.title,
                                                font: .bodyThick
                                            )
                                            
                                            Spacer()
                                            
                                            GlacierImage(
                                                name: .constant(viewModel.selectedVPNActivationPolicy == policy ? "radioButton-selected-icon" : "radioButton-deselected-icon"),
                                                width: 16,
                                                height: 16,
                                                shouldAdaptToColorSchemeChange: true
                                            )
                                        }
                                        
                                        GlacierLabel(
                                            text: policy.description,
                                            font: .bodyRegular,
                                            customTextColor: $secondaryTextColor
                                        )
                                        .padding(.top, 40)
                                        .padding(.trailing, 40)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .onTapGesture {
                                    viewModel.getConfirmationForVPNActivationPolicyChange(to: policy)
                                }
                            }
                        }
                        
                        // Trusted networks
                        GlacierLabel(
                            text: NSLocalizedString("Trusted Networks", comment: "WiFi settings screen trusted networks title"),
                            font: .bodyRegular,
                            customTextColor: $secondaryTextColor
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 30)
                        .padding(.leading, 8)
                        
                        VStack(alignment: .center, spacing: 16) {
                            ForEach(viewModel.trustedNetworks, id: \.id) { network in
                                GlacierViewContainer(padding: 24) {
                                    HStack(alignment: .center, spacing: 0) {
                                        GlacierLabel(
                                            text: network.name,
                                            font: .bodyThick
                                        )
                                        
                                        Spacer()
                                        
                                        GeometryReader { proxy in
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(Color.clear)
                                                    .frame(width: 40, height: 40)
                                                
                                                GlacierImage(
                                                    name: .constant("three-dot-icon"),
                                                    width: 24,
                                                    height: 8,
                                                    shouldAdaptToColorSchemeChange: false,
                                                    customTintColor: .constant(.grey60)
                                                )
                                                .frame(width: 24, height: 24)
                                            }
                                            .onTapGesture {
                                                selectedWiFiNetwork = network
                                                menuFrame = proxy.frame(in: .named("container"))
                                                showMenu = true
                                            }
                                        }
                                        .frame(width: 40, height: 40)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        
                        // Add trusted network button
                        GlacierViewContainer(padding: 24) {
                            HStack(alignment: .center, spacing: 16) {
                                GlacierImage(
                                    name: .constant("plus-icon"),
                                    width: 16,
                                    height: 16,
                                    shouldAdaptToColorSchemeChange: true
                                )
                                
                                GlacierLabel(
                                    text: NSLocalizedString("Add trusted network", comment: "WiFi settings screen add trusted networks button title"),
                                    font: .bodyThick
                                )
                                
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .onTapGesture {
                            viewModel.presentAddTrustedNetworkPopup()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .padding(.top, 4)
            }
            .padding(.top, 8)
            
            // Phone number context menu
            if showMenu {
                Color.black.opacity(0.01)
                    .onTapGesture {
                        showMenu = false
                        selectedWiFiNetwork = nil
                    }
                
                GlacierMenuView(menuItems: [
                    GlacierMenuItem(
                        icon: nil,
                        title: NSLocalizedString("Remove", comment: "Wifi settings screen remove button title"),
                        action: {
                            showMenu = false
                            guard let netword = selectedWiFiNetwork else { return }
                            viewModel.removeTrustedNetwork(netword.name)
                            selectedWiFiNetwork = nil
                        }
                    )
                ]
                )
                .position(x: menuFrame.minX, y: menuFrame.minY - 95)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                GlacierLabel(
                    text: NSLocalizedString("Wi-Fi Networks", comment: "WiFi settings screen title"),
                    font: .headerTwo
                )
            }
        }
        .onFirstAppear {
            setupColors(for: glacierColorScheme.activeScheme)
            viewModel.initialize()
        }
        .onChange(of: glacierColorScheme.activeScheme) { colorScheme in
            setupColors(for: colorScheme)
        }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        secondaryTextColor = scheme == .light ? .grey60 : .grey40
    }
}
