//
//  DiscoverySurvey.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import Foundation

/**
 Where the user first heard about Glacier, asked once per account on the last onboarding screen.
 The raw values are the backend's channel IDs, shared with the console and Android, and must
 not change. The order is the order shown, with **Other** and
 **I don't remember** last.
 */
enum DiscoveryChannel: String, CaseIterable, Identifiable {
    case webSearch = "web_search"
    case podcast
    case youtube
    case socialMedia = "social_media"
    case publication
    case wordOfMouth = "word_of_mouth"
    case aiAssistant = "ai_assistant"
    case appStore = "app_store"
    case other
    case dontRemember = "dont_remember"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .webSearch:
            NSLocalizedString("Web search", comment: "Discovery survey channel")
        case .podcast:
            NSLocalizedString("Podcast", comment: "Discovery survey channel")
        case .youtube:
            NSLocalizedString("YouTube", comment: "Discovery survey channel")
        case .socialMedia:
            NSLocalizedString("Social media", comment: "Discovery survey channel")
        case .publication:
            NSLocalizedString("Article, review, or newsletter", comment: "Discovery survey channel")
        case .wordOfMouth:
            NSLocalizedString("Friend or family", comment: "Discovery survey channel")
        case .aiAssistant:
            NSLocalizedString("AI assistant", comment: "Discovery survey channel")
        case .appStore:
            NSLocalizedString("App Store or Google Play", comment: "Discovery survey channel")
        case .other:
            NSLocalizedString("Other", comment: "Discovery survey channel")
        case .dontRemember:
            NSLocalizedString("I don't remember", comment: "Discovery survey channel")
        }
    }

    /// The optional follow-up question, or `nil` when this channel doesn't ask for detail.
    /// **Friend or family** deliberately has none: we never ask for the person's name.
    var detailPrompt: String? {
        switch self {
        case .podcast:
            NSLocalizedString("Which podcast?", comment: "Discovery survey detail prompt")
        case .youtube:
            NSLocalizedString("Which channel or creator?", comment: "Discovery survey detail prompt")
        case .socialMedia:
            NSLocalizedString("Which platform or account?", comment: "Discovery survey detail prompt")
        case .publication:
            NSLocalizedString("Which publication or newsletter?", comment: "Discovery survey detail prompt")
        case .aiAssistant:
            NSLocalizedString("Which AI assistant?", comment: "Discovery survey detail prompt")
        case .other:
            NSLocalizedString("Where did you hear about us?", comment: "Discovery survey detail prompt")
        case .webSearch, .wordOfMouth, .appStore, .dontRemember:
            nil
        }
    }
}

/// The user's answer. `nil` everywhere it's used means they skipped the question.
struct DiscoverySurveyAnswer: Equatable {
    /// The backend counts Unicode code points after trimming and rejects anything longer.
    static let maxDetailLength = 160

    let channel: DiscoveryChannel
    let detail: String?

    /// Turns control characters (a pasted tab, say) into spaces and trims the detail, drops it when
    /// blank or when the channel doesn't ask for one, and caps it at `maxDetailLength` code points.
    /// The backend rejects the whole answer if any of these slip through.
    init(channel: DiscoveryChannel, detail: String?) {
        self.channel = channel
        var scalars = String.UnicodeScalarView()
        for scalar in (detail ?? "").unicodeScalars {
            scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if channel.detailPrompt == nil || trimmed.isEmpty {
            self.detail = nil
        } else {
            self.detail = Self.capped(trimmed)
        }
    }

    /// `text` cut to at most `maxDetailLength` Unicode code points.
    static func capped(_ text: String) -> String {
        guard text.unicodeScalars.count > maxDetailLength else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(maxDetailLength))
        return String(scalars)
    }
}
