import XCTest
@testable import Glacier

final class UserPasswordValidationChecklistTests: XCTestCase {

    func testEmptyPasswordReturnsDefaultAllFalse() {
        let checklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: "")
        XCTAssertFalse(checklist.hasMinimumLength)
        XCTAssertFalse(checklist.hasUppercase)
        XCTAssertFalse(checklist.hasLowercase)
        XCTAssertFalse(checklist.hasNumber)
        XCTAssertFalse(checklist.hasSpecialCharacter)
        XCTAssertFalse(checklist.isValidPassword)
    }

    func testWhitespaceOnlyPasswordTreatedAsEmpty() {
        let checklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: "   \t\n  ")
        XCTAssertFalse(checklist.isValidPassword)
        XCTAssertFalse(checklist.hasMinimumLength)
    }

    func testFullyValidPassword() {
        let checklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: "Aa1!aaaa")
        XCTAssertTrue(checklist.hasMinimumLength)
        XCTAssertTrue(checklist.hasUppercase)
        XCTAssertTrue(checklist.hasLowercase)
        XCTAssertTrue(checklist.hasNumber)
        XCTAssertTrue(checklist.hasSpecialCharacter)
        XCTAssertTrue(checklist.isValidPassword)
    }

    func testMissingSpecialCharacterFails() {
        let checklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: "Aaaaaaa1")
        XCTAssertTrue(checklist.hasMinimumLength)
        XCTAssertTrue(checklist.hasUppercase)
        XCTAssertTrue(checklist.hasLowercase)
        XCTAssertTrue(checklist.hasNumber)
        XCTAssertFalse(checklist.hasSpecialCharacter)
        XCTAssertFalse(checklist.isValidPassword)
    }

    func testMissingUppercaseFails() {
        let checklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: "aaaaaaa1!")
        XCTAssertFalse(checklist.hasUppercase)
        XCTAssertFalse(checklist.isValidPassword)
    }

    func testMissingLowercaseFails() {
        let checklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: "AAAAAAA1!")
        XCTAssertFalse(checklist.hasLowercase)
        XCTAssertFalse(checklist.isValidPassword)
    }

    func testMissingNumberFails() {
        let checklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: "Aaaaaaaa!")
        XCTAssertFalse(checklist.hasNumber)
        XCTAssertFalse(checklist.isValidPassword)
    }

    func testSevenCharacterPasswordFailsMinimumLength() {
        let checklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: "Aa1!aaa")
        XCTAssertFalse(checklist.hasMinimumLength)
        XCTAssertFalse(checklist.isValidPassword)
    }

    func testEightCharacterPasswordPassesMinimumLengthBoundary() {
        let checklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: "Aa1!aaaa")
        XCTAssertTrue(checklist.hasMinimumLength)
    }

    func testEachAcceptedSpecialCharacterRecognized() {
        for specialChar in "!@#$%^&*" {
            let password = "Aaaaaaa1\(specialChar)"
            let checklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: password)
            XCTAssertTrue(checklist.hasSpecialCharacter, "Expected '\(specialChar)' to satisfy special-character requirement")
            XCTAssertTrue(checklist.isValidPassword, "Expected '\(password)' to be a valid password")
        }
    }

    func testUnsupportedSpecialCharacterDoesNotSatisfyRequirement() {
        // The checklist intentionally accepts only !@#$%^&* — characters like '-' or '_' must fail.
        let checklist = UserPasswordValidationChecklist.getPasswordValidationChecklistStatus(for: "Aaaaaaa1-")
        XCTAssertFalse(checklist.hasSpecialCharacter)
        XCTAssertFalse(checklist.isValidPassword)
    }
}
