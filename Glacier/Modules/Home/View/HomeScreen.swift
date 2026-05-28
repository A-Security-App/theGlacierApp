//
//  HomeScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 HomeScreen presents user device and communication related security status, warnings, etc and helps user
 manage DNS/VPN connection, device security settings, etc.
 It presents UI/UX for,
 - Security issues overview like security breach related warning, number of issues prevented, etc.
 - DNS and VPN connection state
 - Device security settings status
 */
struct HomeScreen<ViewModel: HomeViewModel & ObservableObject>: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @ObservedObject private var viewModel: ViewModel
    
    @State private var blockedTrackerTextColor: Color?
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
            
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        
                        // MARK: - Security issues overview
                        
                        GlacierViewContainer(padding: 0) {
                            ZStack(alignment: .topLeading) {
                                
                                // Linear gradient animation view
                                SecurityStatusAnimatedGradientView(
                                    height: 240,
                                    isScanningForSecurityStatus: $viewModel.isScanningDevice,
                                    isSecured: $viewModel.isUserDeviceSecured
                                )
                                
                                VStack(alignment: .leading, spacing: 24) {
                                    // Security status trext
                                    GlacierLabel(
                                        text: viewModel.securityStatusText,
                                        font: .headerOne,
                                        textAlignment: .leading,
                                        customTextColor: .constant(.black)
                                    )
                                    .frame(width: 170, alignment: .leading)
                                    .padding(.top, 4)
                                    .opacity(viewModel.isScanningDevice ? 0 : 1)
                                    .layoutPriority(3)
                                    
                                    Spacer()
                                    
                                    HStack(alignment: .bottom) {
                                        
                                        // Security risk warning text
                                        if let issueText = viewModel.securityIssueText {
                                            GlacierLabel(
                                                text: issueText,
                                                font: .bodyThick,
                                                textAlignment: .leading,
                                                lineSpacing: 5,
                                                customTextColor: .constant(.black)
                                            )
                                            .frame(width: 190, alignment: .leading)
                                            .opacity(viewModel.isScanningDevice ? 0 : 1)
                                        }
                                        
                                        Spacer()
                                        
                                        // Refresh security status button
                                        Button(
                                            action: {
                                                viewModel.refreshDeviceSecurityStatus()
                                            },
                                            label: {
                                                ZStack {
                                                    RoundedRectangle(cornerRadius: 16)
                                                        .fill(.white)
                                                        .frame(width: 40, height: 32)
                                                    
                                                    GlacierImage(
                                                        name: .constant("refresh-icon"),
                                                        width: 16,
                                                        height: 16,
                                                        shouldAdaptToColorSchemeChange: false,
                                                        customTintColor: .constant(.grey60)
                                                    )
                                                }
                                            }
                                        )
                                        .opacity(viewModel.isScanningDevice ? 0.7 : 1)
                                        .disabled(viewModel.isScanningDevice)
                                    }
                                    .padding(.bottom, 30)
                                    .layoutPriority(1)
                                    
                                    HStack(alignment: .center) {
                                        GlacierLabel(
                                            text: NSLocalizedString("Today", comment: "Home screen today text"),
                                            font: .bodyLargeThick
                                        )
                                        .opacity(viewModel.isScanningDevice ? 0 : 1)
                                        
                                        Spacer()
                                        
                                        ZStack(alignment: .trailing) {
                                            // Number of blocked trackers text
                                            GlacierLabel(
                                                text: viewModel.blockedTrackersInfoText,
                                                font: .bodyLarge,
                                                customTextColor: $blockedTrackerTextColor
                                            )
                                            .frame(width: 180, alignment: .trailing)
                                            .opacity(viewModel.isUpdatingBlockedTrackersCount ? 0 : 1)
                                            
                                            // Status loading graphics
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color.grey30)
                                                .frame(width: 170, height: 20)
                                                .opacity(viewModel.isUpdatingBlockedTrackersCount ? 1 : 0)
                                        }
                                    }
                                    .layoutPriority(2)
                                }
                                .padding(.all, 24)
                                .frame(height: 310)
                            }
                        }
                        
                        // MARK: - Secured Connection Status
                        
                        GlacierViewContainer {
                            VStack(alignment: .leading) {
                                HStack(alignment: .center, spacing: 8) {
                                    GlacierLabel(text: viewModel.connectionStatusText, font: .bodyThick)
                                        .padding(.vertical, 8)
                                    if let activeLabel = viewModel.activeConnectionLabel {
                                        HStack(spacing: 6) {
                                            if viewModel.isConnectedToVPN,
                                               activeLabel != SecuredConnectionType.dns.label {
                                                GlacierLabel(text: SecuredConnectionType.dns.label, font: .bodySmallThick)
                                                    .padding(.all, 8)
                                                    .background(
                                                        GlacierBackground(cornerRadius: 8)
                                                    )
                                            }
                                            GlacierLabel(text: activeLabel, font: .bodySmallThick)
                                                .padding(.all, 8)
                                                .background(
                                                    GlacierBackground(cornerRadius: 8)
                                                )
                                        }
                                    }
                                    Spacer()
                                    
                                    if viewModel.isConnectedToVPN {
                                        GlacierImage(
                                            name: .constant("right-arrow-small-icon"),
                                            width: 7,
                                            height: 12,
                                            shouldAdaptToColorSchemeChange: true
                                        )
                                    }
                                }
                                
                                if !viewModel.isConnectedToVPN && !viewModel.isConnectedToDNS {
                                    GlacierButton(
                                        style: .primary,
                                        title: NSLocalizedString("Connect", comment: "Home screen connect button title"),
                                        action: {
                                            viewModel.connectToSecuredNetwork()
                                        }
                                    )
                                    .padding(.top, 80)
                                } else {
                                    GlacierButton(
                                        style: .tertiary,
                                        title: NSLocalizedString("Disconnect", comment: "Home screen disconnect button title"),
                                        action: {
                                            viewModel.disconnectFromSecuredNetwork()
                                        }
                                    )
                                    .padding(.top, 80)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onTapGesture {
                            guard viewModel.isConnectedToVPN else { return }
                            viewModel.presentVPNSettingsScreen()
                        }
                        
                        // MARK: - Device Security Settings Status
                        
                        GlacierViewContainer {
                            VStack(alignment: .leading) {
                                HStack(alignment: .center) {
                                    GlacierLabel(
                                        text: NSLocalizedString("Device security settings", comment: "Home screen device security settings title"),
                                        font: .bodyThick,
                                        customTextColor: $blockedTrackerTextColor
                                    )
                                    
                                    Spacer()
                                    
                                    // Security settings progress view
                                    SecuritySettingsProgressView(
                                        securitySettings: $viewModel.deviceSecuritySettingsStatus,
                                        width: 60,
                                        height: 8
                                    )
                                    .opacity(viewModel.isFirstDeviceScanCompleted ? 1 : 0)
                                }
                                
                                VStack(alignment: .leading, spacing: 32) {
                                    ForEach(viewModel.deviceSecuritySettingsStatus, id: \.id) { securitySetting in
                                        HStack(alignment: .center) {
                                            GlacierLabel(
                                                text: securitySetting.type.title,
                                                font: .bodyThick
                                            )
                                            
                                            Spacer()
                                            
                                            if securitySetting.isEnabled {
                                                Button(
                                                    action: {},
                                                    label: {
                                                        ZStack {
                                                            GlacierImage(
                                                                name: .constant("tick-icon"),
                                                                width: 16,
                                                                height: 16,
                                                                shouldAdaptToColorSchemeChange: false,
                                                                customTintColor: .constant(.grey40)
                                                            )
                                                        }
                                                    }
                                                )
                                                //.disabled(true)
                                            } else {
                                                GlacierLabel(
                                                    text: securitySetting.type.actionButtonTitle,
                                                    font: .bodyThick,
                                                    textAlignment: .trailing,
                                                    isUnderlined: true
                                                )
                                                .frame(width: 50)
                                                .onTapGesture {
                                                    viewModel.presentDeviceSettings(for: securitySetting.type)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 50)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 16)
                    
                    // This bottom padding is required to bypass floating tab bar blur area so that
                    // content are fully visible
                    .padding(.bottom, 100)
                }
                .padding(.top, 4)
            }
        }
        .onAppear {
            setupColors(for: glacierColorScheme.activeScheme)
            // refreshDeviceSecurityStatus() must be called first so that isScanningDevice
            // transitions false → true → false, triggering the gradient's onChange and
            // populating securityStatusText. Without it, refreshStatus() alone never
            // changes isScanningDevice (it stays false), so onChange never fires and the
            // gradient stays at its initial offset-0 (mixed-color) position indefinitely.
            // This manifests after onboarding, where no VPN status change fires to kick
            // off the full scan the way it does on a normal cold start.
            viewModel.refreshDeviceSecurityStatus()
            viewModel.refreshStatus()
        }
        .onChange(of: glacierColorScheme.activeScheme) { colorScheme in
            setupColors(for: colorScheme)
        }
    }
    
    // MARK: - Private methods
    
    private func setupColors(for scheme: ColorScheme) {
        blockedTrackerTextColor = scheme == .light ? .grey60 : .grey40
    }
}
