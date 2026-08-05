//
//  EnableCellularScreen.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

/**
 EnableCellularScreen is the confirmation shown when the user turns on the "VPN on cellular"
 on-demand setting from VPN settings. It mirrors CellularSetupScreen and either enables cellular
 on-demand or cancels, leaving the setting unchanged.
 */
struct EnableCellularScreen<ViewModel: EnableCellularViewModel>: View {

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
                            text: NSLocalizedString("Are you sure you want to enable VPN while on cellular?", comment: "Enable cellular screen sub header"),
                            font: .headerOne,
                            shouldReverseColor: true
                        )
                        .opacity(visibleIndices.contains(0) ? 1 : 0)
                        .padding(.top, 8)

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
                                viewModel.enableCellular()
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
