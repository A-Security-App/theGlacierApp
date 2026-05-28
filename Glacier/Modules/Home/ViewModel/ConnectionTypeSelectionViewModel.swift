//
//  ConnectionTypeSelectionViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 16/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 ConnectionTypeSelectionViewModel defines requirements for ConnectionTypeSelectionScreen view models.
 */
protocol ConnectionTypeSelectionViewModel: GlacierViewModelWithRootCoordinator {
    var selectedConnectionType: SecuredConnectionType? { get set }
    var connectionTypes: [SecuredConnectionType] { get }
    init(rootCoordinator: any GlacierRootCoordinator)
}

/**
 ConnectionTypeSelectionVM defines data/states and business logic for ConnectionTypeSelectionScreen.
 */
final class ConnectionTypeSelectionVM: ConnectionTypeSelectionViewModel, ObservableObject {
    
    // MARK: - Public properties
    
    @Published var selectedConnectionType: SecuredConnectionType? {
        didSet {
            guard let connectionType = selectedConnectionType else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.dismissSheet()
                NotificationCenter.default.post(
                    name: .userSelectedConnectionType,
                    object: nil,
                    userInfo: [GlacierNotificationProperties.connectionType : connectionType.label]
                )
            }
        }
    }
    @Published private(set) var connectionTypes: [SecuredConnectionType]
    
    let rootCoordinator: any GlacierRootCoordinator
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator) {
        self.rootCoordinator = rootCoordinator
        connectionTypes = SecuredConnectionType.allCases
    }
    
    // MARK: - Private methods
    
    private func presentDNSSettingsPrompt() {
        
    }
    
    private func presentVPNSettingsPrompt() {
        
    }
}
