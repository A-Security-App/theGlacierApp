//
//  CellularSetupViewModel.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 CellularSetupViewModel defines requirements for CellularSetupScreen view models.
 */
protocol CellularSetupViewModel: GlacierViewModelWithRootCoordinator {
    init(rootCoordinator: any GlacierRootCoordinator)
    func enableCellularAndContinue()
    func skip()
}

/**
 CellularSetupVM provides data/state and business logic for CellularSetupScreen.
 */
final class CellularSetupVM: CellularSetupViewModel, ObservableObject {

    // MARK: - Public properties

    let rootCoordinator: any GlacierRootCoordinator

    // MARK: - Private properties

    private let wireGuardManager = WireGuardManager.shared()

    private var currentInstalledRegion: String {
        UserDefaults.standard.string(forKey: "glacier_vpn_installed_region") ?? "us-east-1"
    }

    // MARK: - Initializer

    required init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
    }

    // MARK: - Public methods

    func enableCellularAndContinue() {
        updateCellularOnDemand(enabled: true)
        presentScreen(.wifiSetup)
    }

    func skip() {
        presentScreen(.wifiSetup)
    }

    // MARK: - Private methods

    private func updateCellularOnDemand(enabled: Bool) {
        guard let tunnelMgr = wireGuardManager.tunnelsManager,
              let tunnel = tunnelMgr.tunnel(named: currentInstalledRegion),
              let tunnelConfig = tunnel.tunnelConfiguration else { return }

        let model = ActivateOnDemandViewModel(tunnel: tunnel)
        model.isNonWiFiInterfaceEnabled = enabled

        let onDemandOption = model.toOnDemandOption()
        tunnelMgr.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfig, onDemandOption: onDemandOption) { _ in }
    }
}
