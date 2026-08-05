//
//  EnableCellularViewModel.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 EnableCellularViewModel defines requirements for EnableCellularScreen view models.
 */
protocol EnableCellularViewModel: GlacierViewModelWithRootCoordinator {
    func enableCellular()
    func cancel()
}

/**
 EnableCellularVM backs EnableCellularScreen, the confirmation shown when the user turns on
 the "VPN on cellular" on-demand setting from VPN settings.

 The actual enable/cancel work is delegated back to the presenting VPN settings view model via
 callbacks, so the on-demand toggle there remains the single source of truth (mirroring the
 behavior of the confirmation alert this screen replaces).
 */
final class EnableCellularVM: EnableCellularViewModel, ObservableObject {

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

    func enableCellular() {
        dismissPresentedScreen()
        onEnable()
    }

    func cancel() {
        dismissPresentedScreen()
        onCancel()
    }
}

// MARK: - Conformance to Identifiable and Hashable protocols

extension EnableCellularVM: Identifiable, Hashable {
    static func == (lhs: EnableCellularVM, rhs: EnableCellularVM) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
