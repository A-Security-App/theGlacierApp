//
//  GlacierExtraPhoneNumberProduct.swift
//  Glacier
//
//  Defines the consumable IAP product used when a user wants to add a phone number
//  after exhausting their plan's free-slot allocation.
//

import Foundation

/// Namespace for the consumable $2.99 "extra phone number" in-app purchase.
///
/// This product must be configured in App Store Connect as a **Consumable** IAP:
/// - Product ID:   `com.glacier.secure.addon.extranumber`
/// - Display Name: `Additional Phone Number`
/// - Price:        $2.99 (Tier 3)
enum GlacierExtraPhoneNumberProduct {
    /// The App Store product identifier for the consumable extra-number purchase.
    static let productIdentifier = "com.glacier.secure.addon.extranumber"

    /// Formatted price string shown in paywall UI.
    static let displayPrice = "$2.99"
}
