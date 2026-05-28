//
//  PasswordResetScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 11/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 PasswordResetScreen presents the UI/UX for sending password reset email.
 */
struct PasswordResetScreen<ViewModel: PasswordResetViewModel & ObservableObject, Coordinator: PasswordResetCoordinator>: View {

    // MARK: - Private properties

    @SwiftUI.Environment(\.presentationMode) private var presentationMode

    @StateObject private var viewModel: ViewModel
    @StateObject private var passwordResetCoordinator: Coordinator
    @EnvironmentObject private var glacierColorScheme: GlacierColorScheme
    @State private var descriptionTextColor: Color?
    @State private var confirmationCode: String = ""
    @FocusState private var isOTPFieldFocused: Bool

    // MARK: - Initializer

    init(viewModel: ViewModel, coordinator: Coordinator) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self._passwordResetCoordinator = StateObject(wrappedValue: coordinator)
    }

    // MARK: - UI/UX

    var body: some View {
        ZStack {
            if viewModel.isPresentedFromLoginScreen {
                // When presented from user login screen sheet view, we use existing navigation stack of the
                // login screen because we need to go back to login screen after password is reset.
                content
            } else {
                // When presented indpendently as sheet view, we need to show own navigation stack
                // for back/forth navigation b/w password reset screen and new password input screen.
                contentWithStackView
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetPasswordLinkClicked)) { notification in
            guard let userInfo = notification.userInfo,
                  let code = userInfo[GlacierNotificationProperties.confirmationCode] as? String else {
                return
            }
            confirmationCode = code
            viewModel.presentPsswordInputScreen(with: code)
        }
    }

    @ViewBuilder
    private var contentWithStackView: some View {
        NavigationStack(path: $passwordResetCoordinator.path) {
            content
                .navigationDestination(for: PasswordResetScreens.self) { screen in
                    passwordResetCoordinator.build(screen)
                }
                .toolbar {
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
        .presentationDetents([.fraction(0.75), .large])
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()
                .onTapGesture {
                    UIApplication.shared.dismissKeyboard()
                    isOTPFieldFocused = false
                }

            if viewModel.isLinkSent {
                checkEmailContent
            } else {
                sendLinkContent
            }
        }
        .onAppear {
            descriptionTextColor = glacierColorScheme.activeScheme == .light ? .grey60 : .grey40
        }
        .onChange(of: glacierColorScheme.activeScheme) { colorScheme in
            descriptionTextColor = colorScheme == .light ? .grey60 : .grey40
        }
    }

    @ViewBuilder
    private var sendLinkContent: some View {
        VStack(alignment: .center, spacing: 16) {
            VStack(alignment: .center, spacing: 8) {
                GlacierLabel(
                    text: NSLocalizedString("Reset your password", comment: "Password reset screen header"),
                    font: .headerTwo,
                    textAlignment: .center
                )

                GlacierLabel(
                    text: NSLocalizedString("We'll send you a link to reset your password if this email is associated with an account.", comment: "Password reset screen sub header"),
                    font: .headerTwo,
                    textAlignment: .center,
                    customTextColor: $descriptionTextColor
                )
            }
            .padding(.top, 24)

            GlacierTextField(
                placeholder: NSLocalizedString("Email", comment: "User login screen email place holder"),
                text: $viewModel.email
            )
            .padding(.top, 24)

            GlacierButton(
                style: .secondary,
                title: NSLocalizedString("Send Link", comment: "Password reset screen send link button title"),
                isEnabled: $viewModel.isContinueButtonEnabled,
                action: {
                    UIApplication.shared.dismissKeyboard()
                    viewModel.sendPasswordResetLink()
                }
            )

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private var checkEmailContent: some View {
        VStack(alignment: .center, spacing: 8) {
            GlacierLabel(
                text: NSLocalizedString("Check your email", comment: "Password reset check email header"),
                font: .headerTwo,
                textAlignment: .center
            )

            GlacierLabel(
                text: NSLocalizedString("We sent you an email to reset your password.", comment: "Password reset check email sub header"),
                font: .headerTwo,
                textAlignment: .center,
                customTextColor: $descriptionTextColor
            )

            otpEntrySection

            GlacierButton(
                style: .tertiary,
                title: NSLocalizedString("Resend", comment: "Resend button title"),
                height: 42,
                width: 95,
                cornerRadius: 21,
                action: {
                    viewModel.sendPasswordResetLink()
                }
            )
            .padding(.top, 16)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - OTP Entry

    private var otpEntrySection: some View {
        VStack(spacing: 16) {
            GlacierLabel(
                text: NSLocalizedString("Enter the 6-digit code from your email", comment: "Password reset screen OTP entry label"),
                font: .headerTwo,
                textAlignment: .center,
                customTextColor: $descriptionTextColor
            )

            ZStack {
                TextField("", text: $confirmationCode)
                    .keyboardType(.numberPad)
                    .focused($isOTPFieldFocused)
                    .opacity(0)
                    .frame(width: 1, height: 1)
                    .onChange(of: confirmationCode) { newValue in
                        let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                        if filtered != confirmationCode {
                            confirmationCode = filtered
                        }
                        if filtered.count == 6 {
                            isOTPFieldFocused = false
                            viewModel.presentPsswordInputScreen(with: filtered)
                        }
                    }

                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { index in
                        otpDigitBox(at: index)
                    }
                }
                .onTapGesture {
                    isOTPFieldFocused = true
                }
            }

            GlacierLabel(
                text: NSLocalizedString("Tip: Make sure to check your inbox and spam folders.", comment: "Password reset screen OTP tip"),
                font: .headerTwo,
                textAlignment: .center,
                customTextColor: $descriptionTextColor
            )
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    private func otpDigitBox(at index: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.grey90)
                .frame(width: 40, height: 54)

            if index < confirmationCode.count {
                let charIndex = confirmationCode.index(confirmationCode.startIndex, offsetBy: index)
                Text(String(confirmationCode[charIndex]))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white)
            }
        }
    }
}
