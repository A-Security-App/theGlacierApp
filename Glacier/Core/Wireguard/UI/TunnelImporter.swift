// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import WireGuardKit

class TunnelImporter {
    static func importFromFile(urls: [URL], region: String?, into tunnelsManager: TunnelsManager, sourceVC: AnyObject?, errorPresenterType: ErrorPresenterProtocol.Type, completionHandler: (() -> Void)? = nil) {
        guard !urls.isEmpty else {
            completionHandler?()
            return
        }
        let dispatchGroup = DispatchGroup()
        var configs = [TunnelConfiguration?]()
        var lastFileImportErrorText: (title: String, message: String)?
        for url in urls {
            let fileName = url.lastPathComponent
            let fileBaseName = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            dispatchGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let fileContents: String
                do {
                    fileContents = try String(contentsOf: url)
                } catch let error {
                    DispatchQueue.main.async {
                        if let cocoaError = error as? CocoaError, cocoaError.isFileError {
                            lastFileImportErrorText = (title: "alertCantOpenInputConfFileTitle", message: error.localizedDescription)
                        } else {
                            lastFileImportErrorText = (title: "alertCantOpenInputConfFileTitle", message: String(format: "alertCantOpenInputConfFileMessage (%@)", fileName))
                        }
                        configs.append(nil)
                        dispatchGroup.leave()
                    }
                    return
                }
                var parseError: Error?
                var tunnelConfiguration: TunnelConfiguration?
                do {
                    tunnelConfiguration = try TunnelConfiguration(fromWgQuickConfig: fileContents, called: fileBaseName)
                } catch let error {
                    parseError = error
                }
                DispatchQueue.main.async {
                    if parseError != nil {
                        if let parseError = parseError as? WireGuardAppError {
                            lastFileImportErrorText = parseError.alertText
                        } else {
                            lastFileImportErrorText = (title: "alertBadConfigImportTitle", message: String(format: "alertBadConfigImportMessage (%@)", fileName))
                        }
                    }
                    configs.append(tunnelConfiguration)
                    dispatchGroup.leave()
                }
            }
        }
        dispatchGroup.notify(queue: .main) {
            tunnelsManager.addMultiple(tunnelConfigurations: configs.compactMap { $0 }, region: region) { numberSuccessful, lastAddError in
                if !configs.isEmpty && numberSuccessful == configs.count {
                    completionHandler?()
                    return
                }
                let alertText: (title: String, message: String)?
                if urls.count == 1 {
                    alertText = lastFileImportErrorText ?? lastAddError?.alertText
                } else {
                    alertText = (title: String(format: "Created %d tunnels", numberSuccessful),
                                 message: String(format: "Created %1$d of %2$d tunnels from imported files", numberSuccessful, configs.count))
                }
                if let alertText = alertText {
                    errorPresenterType.showErrorAlert(title: alertText.title, message: alertText.message, from: sourceVC, onPresented: completionHandler)
                } else {
                    completionHandler?()
                }
            }
        }
    }
}
