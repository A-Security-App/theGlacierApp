// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import NetworkExtension

enum TunnelsManagerError: WireGuardAppError {
    case tunnelNameEmpty
    case tunnelAlreadyExistsWithThatName
    case systemErrorOnListingTunnels(systemError: Error)
    case systemErrorOnAddTunnel(systemError: Error)
    case systemErrorOnModifyTunnel(systemError: Error)
    case systemErrorOnRemoveTunnel(systemError: Error)

    var alertText: AlertText {
        switch self {
        case .tunnelNameEmpty:
            return ("No name provided", "Cannot have core profile with an empty name")
        case .tunnelAlreadyExistsWithThatName:
            return ("Name already exists", "A tunnel with that name already exists")
        case .systemErrorOnListingTunnels(let systemError):
            return ("Unable to list core tunnels", systemError.localizedUIString)
        case .systemErrorOnAddTunnel(let systemError):
            return ("Unable to create core tunnel", systemError.localizedUIString)
        case .systemErrorOnModifyTunnel(let systemError):
            return ("Unable to modify core tunnel", systemError.localizedUIString)
        case .systemErrorOnRemoveTunnel(let systemError):
            return ("Unable to remove core tunnel", systemError.localizedUIString)
        }
    }
}

enum TunnelsManagerActivationAttemptError: WireGuardAppError {
    case tunnelIsNotInactive
    case failedWhileStarting(systemError: Error) // startTunnel() throwed
    case failedWhileSaving(systemError: Error) // save config after re-enabling throwed
    case failedWhileLoading(systemError: Error) // reloading config throwed
    case failedBecauseOfTooManyErrors(lastSystemError: Error) // recursion limit reached

    var alertText: AlertText {
        switch self {
        case .tunnelIsNotInactive:
            return ("Already active", "Core is already active")
        case .failedWhileStarting(let systemError),
             .failedWhileSaving(let systemError),
             .failedWhileLoading(let systemError),
             .failedBecauseOfTooManyErrors(let systemError):
            return ("Core tunnel activation failed",
                    String(format: "Error: (%@)", systemError.localizedUIString))
        }
    }
}

enum TunnelsManagerActivationError: WireGuardAppError {
    case activationFailed(wasOnDemandEnabled: Bool)
    case activationFailedWithExtensionError(title: String, message: String, wasOnDemandEnabled: Bool)

    var alertText: AlertText {
        switch self {
        case .activationFailed:
            return ("Activation Failure", "Core could not be activated. Please ensure that you are connected to the Internet.")
        case .activationFailedWithExtensionError(let title, let message, _):
            return (title, message)
        }
    }
}

extension PacketTunnelProviderError: WireGuardAppError {
    var alertText: AlertText {
        switch self {
        case .savedProtocolConfigurationIsInvalid:
            return ("Activation Failure", "Unable to retrieve core tunnel information from the saved configuration.")
        case .dnsResolutionFailure:
            return ("DNS Resolution Failure", "One or more endpoint domains could not be resolved.")
        case .couldNotStartBackend:
            return ("Activation Failure", "Unable to turn on core tunnel.")
        case .couldNotDetermineFileDescriptor:
            return ("Activation Failure", "Unable to determine core profile details.")
        case .couldNotSetNetworkSettings:
            return ("Activation Failure", "Unable to apply network settings to core tunnel object.")
        }
    }
}

extension Error {
    var localizedUIString: String {
        if let systemError = self as? NEVPNError {
            switch systemError {
            case NEVPNError.configurationInvalid:
                return "Core configuration is invalid"
            case NEVPNError.configurationDisabled:
                return "Core configuration is disabled."
            case NEVPNError.connectionFailed:
                return "Core connection failed."
            case NEVPNError.configurationStale:
                return"Core configuration is stale."
            case NEVPNError.configurationReadWriteFailed:
                return "Reading or writing the configuration failed."
            case NEVPNError.configurationUnknown:
                return "Unknown core error."
            default:
                return ""
            }
        } else {
            return localizedDescription
        }
    }
}
