//
//  ErrorNotifier.swift
//  WireGuardNetworkExtension
//
//  Created by andyfriedman on 8/26/24.
//  Copyright © 2024 Glacier. All rights reserved.
//

import Foundation
import NetworkExtension
import WireGuardKit

class ErrorNotifier {
    let activationAttemptId: String?

    init(activationAttemptId: String?) {
        self.activationAttemptId = activationAttemptId
        ErrorNotifier.removeLastErrorFile()
    }

    func notify(_ error: PacketTunnelProviderError) {
        guard let activationAttemptId = activationAttemptId, let lastErrorFilePath = FileManager.networkExtensionLastErrorFileURL?.path else { return }
        let errorMessageData = "\(activationAttemptId)\n\(error)".data(using: .utf8)
        FileManager.default.createFile(atPath: lastErrorFilePath, contents: errorMessageData, attributes: nil)
    }

    static func removeLastErrorFile() {
        if let lastErrorFileURL = FileManager.networkExtensionLastErrorFileURL {
            _ = FileManager.deleteFile(at: lastErrorFileURL)
        }
    }
}
