//
//  StoredModel.swift
//  Glacier
//

import Foundation

/// Base class for the model objects that wrap a `StoredRecord`. `uniqueId` is the record's
/// `uniqueId`, generated for a new model and taken from the row for a loaded one.
open class StoredModel: NSObject {

    let uniqueId: String

    public override init() {
        self.uniqueId = UUID().uuidString
    }

    public init(uniqueId: String) {
        self.uniqueId = uniqueId
    }
}
