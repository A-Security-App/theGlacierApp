//
//  UserPasswordValidationChecklist.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 25/01/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation
import SwiftUI

/**
 UserPasswordValidationChecklist is used to validate user entered password against the defined validation checklist.
 */
struct UserPasswordValidationChecklist {
    let hasMinimumLength: Bool
    let hasUppercase: Bool
    let hasLowercase: Bool
    let hasNumber: Bool
    let hasSpecialCharacter: Bool

    // MARK: - Public properties
    
    static func getPasswordValidationChecklistStatus(for password: String) -> UserPasswordValidationChecklist {
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty else {
            return UserPasswordValidationChecklist.defaultState
        }
        
        let uppercaseSet = CharacterSet.uppercaseLetters
        let lowercaseSet = CharacterSet.lowercaseLetters
        let numberSet = CharacterSet.decimalDigits
        let specialSet = CharacterSet(charactersIn: "!@#$%^&*")

        return UserPasswordValidationChecklist(
            hasMinimumLength: password.count >= 8,
            hasUppercase: password.rangeOfCharacter(from: uppercaseSet) != nil,
            hasLowercase: password.rangeOfCharacter(from: lowercaseSet) != nil,
            hasNumber: password.rangeOfCharacter(from: numberSet) != nil,
            hasSpecialCharacter: password.rangeOfCharacter(from: specialSet) != nil
        )
    }
    
    var isValidPassword: Bool {
        hasMinimumLength && hasUppercase && hasLowercase && hasNumber && hasSpecialCharacter
    }
    
    func validationChecklistStatus(for colorScheme: ColorScheme) -> AttributedString {
        var validationString = AttributedString()
        validationString += getValidationText(
            for: NSLocalizedString("• At least 8 characters\n", comment: "User registration password validation check 1"),
            colorScheme: colorScheme,
            isValid: self.hasMinimumLength
        )
        validationString += getValidationText(
            for :NSLocalizedString("• At least one uppercase letter\n", comment: "User registration password validation check 2"),
            colorScheme: colorScheme,
            isValid: self.hasUppercase
        )
        validationString += getValidationText(
            for: NSLocalizedString("• At least one lowercase letter\n", comment: "User registration password validation check 3"),
            colorScheme: colorScheme,
            isValid: self.hasLowercase
        )
        validationString += getValidationText(
            for: NSLocalizedString("• At least one number\n", comment: "User registration password validation check 4"),
            colorScheme: colorScheme,
            isValid: self.hasNumber
        )
        validationString += getValidationText(
            for: NSLocalizedString("• At least one special character (!@#$%^&*)", comment: "User registration password validation check 5"),
            colorScheme: colorScheme,
            isValid: self.hasSpecialCharacter
        )
        return validationString
    }
    
    // MARK: - Private methods
    
    private func getValidationText(for text: String, colorScheme: ColorScheme, isValid: Bool) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = isValid ? .green : colorScheme == .dark ? .white : .black
        return attributed
    }
}

extension UserPasswordValidationChecklist {
    static var defaultState: UserPasswordValidationChecklist {
        UserPasswordValidationChecklist(hasMinimumLength: false, hasUppercase: false, hasLowercase: false, hasNumber: false, hasSpecialCharacter: false)
    }
}
