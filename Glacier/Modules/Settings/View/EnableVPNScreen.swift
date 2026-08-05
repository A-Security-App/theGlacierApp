//
//  EnableVPNScreen.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 EnableVPNScreen is the confirmation shown when the user enables VPN from the VPN settings slider
 or the Choose protection screen, once the first-time VPN mini-setup has already been completed.
 It mirrors EnableCellularScreen and either enables VPN or cancels, leaving the setting unchanged.
 */
struct EnableVPNScreen<ViewModel: EnableVPNViewModel>: View {

    // MARK: - Private properties

    @State private var visibleIndices: Set<Int> = []
    private var viewModel: ViewModel

    // MARK: - Initializer

    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - UI/UX

    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                GlacierViewContainer(shouldReverseColor: true, darkColor: .grey95, lightColor: .white) {
                    VStack(alignment: .leading, spacing: 16) {
                        GlacierLabel(
                            text: NSLocalizedString("Are you sure you want to enable VPN?", comment: "Enable VPN screen sub header"),
                            font: .headerOne,
                            shouldReverseColor: true
                        )
                        .opacity(visibleIndices.contains(0) ? 1 : 0)
                        .padding(.top, 8)

                        Spacer()

                        HStack(alignment: .bottom) {
                            GlacierLabel(
                                text: NSLocalizedString(
                                    "Heads up - can slow or limit your connection to some websites and apps.\n\nRecommended on untrusted networks like public Wi-Fi.\n\nEnable anyway.",
                                    comment: "Enable VPN screen overview"
                                ),
                                font: .headerOne,
                                customTextColor: .constant(.grey50)
                            )

                            Spacer(minLength: 32)

                            GlacierImageButton(name: "right-arrow-icon", imageWidth: 16, imageHeight: 16, backgroundOpacity: 0, shouldReverseColor: true) {
                                viewModel.enableVPN()
                            }
                        }
                        .opacity(visibleIndices.contains(1) ? 1 : 0)
                    }
                }
                .padding(.top, 40)

                GlacierButton(style: .tertiary, title: NSLocalizedString("Cancel", comment: "Cancel button title")) {
                    viewModel.cancel()
                }
                .opacity(visibleIndices.contains(2) ? 1 : 0)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            animateContentAppearance()
        }
    }

    // MARK: - Private methods

    private func animateContentAppearance() {
        Task {
            let duration: UInt64 = 500_000_000
            for index in 0...2 {
                let _ = withAnimation(.easeOut(duration: 0.4)) {
                    visibleIndices.insert(index)
                }
                try? await Task.sleep(nanoseconds: duration)
            }
        }
    }
}
