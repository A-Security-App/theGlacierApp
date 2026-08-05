//
//  EnableVPNViewModel.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 EnableVPNViewModel defines requirements for EnableVPNScreen view models.
 */
protocol EnableVPNViewModel: GlacierViewModelWithRootCoordinator {
    func enableVPN()
    func cancel()
}

/**
 EnableVPNVM backs EnableVPNScreen, the confirmation shown when the user enables VPN from the
 VPN settings slider or the Choose protection screen — but only after the first-time VPN
 mini-setup (Cellular/Wi-Fi setup) has already been completed.

 The actual enable/cancel work is delegated back to the presenting view model via callbacks, so
 the presenter stays the single source of truth (mirroring EnableCellularVM).
 */
final class EnableVPNVM: EnableVPNViewModel, ObservableObject {

    // MARK: - Public properties

    let rootCoordinator: any GlacierRootCoordinator

    // MARK: - Private properties

    private let onEnable: () -> Void
    private let onCancel: () -> Void

    // MARK: - Initializer

    init(
        rootCoordinator: any GlacierRootCoordinator,
        onEnable: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.rootCoordinator = rootCoordinator
        self.onEnable = onEnable
        self.onCancel = onCancel
    }

    // MARK: - Public methods

    func enableVPN() {
        dismissPresentedScreen()
        onEnable()
    }

    func cancel() {
        dismissPresentedScreen()
        onCancel()
    }
}

// MARK: - Conformance to Identifiable and Hashable protocols

extension EnableVPNVM: Identifiable, Hashable {
    static func == (lhs: EnableVPNVM, rhs: EnableVPNVM) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
