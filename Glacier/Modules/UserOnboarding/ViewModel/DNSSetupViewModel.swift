//
//  DNSSetupViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 06/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import UIKit
import Foundation
import NetworkExtension

/**
 DNSSetupViewModel defines requirements for DNSSetupScreen view models.
 */
protocol DNSSetupViewModel: GlacierViewModelWithRootCoordinator, GlacierViewModelWithUserOnboardingCoordinator {
    var didShowDeviceSettings: Bool { get }

    init(rootCoordinator: any GlacierRootCoordinator, userOnboardingCoordinator: any GlacierCoordinator)

    @MainActor
    func presentDNSSetupConfirmationPrompt()
    func presentVPNSetupView()
    func skip()
    func prefetchAndStoreDNSProfile()
}

/**
 DNSSetupVM provides data/state and business logic for DNSSetupScreen.
 */
final class DNSSetupVM: DNSSetupViewModel {
    
    // MARK: - Public properties
    
    var didShowDeviceSettings: Bool
    let rootCoordinator: any GlacierRootCoordinator
    let userOnboardingCoordinator: any GlacierCoordinator
    
    // MARK: - Private properties
    
    private let dnsOverTlsController = DnsOverTlsController.shared
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator, userOnboardingCoordinator: any GlacierCoordinator) {
        self.didShowDeviceSettings = false
        self.rootCoordinator = rootCoordinator
        self.userOnboardingCoordinator = userOnboardingCoordinator
    }
    
    // MARK: - Public methods
    
    @MainActor
    func presentDNSSetupConfirmationPrompt() {
        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("Enable Glacier DNS in Settings", comment: "DNS setup popup title"),
            description: NSLocalizedString("In Settings page, navigate to:\n\nGeneral →\nVPN & Device Management →\nDNS →\n\nThen select Glacier.", comment: "DNS setup popup description"),
            buttons: [
                PopupButton(
                    style: .tertiary,
                    title: NSLocalizedString("Cancel", comment: "Cancel button title"),
                    onTap: {
                        self.dismissPopup()
                    }
                ),
                PopupButton(
                    style: .primary,
                    title: NSLocalizedString("Open Settings", comment: "Open settings button title"),
                    onTap: {
                        self.dismissPopup()
                        
                        // Let's add Glacier DNS configuration to user device
                        self.addDNSConfigurationToUserDevice()
                    }
                )
            ],
            buttonsAlignment: .horizontal
        )
        presentPopup(with: popupConfiguration)
    }
    
    func presentVPNSetupView() {
        setOnboardingScreen(.vpnSetup)
    }
    
    func skip() {
        navigateToPhoneNumberOnboarding()
    }

    // MARK: - Private methods
    
    @MainActor
    private func addDNSConfigurationToUserDevice() {
        let dnsOverTlsController = DnsOverTlsController.shared
        let securityCenter = GlacierApplicationDelegate.appDelegate.securityCenter
        
        presentProgressIndicator()
        securityCenter.getDNSProfile { [weak self] dnsProfile in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.dismissProgressIndicator()
            }
            
            guard let profile = dnsProfile else { return }
            var finalProfile = profile
            if !profile.hasPrefix("tls://"), profile.contains(SecurityCenter.DNS_BACKUP) {
                if let deviceID = self.getShortDeviceID(length: 12) {
                    finalProfile = "tls://\(deviceID)-\(profile)"
                } else {
                    finalProfile = "tls://\(profile)"
                }
            }
            dnsOverTlsController.storeNewConfiguration(finalProfile)
            
            let configuration = dnsOverTlsController.loadSavedConfiguration()
            dnsOverTlsController.apply(configuration: configuration) { result in
                guard case .success(let _) = result else {
                    DispatchQueue.main.async {
                        self.presentAlertWith(
                            title: .errorText,
                            description: NSLocalizedString("Something went wrong while adding DNS configuration. Please try again.", comment: "DNS setup screen add DNS configuration error")
                        )
                    }
                    return
                }
                
                // Let's open iOS settings so that user can select Glacier DNS
                //guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                guard let url = URL(string: UIApplication.settingsRootURL) else { return }
                UIApplication.shared.open(url)
                self.didShowDeviceSettings = true
                UserDefaultsService.shared.set(true, for: \.didCompleteDNSSetupDuringOnboarding)
            }
        }
    }
    
    /// Fetches the user's DNS profile_id from the API and stores it in shared UserDefaults
    /// (App Group) without enabling DNS. This ensures the NetworkExtension has a valid
    /// profile_id-based URL available if the user turns on the VPN before ever enabling DNS,
    /// preventing it from falling back to a device-generated ID that breaks analytics.
    func prefetchAndStoreDNSProfile() {
        // Don't overwrite an existing configuration — user may have already set up DNS.
        guard dnsOverTlsController.loadSavedConfiguration().urlString == nil else { return }

        let securityCenter = GlacierApplicationDelegate.appDelegate.securityCenter
        securityCenter.getDNSProfile { [weak self] dnsProfile in
            guard let self, let profile = dnsProfile else { return }
            var finalProfile = profile
            if !profile.hasPrefix("tls://"), profile.contains(SecurityCenter.DNS_BACKUP) {
                if let deviceID = self.getShortDeviceID(length: 12) {
                    finalProfile = "tls://\(deviceID)-\(profile)"
                } else {
                    finalProfile = "tls://\(profile)"
                }
            }
            self.dnsOverTlsController.storeNewConfiguration(finalProfile)
        }
    }

    private func getShortDeviceID(length: Int) -> String? {
        let deviceId = DnsOverTlsController.shared.shortDeviceID(length: length)
        let invalidSuffix = "-unknown"
        if deviceId.hasSuffix(invalidSuffix) {
            return nil
        }
        return deviceId
    }
}
