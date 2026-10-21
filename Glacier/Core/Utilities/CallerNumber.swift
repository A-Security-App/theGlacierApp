//
//  CallerNumber.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI
import UIKit

/**
 CallerNumber decides whether a remote party's raw number (a Twilio `from`/`to`) is a real phone number
 the user can copy, or a placeholder for a hidden caller.

 Hidden callers reach us either as text ("anonymous", "Restricted", ...) or as the keypad spelling of
 that word, which Twilio substitutes for withheld caller ID (+266696687 is A-N-O-N-Y-M-O-U-S).
 Neither may be copied as if it were a number.
 */
enum CallerNumber {

    /// Twilio's keypad-spelled stand-ins for a withheld number, digits only.
    private static let placeholderDigits: Set<String> = [
        "266696687",    // ANONYMOUS
        "8656696",      // UNKNOWN
        "7378742833",   // RESTRICTED
        "2562533",      // BLOCKED
        "86282452253",  // UNAVAILABLE
    ]

    /// Characters a real number may contain besides digits.
    private static let formattingCharacters = CharacterSet(charactersIn: "+-() .")

    /**
     The number to copy, unchanged (Twilio sends E.164, which pastes straight into Phone), or nil
     when there's no usable number: empty, a hidden-caller placeholder, or a SIP/client address.
     */
    static func usableNumber(_ raw: String?) -> String? {
        guard let number = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !number.isEmpty else {
            return nil
        }
        // Letters mean a word ("anonymous") or an address ("sip:...", "client:..."), not a number.
        let allowed = CharacterSet.decimalDigits.union(formattingCharacters)
        guard number.unicodeScalars.allSatisfy(allowed.contains) else { return nil }

        let digits = number.filter(\.isNumber)
        guard !digits.isEmpty, !placeholderDigits.contains(digits) else { return nil }
        return number
    }

    /**
     Puts the number on the pasteboard and confirms it with a haptic and a brief "Number copied" toast.
     */
    @MainActor
    static func copy(_ number: String) {
        UIPasteboard.general.string = number
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        GlacierToast.show(NSLocalizedString("Number copied", comment: "Confirmation shown after a phone number is copied"))
    }
}

extension View {

    /**
     Adds a long-press menu with a Copy number action for a call-history or voicemail row.
     A hidden or unknown caller gets a disabled "Number unavailable" item instead, so a
     placeholder is never copied as a number.
     */
    func copyNumberContextMenu(for rawNumber: String?, onCopy: @escaping (String) -> Void) -> some View {
        contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 8))
            .contextMenu {
                if let number = CallerNumber.usableNumber(rawNumber) {
                    Button {
                        onCopy(number)
                    } label: {
                        Label(NSLocalizedString("Copy number", comment: "Context menu action that copies the caller's phone number"), systemImage: "doc.on.doc")
                    }
                } else {
                    Button {} label: {
                        Label(NSLocalizedString("Number unavailable", comment: "Disabled context menu item shown when a caller's number is hidden or unknown"), systemImage: "eye.slash")
                    }
                    .disabled(true)
                }
            }
    }
}
