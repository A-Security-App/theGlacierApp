//
//  UserAuthenticationViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 23/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI
import Amplify

/**
 UserAuthenticationViewModel protocol defines view model requirements for screens that presents and manages user authentication related workflows.
 */
protocol UserAuthenticationViewModel: GlacierViewModelWithRootCoordinator {
    var email: String { get set }
    var isValidEmail: Bool { get set }
    
    var shouldShowPasswordTextField: Bool { get set }
    var passwordTextFieldState: GlacierTextFieldState { get set }
    var password: String { get set }
    var isValidPassword: Bool { get set }
    
    var isContinueButtonEnabled: Bool { get set }
    var userAccount: UserAccount? { get set }
    
    @MainActor
    func signInWithEmail()
    
    @MainActor
    func signInWith(_ authProvider: AuthProvider)
}
