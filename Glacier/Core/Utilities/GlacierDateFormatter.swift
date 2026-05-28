//
//  GlacierDateFormatter.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 01/03/26.
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

enum CallTimestampStyle {
    // It returns formatted date string like `Today: 12:14 PM`, `Yesterday` and `27/02/26`
    case compact
    
    // It returns formatted date string like `Today: 12:14 PM`, `Yesterday at 12:14 PM` and `Sun, Oct 28 at 12:14 PM`
    case detailed
}

/**
 GlacierDateFormatter helps in formatting date strings as more readable date and time stamps.
 */
struct GlacierDateFormatter {

    static func timestamp(for dateString: String, style: CallTimestampStyle, calendar: Calendar = .current) -> String {

        guard let date = parseDate(from: dateString) else {
            return ""
        }
        
        if calendar.isDateInToday(date) {
            return timeString(from: date)
        }

        if calendar.isDateInYesterday(date) {
            switch style {
            case .compact:
                return NSLocalizedString("Yesterday", comment: "")
            case .detailed:
                return "\(NSLocalizedString("Yesterday", comment: "")) at \(timeString(from: date))"
            }
        }

        switch style {
        case .compact:
            return shortDateString(from: date)

        case .detailed:
            return "\(weekdayMonthString(from: date)) at \(timeString(from: date))"
        }
    }
}

private extension GlacierDateFormatter {
    
    static func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
    
    static func shortDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy"
        return formatter.string(from: date)
    }
    
    static func weekdayMonthString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }
    
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }()
    
    static func parseDate(from string: String) -> Date? {
        isoFormatter.date(from: string)
    }
}
