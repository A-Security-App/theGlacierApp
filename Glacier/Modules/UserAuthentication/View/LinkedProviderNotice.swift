//
//  LinkedProviderNotice.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 "This email is linked to Google." with that provider's button. The login and
 sign-up screens show it right under the email field during the password step:
 the regular Google and Apple buttons are hidden then, and the keyboard opens
 for the password, so anything lower on the screen ends up behind it.
 */
struct LinkedProviderNotice: View {

    let provider: FederatedSignInProvider
    let message: String
    let action: () -> Void

    init(provider: FederatedSignInProvider, message: String? = nil, action: @escaping () -> Void) {
        self.provider = provider
        self.message = message ?? String(
            format: NSLocalizedString(
                "This email is linked to %@.",
                comment: "User login screen notice that the email belongs to a Google or Apple account. %@ is the provider name."
            ),
            provider.displayName
        )
        self.action = action
    }

    var body: some View {
        VStack(spacing: 16) {
            GlacierLabel(
                text: message,
                font: .bodyRegular,
                textAlignment: .center,
                allowsVerticalGrowth: true,
                customTextColor: .constant(.grey60)
            )

            GlacierButton(
                style: .tertiary,
                title: provider.continueButtonTitle,
                icon: provider.buttonIcon,
                action: action
            )
        }
    }
}
