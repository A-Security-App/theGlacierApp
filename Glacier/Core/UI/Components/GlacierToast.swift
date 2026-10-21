//
//  GlacierToast.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import UIKit
import SwiftUI

/**
 GlacierToast briefly shows a short confirmation ("Number copied") near the bottom of the screen.

 It lives in its own window above the app and any sheet, and that window never takes touches,
 so the user can keep using the screen while the toast is visible. VoiceOver reads the message.
 */
@MainActor
final class GlacierToast: ObservableObject {

    // MARK: - Public methods

    static func show(_ message: String) {
        shared.present(message)
    }

    // MARK: - Private properties

    private static let shared = GlacierToast()
    private static let displayDuration: Duration = .seconds(1.5)

    @Published fileprivate var message: String?

    private var window: UIWindow?
    private var hideTask: Task<Void, Never>?

    private init() {}

    // MARK: - Private methods

    private func present(_ message: String) {
        setupWindowIfNeeded()
        window?.isHidden = false
        withAnimation(.easeOut(duration: 0.2)) {
            self.message = message
        }
        UIAccessibility.post(notification: .announcement, argument: message)

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        withAnimation(.easeIn(duration: 0.2)) {
            message = nil
        } completion: { [weak self] in
            guard let self, self.message == nil else { return }
            self.window?.isHidden = true
        }
    }

    private func setupWindowIfNeeded() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 2
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false

        let hosting = UIHostingController(rootView: GlacierToastView().environmentObject(self))
        hosting.view.backgroundColor = .clear
        window.rootViewController = hosting
        self.window = window
    }
}

/**
 GlacierToastView draws the current toast message, if any.
 */
private struct GlacierToastView: View {

    @EnvironmentObject private var toast: GlacierToast

    var body: some View {
        VStack {
            Spacer()

            if let message = toast.message {
                Text(message)
                    .font(.bodyThick)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(Color.grey90)
                    )
                    .overlay(
                        Capsule().stroke(Color.grey70, lineWidth: 1)
                    )
                    .padding(.horizontal, 32)
                    // Clear of the floating tab bar.
                    .padding(.bottom, 110)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
