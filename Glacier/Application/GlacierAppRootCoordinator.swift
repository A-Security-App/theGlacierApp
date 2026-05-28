//
//  GlacierAppRootCoordinator.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 10/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI
import Amplify

/**
 `GlacierAppRootCoordinator` works as a root coordinator that could be referenced from any view model for setting up root level screens like user authentication, user onboarding, home, etc.
 It also provides API for presenting these overlay views over the presented root screen,
 - Popups
 - Sheet
 - Full screen cover
 - Progress indicator
 */
final class GlacierAppRootCoordinator: GlacierRootCoordinator, ObservableObject {
    
    typealias Screen = GlacierScreen
    
    // MARK: - Public properties
    
    @Published var path: NavigationPath = NavigationPath()
    @Published var sheet: Sheet?

    @Published private(set) var currentScreen: Screen?
    @Published private(set) var presentedScreen: Screen?

    /// Non-nil while a phone call is active (even if user navigated away from PhoneCallScreen).
    @Published var activeCallVM: PhoneCallVM?
    /// True only while PhoneCallScreen is visible on screen.
    @Published var isViewingPhoneCallScreen: Bool = false

    // MARK: - Private properties

    private var phoneCallEndedObserver: Any?

    // MARK: - Initializer

    init() {
        phoneCallEndedObserver = NotificationCenter.default.addObserver(
            forName: .phoneCallEnded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.activeCallVM = nil
        }
    }

    deinit {
        if let observer = phoneCallEndedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Public methods
    
    func setScreen(_ screen: Screen) {
        self.currentScreen = screen
    }
    
    func presentScreen(_ screen: Screen) {
        self.presentedScreen = screen
        path.append(screen)
        if case .phoneCall(let vm) = screen {
            activeCallVM = vm
        }
    }

    func returnToActiveCall() {
        guard let callVM = activeCallVM, !isViewingPhoneCallScreen else { return }
        presentScreen(.phoneCall(callVM))
    }
    
    func dismissPresentedScreen() {
        guard path.count > 0 else { return }
        try path.removeLast()
    }
    
    func presentRootScreen() {
        path.removeLast(path.count)
    }
    
    func presentSheet(_ sheet: Sheet) {
        // Dismiss existing sheet, if being presented.
        if self.sheet != nil {
            self.sheet = nil
        }
        
        // Present given sheet
        self.sheet = sheet
    }
    
    func dismissSheet() {
        self.sheet = nil
    }
    
    func presentPopup(with configuration: PopupConfiguration) {
        Task { @MainActor in
            OverlayViewManager.shared.presentPopupView(
                GlacierPopup(configuration: configuration)
            )
        }
    }
    
    func dismissPopup() {
        Task { @MainActor in
            OverlayViewManager.shared.dismissPopupView()
        }
    }
    
    func presentProgressIndicator() {
        Task { @MainActor in
            OverlayViewManager.shared.presentProgressView(
                GlacierProgressIndicator(size: 48)
            )
        }
    }
    
    func dismissProgressIndicator() {
        Task { @MainActor in
            OverlayViewManager.shared.dismissProgressView()
        }
    }
    
    @ViewBuilder
    func build(_ screen: Screen) -> some View {
        switch screen {
        case .userAuthentication:
            let viewModel = UserAuthenticationHomeVM(rootCoodinator: self)
            UserAuthenticationHomeScreen(viewModel: viewModel)
            
        case .userAccountConfirmation:
            let viewModel = UserRegistrationVM(rootCoodinator: self, authenticationService: AmplifyAuthenticationService())
            UserRegistrationConfirmationScreen(viewModel: viewModel)
            
        case .userOnboarding:
            UserOnboardingScreen(rootCoordinator: self)
            
        case .main:
            let viewModel = MainVM(rootCoordinator: self)
            MainScreen(rootCoordinator: self, viewModel: viewModel)
            
        case .settings:
            let viewModel = SettingsVM(rootCoordinator: self)
            SettingsScreen(viewModel: viewModel)
            
        case .vpnSettings:
            let viewModel = VPNSettingsVM(rootCoordinator: self)
            VPNSettingsScreen(viewModel: viewModel)
        
        case .wifiSettings:
            let viewModel = WiFiSettingsVM(rootCoordinator: self)
            WiFiSettingsScreen(viewModel: viewModel)

        case .cellularSetup:
            let viewModel = CellularSetupVM(rootCoordinator: self)
            CellularSetupScreen(viewModel: viewModel)

        case .wifiSetup:
            let viewModel = WifiSetupVM(rootCoordinator: self)
            WifiSetupScreen(viewModel: viewModel)

        case .managePhoneNumbers:
            let viewModel = ManagePhoneNumbersVM(rootCoordinator: self)
            ManagePhoneNumbersScreen(viewModel: viewModel)
            
        case .phoneCall(let viewModel):
            PhoneCallScreen(viewModel: viewModel)
            
        case .voicemailDetails(let voicemail):
            let viewModel = VoiceMailDetailsVM(rootCoordinator: self, voiceMail: voicemail)
            VoicemailDetailsScreen(viewModel: viewModel)
        }
    }
    
    @ViewBuilder
    func build(_ sheet: Sheet) -> some View {
        switch sheet {
        case .userRegistration:
            let viewModel = UserRegistrationVM(
                rootCoodinator: self,
                authenticationService: AmplifyAuthenticationService()
            )
            UserRegistrationScreen(viewModel: viewModel)
            
        case .userLogin:
            let coordinator = PasswordResetCoordinator(
                rootCoordinator: self,
                isPresentedFromLoginScreen: true
            )
            let viewModel = UserLoginVM(
                rootCoodinator: self,
                passwordResetCoordinator: coordinator,
                authenticationService: AmplifyAuthenticationService()
            )
            UserLoginScreen(viewModel: viewModel, coordinator: coordinator)
            
        case .passwordReset:
            let coordinator = PasswordResetCoordinator(
                rootCoordinator: self,
                isPresentedFromLoginScreen: false
            )
            let viewModel = PasswordResetVM(
                rootCoodinator: self,
                passwordResetCoordinator: coordinator,
                authenticationService: AmplifyAuthenticationService(),
                isPresentedFromLoginScreen: false
            )
            PasswordResetScreen(viewModel: viewModel, coordinator: coordinator)
            
        case .glacierPlanPurchase:
            let viewModel = GlacierPlanPurchaseVM(
                rootCoodinator: self,
                service: SKGlacierPlanPurchaseService()
            )
            GlacierPlanPurchaseScreen(viewModel: viewModel)
            
        case .phoneNumberPlanPurchase:
            let viewModel = PhoneNumberPlanPurchaseVM(
                rootCoodinator: self,
                service: SKGlacierPhoneNumberPlanPurchaseService()
            )
            PhoneNumberPlanPurchaseScreen(viewModel: viewModel)
            
        case .phoneNumberSelection(let isPresentedFromPhoneScreen):
            let viewModel = PhoneNumberSelectionVM(rootCoordinator: self, isPresentedFromPhoneScreen: isPresentedFromPhoneScreen)
            PhoneNumberSelectionScreen(viewModel: viewModel)
            
        case .connectionTypeSelection:
            let viewModel = ConnectionTypeSelectionVM(rootCoordinator: self)
            ConnectionTypeSelectionScreen(viewModel: viewModel)
            
        case .appearanceSettings:
            let viewModel = AppearanceSettingsVM()
            AppearanceSettingsScreen(viewModel: viewModel)

        case .widgetSettings:
            let viewModel = WidgetSettingsVM()
            WidgetSettingsScreen(viewModel: viewModel)
        }
    }
}
