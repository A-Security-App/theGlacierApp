//
//  UserPermissionState.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 07/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

enum UserPermissionType {
    case location
    case contacts
    case notifications
}

enum UserPermissionState: String {
    case notDetermined
    case granted
    case denied
}
