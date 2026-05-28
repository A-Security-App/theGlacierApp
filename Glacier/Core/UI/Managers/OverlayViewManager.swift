//
//  OverlayViewManager.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import UIKit
import SwiftUI

/**
 OverlayViewManager provides clean API for presenting and dismissing global overlay views like,
 - Progress indicator view
 - Alert views
 - Prompt views, etc
 */
@MainActor
final class OverlayViewManager: ObservableObject {
    
    // MARK: - Public properties
    
    static let shared = OverlayViewManager()
    
    @Published fileprivate var popup: AnyView? {
        didSet { updateWindowVisibility() }
    }

    @Published fileprivate var progress: AnyView? {
        didSet { updateWindowVisibility() }
    }
    
    // MARK: - Private properties
    
    private var overlayWindow: UIWindow?
    
    private init() {
        setupWindow()
    }
    
    // MARK: - Public methods
    
    func presentProgressView<Content: View>(_ view: Content) {
        guard progress == nil else { return }
        progress = AnyView(view)
    }
    
    func dismissProgressView() {
        progress = nil
    }
    
    func presentPopupView<Content: View>(_ view: Content) {
        guard popup == nil else { return }
        popup = AnyView(view)
    }
    
    func dismissPopupView() {
        popup = nil
    }
    
    func isPresentingPopupView() -> Bool {
        return popup != nil
    }
    
    // MARK: - Private methods
    
    /**
     It initializes the new window that is presented over the main app window.
     This new window acts as an overlay, presenting progress, alert and prompt views.
     */
    private func setupWindow() {
        guard overlayWindow == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else { return }
        
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        
        let rootView = OverlayContainerView()
            .environmentObject(self)
        
        let hosting = UIHostingController(rootView: rootView)
        hosting.view.backgroundColor = .clear
        window.rootViewController = hosting
        window.isHidden = true
        
        overlayWindow = window
    }
    
    private func updateWindowVisibility() {
        guard let window = overlayWindow else { return }
        let shouldShow = popup != nil || progress != nil
        withAnimation(.easeIn(duration: 0.2)) {
            window.isHidden = !shouldShow
        }
    }
}

/**
 OverlayContainerView works as a wrapper view for custom propgress view, alert view and popup views
 that are presented by OverlayViewManager.
 */
struct OverlayContainerView: View {
    
    // MARK: - Private properties
    
    @EnvironmentObject private var manager: OverlayViewManager
    
    // MARK: - UI/UX
    
    var body: some View {
        ZStack {
            if let popup = manager.popup {
                popup
                    .transition(.opacity)
                    .zIndex(1)
            }
            
            if let progress = manager.progress {
                progress
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .background(Color.clear)
        .ignoresSafeArea()
    }
}
