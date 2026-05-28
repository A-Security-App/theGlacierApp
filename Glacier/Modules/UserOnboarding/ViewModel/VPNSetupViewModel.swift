//
//  VPNSetupViewModel.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 07/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import NetworkExtension
import UIKit

/**
 VPNSetupViewModel defines requirements for VPNSetupScreen view models.
 */
protocol VPNSetupViewModel: GlacierViewModelWithRootCoordinator, GlacierViewModelWithUserOnboardingCoordinator {
    var didShowVPNConfigurationPrompt: Bool { get }
    
    init(rootCoordinator: any GlacierRootCoordinator, userOnboardingCoordinator: any GlacierCoordinator)
    
    @MainActor
    func presentAddVPNConfirmationPrompt()
    func presentTrustedNetworksSetupView()
    func skip()
}

/**
 VPNSetupVM provides data/state and business logic for VPNSetupScreen.
 */
final class VPNSetupVM: VPNSetupViewModel {
    
    // MARK: - Public properties

    var didShowVPNConfigurationPrompt: Bool
    let rootCoordinator: any GlacierRootCoordinator
    let userOnboardingCoordinator: any GlacierCoordinator

    // MARK: - Private properties

    private let securityCenter = SecurityCenter()
    private let dnsController = DnsOverTlsController.shared

    // MARK: - Initializer

    init(rootCoordinator: any GlacierRootCoordinator, userOnboardingCoordinator: any GlacierCoordinator) {
        self.didShowVPNConfigurationPrompt = false
        self.rootCoordinator = rootCoordinator
        self.userOnboardingCoordinator = userOnboardingCoordinator
    }
    
    // MARK: - Public methods
    
    @MainActor
    func presentAddVPNConfirmationPrompt() {
        presentProgressIndicator()
        WireGuardManager.shared().queryForProfiles { [weak self] didLoadProfiles in
            guard let strongSelf = self else { return }
            DispatchQueue.main.async {
                strongSelf.didShowVPNConfigurationPrompt = true
                strongSelf.dismissProgressIndicator()

                guard didLoadProfiles else {
                    strongSelf.presentAlertWith(
                        title: .errorText,
                        description:
                            NSLocalizedString(
                                "Something went wrong while adding VPN configuration. Please try again.",
                                comment: "VPN setup screen VPN configuration error"
                            )
                    )
                    return
                }

                UserDefaults(suiteName: kGlacierGroup)?.set(SecuredConnectionType.vpn.rawValue, forKey: kLastConnectionTypeKey)
                UserDefaults.standard.set("us-east-1", forKey: "glacier_vpn_installed_region")

                // Ensure the DoT profile is set to full coverage now that VPN is enabled,
                // so DNS stays protected whenever on-demand rules suppress the tunnel.
                strongSelf.dnsController.ensureEnabledForVPN(
                    urlProvider: { [weak strongSelf] callback in
                        strongSelf?.securityCenter.getDNSProfile { profile in
                            callback(VPNSetupVM.buildDoTURL(from: profile,
                                                            controller: strongSelf?.dnsController))
                        }
                    },
                    completion: { _ in }
                )

                // downloadAndAdd/downloadAndApply (called inside queryForProfiles) both wait
                // for saveToPreferences to complete before firing this callback, so the iOS
                // VPN permission dialog has already been handled by the time we reach here.
                // Navigate directly — no need to wait for the scenePhase observer.
                strongSelf.presentTrustedNetworksSetupView()
            }
        }
    }

    // Normalises a raw DNS profile string from the server into a tls:// URL.
    private static func buildDoTURL(from profile: String?, controller: DnsOverTlsController?) -> String? {
        guard let profile else { return nil }
        guard !profile.hasPrefix("tls://"), profile.contains(SecurityCenter.DNS_BACKUP) else {
            return profile
        }
        let deviceID = controller?.shortDeviceID(length: 12) ?? ""
        if deviceID.hasSuffix("-unknown") || deviceID.isEmpty {
            return "tls://\(profile)"
        }
        return "tls://\(deviceID)-\(profile)"
    }
    
    func presentTrustedNetworksSetupView() {
        setOnboardingScreen(.trustedNetworksSetup)
    }
    
    func skip() {
        navigateToPhoneNumberOnboarding()
    }
}
