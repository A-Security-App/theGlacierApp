//
//  UserRegistrationConfirmationScreen.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 11/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 `UserRegistrationConfirmationScreen` is presented after successfull user account creation to tell users to confirm their registered email address
 by clicking on the confirmation button in the email sent to them.
 */
struct UserRegistrationConfirmationScreen<ViewModel: UserRegistrationViewModel & ObservableObject>: View {

    // MARK: - Private properties

    @StateObject private var viewModel: ViewModel
    @State private var confirmationCode: String = ""
    @FocusState private var isOTPFieldFocused: Bool

    // MARK: - Initializer

    init(viewModel: ViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }

    // MARK: - UI/UX

    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()

            VStack(alignment: .center, spacing: 8) {
                GlacierLabel(
                    text: NSLocalizedString("Check your email", comment: "User registration confirmation screen header"),
                    font: .headerTwo,
                    textAlignment: .center
                )

                GlacierLabel(
                    text: NSLocalizedString("We sent you an email to verify you're you.", comment: "User registration confirmation screen sub header"),
                    font: .headerTwo,
                    textAlignment: .center,
                    customTextColor: .constant(.grey60)
                )

                otpEntrySection

                GlacierButton(
                    style: .tertiary,
                    title: NSLocalizedString("Resend", comment: "Resend button title"),
                    height: 42,
                    width: 95,
                    cornerRadius: 21,
                    action: {
                        viewModel.resendAccountConfirmationEmail()
                    }
                )
                .padding(.top, 16)
            }
            .padding(.horizontal, 24)
        }
        .onTapGesture {
            isOTPFieldFocused = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .userAccountConfirmationLinkClicked)) { notification in
            guard let userInfo = notification.userInfo,
                  let userName = userInfo[GlacierNotificationProperties.userName] as? String,
                  let code = userInfo[GlacierNotificationProperties.confirmationCode] as? String else {
                return
            }
            confirmationCode = code
            viewModel.confirmAccount(userName: userName, confirmationCode: code)
        }
    }

    // MARK: - OTP Entry

    private var otpEntrySection: some View {
        VStack(spacing: 16) {
            GlacierLabel(
                text: NSLocalizedString("Enter the 6-digit code from your email", comment: "User registration confirmation screen OTP entry label"),
                font: .headerTwo,
                textAlignment: .center,
                customTextColor: .constant(.grey60)
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
                            viewModel.confirmAccountManually(confirmationCode: filtered)
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
                text: NSLocalizedString("Tip: Make sure to check your inbox and spam folders.", comment: "User registration confirmation screen OTP tip"),
                font: .headerTwo,
                textAlignment: .center,
                customTextColor: .constant(.grey60)
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
