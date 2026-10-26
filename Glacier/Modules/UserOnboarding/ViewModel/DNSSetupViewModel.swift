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

    /// Progress of the profile save that starts as soon as the popup appears, so iOS already has
    /// the Glacier entry by the time the user taps "Open Settings".
    private enum ProfileSaveState {
        case idle
        case saving
        case saved
        case failed(missingProfile: Bool)
    }
    private var profileSaveState: ProfileSaveState = .idle
    /// Set when "Open Settings" is tapped while the save is still running.
    private var shouldOpenSettingsWhenSaved = false
    
    // MARK: - Initializer
    
    init(rootCoordinator: any GlacierRootCoordinator, userOnboardingCoordinator: any GlacierCoordinator) {
        self.didShowDeviceSettings = false
        self.rootCoordinator = rootCoordinator
        self.userOnboardingCoordinator = userOnboardingCoordinator
    }
    
    // MARK: - Public methods
    
    @MainActor
    func presentDNSSetupConfirmationPrompt() {
        // Save the profile while the user reads the popup rather than after "Open Settings".
        // It is saved disabled, so leaving it behind on Cancel changes nothing.
        saveDNSProfile()

        let popupConfiguration = PopupConfiguration(
            title: NSLocalizedString("Enable Glacier DNS in Settings", comment: "DNS setup popup title"),
            description: NSLocalizedString("In Settings page, navigate to:\n\nGeneral →\nVPN & Device Management →\nDNS →\n\nThen select Glacier.", comment: "DNS setup popup description") + "\n\n" + .dnsSettingsReopenTip,
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
                        self.openSettingsWhenProfileSaved()
                    }
                )
            ],
            buttonsAlignment: .horizontal
        )
        presentPopup(with: popupConfiguration)
    }
    
    func presentVPNSetupView() {
        // NOTE: VPN setup has been removed from the onboarding flow. The VPN mini-setup now
        // runs later, when the user enables VPN from VPN settings or the Choose protection
        // screen. So once DNS setup completes we skip straight to phone-number onboarding —
        // the same destination the Skip paths funnel through — bypassing both .vpnSetup and
        // .trustedNetworksSetup (trusted networks is VPN-dependent and part of that later
        // mini-setup). VPNSetupScreen/VPNSetupVM are intentionally kept in the project.
        // To restore the VPN step here, replace the line below with:
        //     setOnboardingScreen(.vpnSetup)
        navigateToPhoneNumberOnboarding()
    }
    
    func skip() {
        navigateToPhoneNumberOnboarding()
    }

    // MARK: - Private methods
    
    /// Fetches the user's profile and saves it to iOS, disabled. Does nothing while a save is
    /// running or once one has succeeded; a failed save is retried.
    private func saveDNSProfile() {
        switch profileSaveState {
        case .saving, .saved:
            return
        case .idle, .failed:
            break
        }
        profileSaveState = .saving

        let securityCenter = GlacierApplicationDelegate.appDelegate.securityCenter
        securityCenter.getDNSProfile { [weak self] dnsProfile in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // No profile available (the account isn't provisioned yet, or the fetch failed).
                // `getDNSProfile` no longer substitutes the shared backup profile, because a device
                // pinned to it never re-fetches and reports zero blocked trackers forever. Nothing
                // is stored, and `didCompleteDNSSetupDuringOnboarding` stays unset so the step can
                // be retried.
                guard let profile = dnsProfile else {
                    self.finishProfileSave(.failed(missingProfile: true))
                    return
                }
                var finalProfile = profile
                if !profile.hasPrefix("tls://"), profile.contains(SecurityCenter.DNS_BACKUP) {
                    if let deviceID = self.getShortDeviceID(length: 12) {
                        finalProfile = "tls://\(deviceID)-\(profile)"
                    } else {
                        finalProfile = "tls://\(profile)"
                    }
                }
                self.dnsOverTlsController.storeNewConfiguration(finalProfile)

                let configuration = self.dnsOverTlsController.loadSavedConfiguration()
                self.dnsOverTlsController.apply(configuration: configuration) { result in
                    guard case .success = result else {
                        self.finishProfileSave(.failed(missingProfile: false))
                        return
                    }
                    self.finishProfileSave(.saved)
                }
            }
        }
    }

    private func finishProfileSave(_ state: ProfileSaveState) {
        profileSaveState = state
        guard shouldOpenSettingsWhenSaved else { return }
        shouldOpenSettingsWhenSaved = false
        dismissProgressIndicator()
        openSettingsWhenProfileSaved()
    }

    /// "Open Settings": opens iOS Settings once the profile is saved, waiting behind a progress
    /// indicator if the save is still running, or tells the user why it couldn't be saved.
    private func openSettingsWhenProfileSaved() {
        switch profileSaveState {
        case .saved:
            // Let's open iOS settings so that user can select Glacier DNS
            guard let url = URL(string: UIApplication.settingsRootURL) else { return }
            UIApplication.shared.open(url)
            didShowDeviceSettings = true
            UserDefaultsService.shared.set(true, for: \.didCompleteDNSSetupDuringOnboarding)
        case .saving:
            shouldOpenSettingsWhenSaved = true
            presentProgressIndicator()
        case .idle:
            shouldOpenSettingsWhenSaved = true
            presentProgressIndicator()
            saveDNSProfile()
        case .failed(let missingProfile):
            // Back to idle so the next tap on the card starts a fresh attempt.
            profileSaveState = .idle
            let description = missingProfile
                ? NSLocalizedString(
                    "We couldn't finish setting up Secure DNS right now. Try again in a minute, or skip this step and turn it on later in Settings.",
                    comment: "DNS setup screen missing DNS profile error"
                )
                : NSLocalizedString("Something went wrong while adding DNS configuration. Please try again.", comment: "DNS setup screen add DNS configuration error")
            presentAlertWith(title: .errorText, description: description)
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
