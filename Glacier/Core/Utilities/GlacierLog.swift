//
//  GlacierLog.swift
//  Created on 12/18/19.
//  Copyright © 2019 Glacier Security. All rights reserved.

import OSLog

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier!

    static let general  = Logger(subsystem: subsystem, category: "general")
    static let vpn      = Logger(subsystem: subsystem, category: "vpn")
    static let auth     = Logger(subsystem: subsystem, category: "auth")
    static let calls    = Logger(subsystem: subsystem, category: "calls")
    static let database = Logger(subsystem: subsystem, category: "database")
}
