//
//  SettingsScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI
import Amplify

/**
 Settings screen presents UI/UX for app level setting options and controls.
 */
struct SettingsScreen<ViewModel: SettingsViewModel & ObservableObject>: View {
    
    // MARK: - Environment properties
    
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    
    // MARK: - Private properties
    
    @StateObject private var viewModel: ViewModel
    
    // MARK: - Initializer
    
    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
            
            VStack(alignment: .leading) {
                GlacierLineSeparator(lineThickness: 1)

                ScrollView {
                    VStack(spacing: 16) {
                    GlacierViewContainer {
                        HStack(alignment: .center) {
                            GlacierLabel(
                                text: NSLocalizedString("Account", comment: "Settings screen account"),
                                font: .bodyThick
                            )
                            
                            Spacer()
                            
                            GlacierLabel(
                                text: viewModel.userEmail,
                                font: .bodyThick,
                                customTextColor: .constant(.grey50)
                            )
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(.top, 24)
                    
                    if viewModel.shouldShowVPNSettingsOption {
                        GlacierViewContainer {
                            HStack(alignment: .center) {
                                GlacierLabel(
                                    text: NSLocalizedString("VPN Settings", comment: "Settings screen reset password"),
                                    font: .bodyThick,
                                    textAlignment: .leading
                                )
                                
                                Spacer()
                                
                                GlacierImage(
                                    name: .constant("right-arrow-small-icon"),
                                    width: 16,
                                    height: 16,
                                    shouldAdaptToColorSchemeChange: true
                                )
                            }
                            .padding(.vertical, 6)
                        }
                        .onTapGesture {
                            viewModel.presentVPNSettingsScreen()
                        }
                    }
                    
                    GlacierViewContainer {
                        HStack(alignment: .center) {
                            GlacierLabel(
                                text: NSLocalizedString("Appearance", comment: "Settings screen appearance"),
                                font: .bodyThick,
                                textAlignment: .leading
                            )

                            Spacer()

                            GlacierImage(
                                name: .constant("right-arrow-small-icon"),
                                width: 16,
                                height: 16,
                                shouldAdaptToColorSchemeChange: true
                            )
                        }
                        .padding(.vertical, 6)
                    }
                    .onTapGesture {
                        viewModel.presentAppearanceSettingsScreen()
                    }

                    GlacierViewContainer {
                        HStack(alignment: .center) {
                            GlacierLabel(
                                text: NSLocalizedString("Widget", comment: "Settings screen widget"),
                                font: .bodyThick,
                                textAlignment: .leading
                            )

                            Spacer()

                            GlacierImage(
                                name: .constant("right-arrow-small-icon"),
                                width: 16,
                                height: 16,
                                shouldAdaptToColorSchemeChange: true
                            )
                        }
                        .padding(.vertical, 6)
                    }
                    .onTapGesture {
                        viewModel.presentWidgetSettingsScreen()
                    }

                    GlacierViewContainer {
                        HStack(alignment: .center) {
                            GlacierLabel(
                                text: NSLocalizedString("Reboot Reminder", comment: "Settings screen reboot reminder title"),
                                font: .bodyThick,
                                textAlignment: .leading
                            )

                            Spacer()

                            Toggle(isOn: $viewModel.isRebootReminderEnabled, label: { Text("") })
                                .toggleStyle(SwitchToggleStyle(tint: .green50))
                        }
                        .padding(.vertical, 6)
                    }

                    GlacierViewContainer {
                        HStack(alignment: .center) {
                            GlacierLabel(
                                text: NSLocalizedString("Support & FAQ", comment: "Settings screen FAQ"),
                                font: .bodyThick,
                                textAlignment: .leading
                            )

                            Spacer()

                            GlacierImage(
                                name: .constant("right-arrow-small-icon"),
                                width: 16,
                                height: 16,
                                shouldAdaptToColorSchemeChange: true
                            )
                        }
                        .padding(.vertical, 6)
                    }
                    .onTapGesture {
                        if let url = URL(string: "https://support.theglacierapp.com") {
                            UIApplication.shared.open(url)
                        }
                    }

                    if viewModel.shouldShowResetPasswordOption {
                        GlacierViewContainer {
                            HStack(alignment: .center) {
                                GlacierLabel(
                                    text: NSLocalizedString("Reset Password", comment: "Settings screen reset password"),
                                    font: .bodyThick,
                                    textAlignment: .leading
                                )

                                Spacer()

                                GlacierImage(
                                    name: .constant("right-arrow-small-icon"),
                                    width: 16,
                                    height: 16,
                                    shouldAdaptToColorSchemeChange: true
                                )
                            }
                            .padding(.vertical, 6)
                        }
                        .onTapGesture {
                            viewModel.presentResetPasswordScreen()
                        }
                    }
                    
                    GlacierViewContainer {
                        HStack(alignment: .center) {
                            GlacierLabelButton(
                                text: NSLocalizedString("Sign Out", comment: "Settings screen sign out button title"),
                                font: .bodyThick,
                                alignment: .leading,
                                height: 30,
                                customTextColor: .constant(.ember),
                                action: {
                                    viewModel.signOut()
                                }
                            )

                            Spacer()
                        }
                    }

                    GlacierViewContainer {
                        HStack(alignment: .center) {
                            GlacierLabelButton(
                                text: NSLocalizedString("Delete Account", comment: "Settings screen delete account button title"),
                                font: .bodyThick,
                                alignment: .leading,
                                height: 30,
                                customTextColor: .constant(.ember),
                                action: {
                                    viewModel.deleteAccount()
                                }
                            )

                            Spacer()
                        }
                    }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.horizontal, 0)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                GlacierLabel(
                    text: NSLocalizedString("Settings", comment: "Settings screen title"),
                    font: .headerTwo
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .userSuccessfullyResetPassword)) { notification in
            // Let's dismiss reset password sheet view
            viewModel.dismissResetPasswordScreen()
            
            // Let's force user signout so that user could authenticate with the new password
            viewModel.signOut()
        }
    }
}
