//
//  ActivateOnDemandViewModel.swift
//  Glacier
//
//  Created by andyfriedman on 9/16/24.
//  Copyright © 2024 Glacier. All rights reserved.
//

import Foundation

class ActivateOnDemandViewModel {
    enum OnDemandField {
        case onDemand
        case nonWiFiInterface
        case wiFiInterface
        case ssid
    }

    enum OnDemandSSIDOption {
        case anySSID
        case onlySpecificSSIDs
        case exceptSpecificSSIDs
    }

    var isNonWiFiInterfaceEnabled = false
    var isWiFiInterfaceEnabled = false
    var selectedSSIDs = [String]()
    var ssidOption: OnDemandSSIDOption = .anySSID
}

extension ActivateOnDemandViewModel {
    convenience init(tunnel: TunnelContainer) {
        self.init()
        switch tunnel.onDemandOption {
        case .off:
            break
        case .wiFiInterfaceOnly(let onDemandSSIDOption):
            isWiFiInterfaceEnabled = true
            (ssidOption, selectedSSIDs) = ssidViewModel(from: onDemandSSIDOption)
        case .nonWiFiInterfaceOnly:
            isNonWiFiInterfaceEnabled = true
        case .anyInterface(let onDemandSSIDOption):
            isWiFiInterfaceEnabled = true
            isNonWiFiInterfaceEnabled = true
            (ssidOption, selectedSSIDs) = ssidViewModel(from: onDemandSSIDOption)
        }
    }

    func toOnDemandOption() -> ActivateOnDemandOption {
        switch (isWiFiInterfaceEnabled, isNonWiFiInterfaceEnabled) {
        case (false, false):
            return .off
        case (false, true):
            return .nonWiFiInterfaceOnly
        case (true, false):
            return .wiFiInterfaceOnly(toSSIDOption())
        case (true, true):
            return .anyInterface(toSSIDOption())
        }
    }
}

extension ActivateOnDemandViewModel {
    func isEnabled(field: OnDemandField) -> Bool {
        switch field {
        case .nonWiFiInterface:
            return isNonWiFiInterfaceEnabled
        case .wiFiInterface:
            return isWiFiInterfaceEnabled
        default:
            return false
        }
    }

    func setEnabled(field: OnDemandField, isEnabled: Bool) {
        switch field {
        case .nonWiFiInterface:
            isNonWiFiInterfaceEnabled = isEnabled
        case .wiFiInterface:
            isWiFiInterfaceEnabled = isEnabled
        default:
            break
        }
    }
}

extension ActivateOnDemandViewModel {
    func fixSSIDOption() {
        selectedSSIDs = uniquifiedNonEmptySelectedSSIDs()
        if selectedSSIDs.isEmpty {
            ssidOption = .anySSID
        }
    }
}

private extension ActivateOnDemandViewModel {
    func ssidViewModel(from ssidOption: ActivateOnDemandSSIDOption) -> (OnDemandSSIDOption, [String]) {
        switch ssidOption {
        case .anySSID:
            return (.anySSID, [])
        case .onlySpecificSSIDs(let ssids):
            return (.onlySpecificSSIDs, ssids)
        case .exceptSpecificSSIDs(let ssids):
            return (.exceptSpecificSSIDs, ssids)
        }
    }

    func toSSIDOption() -> ActivateOnDemandSSIDOption {
        switch ssidOption {
        case .anySSID:
            return .anySSID
        case .onlySpecificSSIDs:
            let ssids = uniquifiedNonEmptySelectedSSIDs()
            return ssids.isEmpty ? .anySSID : .onlySpecificSSIDs(selectedSSIDs)
        case .exceptSpecificSSIDs:
            let ssids = uniquifiedNonEmptySelectedSSIDs()
            return ssids.isEmpty ? .anySSID : .exceptSpecificSSIDs(selectedSSIDs)
        }
    }

    func uniquifiedNonEmptySelectedSSIDs() -> [String] {
        let nonEmptySSIDs = selectedSSIDs.filter { !$0.isEmpty }
        var seenSSIDs = Set<String>()
        var uniquified = [String]()
        for ssid in nonEmptySSIDs {
            guard !seenSSIDs.contains(ssid) else { continue }
            uniquified.append(ssid)
            seenSSIDs.insert(ssid)
        }
        return uniquified
    }
}
