// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import os.log

extension FileManager {
    static var appGroupId = "group.com.glaciersec.GlacierApp"
        
    private static var sharedFolderURL: URL? {
        guard let sharedFolderURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FileManager.appGroupId) else {
            NSLog("Cannot obtain shared folder URL")
            return nil
        }
        return sharedFolderURL
    }

    static var logFileURL: URL? {
        return sharedFolderURL?.appendingPathComponent("tunnel-log.bin")
    }

    static var networkExtensionLastErrorFileURL: URL? {
        return sharedFolderURL?.appendingPathComponent("last-error.txt")
    }

    static var loginHelperTimestampURL: URL? {
        return sharedFolderURL?.appendingPathComponent("login-helper-timestamp.bin")
    }

    static func deleteFile(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            return false
        }
        return true
    }
}
