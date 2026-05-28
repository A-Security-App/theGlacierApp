//
//  CellularSetupScreen.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 CellularSetupScreen is the first step of the post-onboarding VPN mini-setup flow.
 It recommends leaving VPN off on cellular and asks the user whether to enable cellular VPN.
 */
struct CellularSetupScreen<ViewModel: CellularSetupViewModel>: View {

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
                            text: NSLocalizedString("VPN on.", comment: "Cellular setup screen header"),
                            font: .headerOne,
                            customTextColor: .constant(.grey50)
                        )
                        .opacity(visibleIndices.contains(0) ? 1 : 0)
                        .padding(.top, 8)

                        GlacierLabel(
                            text: NSLocalizedString("Do you want to enable VPN while on cellular?", comment: "Cellular setup screen sub header"),
                            font: .headerOne,
                            shouldReverseColor: true
                        )
                        .opacity(visibleIndices.contains(1) ? 1 : 0)

                        Spacer()

                        HStack(alignment: .bottom) {
                            GlacierLabel(
                                text: NSLocalizedString(
                                    "Heads up - can slow or limit your connection to some websites and apps.\n\nGlacier recommends leaving VPN off while on cellular for most situations. You can still enable later in settings.\n\nEnable anyway.",
                                    comment: "Cellular setup screen overview"
                                ),
                                font: .headerOne,
                                customTextColor: .constant(.grey50)
                            )

                            Spacer(minLength: 32)

                            GlacierImageButton(name: "right-arrow-icon", imageWidth: 16, imageHeight: 16, backgroundOpacity: 0, shouldReverseColor: true) {
                                viewModel.enableCellularAndContinue()
                            }
                        }
                        .opacity(visibleIndices.contains(2) ? 1 : 0)
                    }
                }
                .padding(.top, 40)

                GlacierButton(style: .tertiary, title: NSLocalizedString("Skip for Now", comment: "Skip button title")) {
                    viewModel.skip()
                }
                .opacity(visibleIndices.contains(3) ? 1 : 0)
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
            for index in 0...3 {
                let _ = withAnimation(.easeOut(duration: 0.4)) {
                    visibleIndices.insert(index)
                }
                try? await Task.sleep(nanoseconds: duration)
            }
        }
    }
}
