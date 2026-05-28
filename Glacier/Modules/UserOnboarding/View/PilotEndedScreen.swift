import SwiftUI

/// Full-screen, non-dismissible screen shown to TestFlight pilot participants whose
/// subscription has expired.  VPN is disabled and phone numbers are released at the
/// call site (GlacierAppRootScreen) before this screen is presented.
struct PilotEndedScreen: View {

    private let feedbackURLString = "https://0z0g1.typeform.com/to/KPxVSEuW"

    @State private var visibleIndices: Set<Int> = []

    var body: some View {
        ZStack {
            GlacierBackground()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                GlacierViewContainer(shouldReverseColor: true, darkColor: .grey95, lightColor: .white) {
                    VStack(alignment: .leading, spacing: 16) {
                        GlacierLabel(
                            text: NSLocalizedString("Thank you.", comment: "Pilot ended screen header"),
                            font: .headerOne,
                            customTextColor: .constant(.grey50)
                        )
                        .opacity(visibleIndices.contains(0) ? 1 : 0)
                        .padding(.top, 8)

                        GlacierLabel(
                            text: NSLocalizedString("Your pilot has ended.", comment: "Pilot ended screen sub header"),
                            font: .headerOne,
                            shouldReverseColor: true
                        )
                        .opacity(visibleIndices.contains(1) ? 1 : 0)

                        Spacer()

                        GlacierLabel(
                            text: NSLocalizedString(
                                "Thank you so much for participating in our pilot! Please leave us your feedback — we'd love to hear from you.\n\nWe look forward to seeing you again when Glacier launches.",
                                comment: "Pilot ended screen body text"
                            ),
                            font: .headerOne,
                            customTextColor: .constant(.grey50)
                        )
                        .opacity(visibleIndices.contains(2) ? 1 : 0)

                        Spacer(minLength: 32)

                        GlacierButton(style: .tertiary, title: NSLocalizedString("Leave Feedback", comment: "Pilot ended screen feedback button title")) {
                            UIApplication.shared.openURL(feedbackURLString)
                        }
                        .opacity(visibleIndices.contains(3) ? 1 : 0)
                    }
                }
                .padding(.top, 40)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
        }
        .onAppear {
            animateContentAppearance()
        }
        .interactiveDismissDisabled(true)
    }

    // MARK: - Private methods

    private func animateContentAppearance() {
        Task {
            let duration: UInt64 = 500_000_000 // 0.5s
            for index in 0...3 {
                let _ = withAnimation(.easeOut(duration: 0.4)) {
                    visibleIndices.insert(index)
                }
                try? await Task.sleep(nanoseconds: duration)
            }
        }
    }
}
