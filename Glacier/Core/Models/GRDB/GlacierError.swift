//
//  GlacierError.swift
//  Glacier
//
//  Created by andyfriedman on 2/27/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation

public protocol GRDBError: Codable, Equatable {
    var errDomain:String { get set }
    var errCode:Int { get set }
    var errDescription:String? { get set }
}

struct GlacierError: GRDBError {
    var errDomain:String
    var errCode:Int
    var errDescription:String?
    
    public init(domain:String, code:Int, description:String?) {
        self.errDomain = domain
        self.errCode = code
        self.errDescription = description
    }
    
    static func == (lhs: GlacierError, rhs: GlacierError) -> Bool {
        lhs.errDomain == rhs.errDomain && lhs.errCode == rhs.errCode && lhs.errDescription == rhs.errDescription
    }
}
