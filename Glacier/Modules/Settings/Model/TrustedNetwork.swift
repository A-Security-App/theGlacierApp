//
//  TrustedNetwork.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 21/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 TrustedNetwork defines data/state for trusted WiFi networks and is used for displaying trusted networks list
 in UI and performing various operations like remove Wifi from trusted networks list, adding new trusted network, etc.
 */
struct TrustedNetwork {
    let id: String = UUID().uuidString
    let name: String
}
