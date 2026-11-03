//
//  SubscriptionOwnershipConflictScreen.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 SubscriptionOwnershipConflictScreen covers the app when this device's Apple subscription belongs to a
 different Glacier account than the one signed in (see `AppleSubscriptionOwnershipMonitor`).

 It can't be dismissed: nothing behind it works for this account. It offers what fixes it — signing
 out to sign in with the account that owns the subscription — plus support, a retry, and the account
 actions Settings would otherwise give (App Review 5.1.1(v)). It never names the other account.
 */
struct SubscriptionOwnershipConflictScreen: View {

    // MARK: - Private properties

    private let accountActions: any SettingsViewModel
    private let supportURL = URL(string: "https://support.theglacierapp.com")

    // MARK: - Initializer

    init(accountActions: any SettingsViewModel) {
        self.accountActions = accountActions
    }

    // MARK: - UI/UX

    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GlacierLabel(
                        text: NSLocalizedString(
                            "Subscription belongs to another account",
                            comment: "Subscription ownership conflict screen title"
                        ),
                        font: .headerOne
                    )
                    .padding(.top, 40)

                    GlacierLabel(
                        text: NSLocalizedString(
                            "Your App Store subscription belongs to a different Glacier account. To use it, sign out and sign in the way you first signed up, such as Continue with Apple.",
                            comment: "Subscription ownership conflict screen explanation"
                        ),
                        font: .body,
                        customTextColor: .constant(.grey50)
                    )

                    if let email = accountActions.userEmail, !email.isEmpty {
                        GlacierLabel(
                            text: String(
                                format: NSLocalizedString(
                                    "Signed in as %@",
                                    comment: "Subscription ownership conflict screen: the signed-in email; %@ is the email address"
                                ),
                                email
                            ),
                            font: .bodySmall,
                            customTextColor: .constant(.grey50)
                        )
                    }

                    VStack(spacing: 12) {
                        GlacierButton(
                            style: .primary,
                            title: NSLocalizedString(
                                "Switch Account",
                                comment: "Subscription ownership conflict screen sign out button title"
                            )
                        ) {
                            accountActions.signOut()
                        }

                        GlacierButton(
                            style: .tertiary,
                            title: NSLocalizedString(
                                "Contact Support",
                                comment: "Subscription ownership conflict screen contact support button title"
                            )
                        ) {
                            if let supportURL {
                                UIApplication.shared.open(supportURL)
                            }
                        }

                        GlacierButton(
                            style: .tertiary,
                            title: NSLocalizedString("Try Again", comment: "Try again button title")
                        ) {
                            // Re-sends the receipt link; a success clears the conflict and this screen.
                            Task {
                                await SKGlacierPlanPurchaseService().refreshEntitlements()
                            }
                        }
                    }
                    .padding(.top, 8)

                    HStack(alignment: .center, spacing: 16) {
                        GlacierLabelButton(
                            text: NSLocalizedString("Delete Account", comment: "Lapse paywall delete account button title"),
                            font: .bodySmall,
                            alignment: .leading,
                            width: 100,
                            customTextColor: .constant(.ember),
                            action: {
                                accountActions.deleteAccount()
                            }
                        )
                        Spacer()
                    }
                    .padding(.bottom, 16)
                }
                .padding(.horizontal, 16)
            }
        }
        .interactiveDismissDisabled(true)
    }
}
