//
//  UserAccount.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 23/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

struct UserAccount: Codable, Identifiable {
    let id: String
    
    init() {
        id = UUID().uuidString
    }
}
