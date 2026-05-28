//
//  ContactsManager.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 06/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import UIKit
import Contacts

/**
 ContactsManager provides an easy to use but highly efficient API for,
 - Setting up Dictionary based phone number vs phone contacts diretory so that its easier and faster to find matching contacts later.
 - Cleaning up contacts directory
 - Finding matching phone contact for given phone number
 */
final class ContactsManager {
    
    // MARK: - Public proprties
    
    static let shared = ContactsManager()
    
    // MARK: - Private properties
    
    private let queue = DispatchQueue(label: "com.glacier.contactmatcher")
    private var phoneIndex: [String: [PhoneContact]] = [:]
    private let matchingDigits = 10
    
    // MARK: - Public methods
    
    /**
     It sets up a Dictionary based phone contacts lookup dictionary for easier and faster
     contacts lookup for the given phone number.
     */
    func buildContactIndex() {
        do {
            let keys: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactThumbnailImageDataKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            let store = CNContactStore()
            
            try store.enumerateContacts(with: request) { [weak self] contact, _ in
                
                guard let self else { return }
                
                let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                let avatar = contact.thumbnailImageData.flatMap { UIImage(data: $0) }
                
                for phone in contact.phoneNumbers {
                    let rawNumber = phone.value.stringValue
                    let normalized = self.normalizeNumber(rawNumber)
                    let key = self.matchingKey(from: normalized)
                    let phoneLabel = CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: phone.label ?? CNLabelOther).capitalized

                    var initials = GlacierImages.stringInitials(withMaxCharacters: name, maxCharacters: 2) ?? ""
                    if initials.isEmpty {
                        initials = GlacierImages.stringInitials(withMaxCharacters: normalized, maxCharacters: 2) ?? ""
                    }

                    let info = PhoneContact(
                        id: "\(contact.identifier)_\(normalized)",
                        name: name,
                        initials: initials,
                        phoneNumber: normalized,
                        phoneLabel: phoneLabel,
                        avatar: avatar
                    )
                    
                    self.queue.sync {
                        if self.phoneIndex[key] != nil {
                            self.phoneIndex[key]?.append(info)
                        } else {
                            self.phoneIndex[key] = [info]
                        }
                    }
                }
            }
        } catch {
            Log.general.error("Failed to build contacts index. \(error.localizedDescription)")
        }
    }
    
    func clearIndex() {
        queue.sync {
            phoneIndex.removeAll(keepingCapacity: false)
        }
    }
    
    func matchContact(for phoneNumber: String) -> PhoneContact? {
        let normalized = normalizeNumber(phoneNumber)
        let key = matchingKey(from: normalized)
        
        return queue.sync {
            phoneIndex[key]?.first
        }
    }
    
    func matchContacts(for phoneNumber: String) -> [PhoneContact]? {
        let normalized = normalizeNumber(phoneNumber)
        let key = matchingKey(from: normalized)
        
        return queue.sync {
            phoneIndex[key]
        }
    }
    
    // MARK: - Private methods
    
    private func normalizeNumber(_ number: String) -> String {
        var digits = number.filter { $0.isNumber }
        if digits.hasPrefix("00") {
            digits.removeFirst(2)
        }
        
        return digits
    }
    
    private func matchingKey(from number: String) -> String {
        if number.count <= matchingDigits {
            return number
        }
        
        return String(number.suffix(matchingDigits))
    }
}
