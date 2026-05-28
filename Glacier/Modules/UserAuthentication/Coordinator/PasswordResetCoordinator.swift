//
//  PasswordResetCoordinator.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 30/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 `PasswordResetCoordinator` is used for presentation/navigation for password reset related screen flows like,
 - Sending password reset email and validation
 - Setting new password
 */
final class PasswordResetCoordinator: GlacierCoordinator, ObservableObject {
    
    typealias Screen = PasswordResetScreens
    
    // MARK: - Public properties
    
    @Published var path: NavigationPath = NavigationPath()
    
    @Published private(set) var currentScreen: Screen?
    @Published private(set) var presentedScreen: Screen?
    
    // MARK: - Private properties
    
    private let rootCoordinator: any GlacierRootCoordinator
    private let isPresentedFromLoginScreen: Bool
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator, isPresentedFromLoginScreen: Bool) {
        self.rootCoordinator = rootCoordinator
        self.isPresentedFromLoginScreen = isPresentedFromLoginScreen
        setCurrentScreen()
    }
    
    // MARK: - Public methods
    
    func setScreen(_ screen: Screen) {
        self.currentScreen = screen
    }
    
    func presentScreen(_ screen: Screen) {
        self.presentedScreen = screen
        path.append(screen)
    }
    
    func dismissPresentedScreen() {
        path.removeLast()
    }
    
    func presentRootScreen() {
        path.removeLast(path.count)
    }
    
    @ViewBuilder
    func build(_ screen: PasswordResetScreens) -> some View {
        switch screen {
        case .passwordReset:
            let viewModel = PasswordResetVM(
                rootCoodinator: rootCoordinator,
                passwordResetCoordinator: self,
                authenticationService: AmplifyAuthenticationService(),
                isPresentedFromLoginScreen: self.isPresentedFromLoginScreen
            )
            PasswordResetScreen(viewModel: viewModel, coordinator: self)
        case .newPasswordInput(let userName, let confirmationCode):
            let viewModel = NewPasswordInputVM(
                rootCoodinator: rootCoordinator,
                passwordResetCoordinator: self,
                authenticationService: AmplifyAuthenticationService(),
                userName: userName,
                confirmationCode: confirmationCode,
                isPresentedFromLoginScreen: self.isPresentedFromLoginScreen
            )
            NewPasswordInputScreen(viewModel: viewModel)
        }
    }
    
    // MARK: - Private methods
    
    private func setCurrentScreen() {
        setScreen(.passwordReset)
    }
}
