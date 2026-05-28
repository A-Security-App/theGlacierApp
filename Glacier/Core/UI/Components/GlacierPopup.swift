//
//  GlacierPopup.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 GlacierPopup view presents the UI/UX for different types of popups (alerts, confirmation prompt, input prompt, etc.) based on the given PopupConfiguration.
 It also auto updates the color codes based on change in dark/light color mode change.
 */
struct GlacierPopup: View {
    
    // MARK: - Private properties
    
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var glacierColorScheme = GlacierColorScheme()
    @FocusState private var isTextFieldFocused: Bool
    
    @State private var hasSmallScreen = false
    @State private var backgroundColor: Color = .white
    
    @State private var text: String = ""
    @State private var textFieldBackgroundColor: Color = .grey30
    @State private var textFieldTextColor: Color = .grey60
    
    @State private var darkBackgroundOpacity: Double = 0.4
    @State private var isAppearing = false
    
    private var configuration: PopupConfiguration

    // MARK: - Initializer
    
    init(configuration: PopupConfiguration) {
        self.configuration = configuration
    }
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {

            // Background
            Color.black.opacity(darkBackgroundOpacity)
                .ignoresSafeArea()

            ZStack {
                // Content views
                VStack(alignment: .center, spacing: 0) {
                    if let titleText = configuration.title {
                        GlacierLabel(
                            text: titleText,
                            font: .system(size: 20, weight: .semibold),
                            textAlignment: .center,
                            customTextColor: .constant(.black)
                        )
                        .padding(.top, 8)
                    }

                    if let descriptionText = configuration.description {
                        GlacierLabel(
                            text: descriptionText,
                            font: .system(size: 18, weight: .regular),
                            textAlignment: .leading,
                            customTextColor: .constant(.black)
                        )
                        .padding(.top, self.configuration.title == nil ? 8 : 16)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: configuration.descriptionAlignment)
                    }
                    
                    if let inputTextConfiguration = configuration.inputTextConfiguration {
                        ZStack {
                            RoundedRectangle(cornerRadius: 24)
                                .fill(textFieldBackgroundColor)
                                .frame(maxWidth: .infinity, maxHeight: 50)
                                .onTapGesture {
                                    isTextFieldFocused = true
                                }
                            
                            TextField(inputTextConfiguration.placeholder ?? "", text: $text)
                                .multilineTextAlignment(.leading)
                                .font(.bodyThick)
                                .foregroundColor(textFieldTextColor)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .focused($isTextFieldFocused)
                                .frame(maxHeight: 50)
                                .onSubmit {
                                    isTextFieldFocused = false
                                }
                                .padding(.all, 24)
                        }
                        .frame(maxHeight: 50)
                        .padding(.top, 30)
                        .onChange(of: text) { text in
                            inputTextConfiguration.onInputTextChange(text)
                        }
                    }

                    if configuration.buttonsAlignment == .horizontal {
                        HStack(alignment: .center, spacing: 8) {
                            ForEach(configuration.buttons, id: \.id) { button in
                                GlacierButton(
                                    style: button.style,
                                    title: button.title,
                                    customTitleColor: button.titleColor,
                                    height: 48,
                                    cornerRadius: 24,
                                    action: {
                                        button.onTap()
                                    }
                                )
                            }
                        }
                        .padding(.top, configuration.inputTextConfiguration == nil ? 30 : 24)
                    } else if configuration.buttonsAlignment == .vertical {
                        VStack(alignment: .center, spacing: 0) {
                            ForEach(configuration.buttons, id: \.id) { button in
                                GlacierButton(
                                    style: button.style,
                                    title: button.title,
                                    customTitleColor: button.titleColor,
                                    height: 48,
                                    cornerRadius: 24,
                                    action: {
                                        button.onTap()
                                    }
                                )
                            }
                        }
                        .padding(.top, configuration.inputTextConfiguration == nil ? 30 : 24)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 36)
                        .fill(backgroundColor)
                        .frame(width: UIScreen.main.bounds.width - 48)
                )
            }
        }
        .environmentObject(glacierColorScheme)
        .onAppear {
            isAppearing = true
            setupColors(for: glacierColorScheme.activeScheme)
        }
        .onDisappear {
            isAppearing = false
        }
        .onChange(of: colorScheme) { newScheme in
            glacierColorScheme.setScheme(newScheme)
        }
        .onChange(of: glacierColorScheme.activeScheme) { newScheme in
            guard isAppearing else { return }
            setupColors(for: newScheme)
        }
        .onTapGesture {
            guard configuration.inputTextConfiguration != nil else { return }
            UIApplication.shared.dismissKeyboard()
        }
    }
    
    // MARK: - Private properties
    
    private func setupColors(for scheme: ColorScheme) {
        backgroundColor = scheme == .dark ? .grey40 : .grey10
        textFieldBackgroundColor = scheme == .dark ? .grey70 : .grey30
        textFieldTextColor = scheme == .dark ? .grey40 : .grey60
        darkBackgroundOpacity = scheme == .dark ? 0.4 : 0.6
    }
}
