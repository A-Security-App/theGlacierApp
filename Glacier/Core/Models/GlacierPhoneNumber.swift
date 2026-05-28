//
//  GlacierPhoneNumber.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 13/02/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

public struct GlacierPhoneNumber: Equatable {
    let id: String
    let number: String
    
    init(id: String = UUID().uuidString, number: String) {
        self.id = id
        self.number = number
    }
}
