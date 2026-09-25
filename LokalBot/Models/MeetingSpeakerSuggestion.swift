import Foundation

/// Combines picker choices, never speaker attribution or persisted identities.
struct MeetingSpeakerSuggestion: Identifiable {
    let id: String
    let name: String?
    var calendar: CalendarParticipantIdentity?
    var calendarIndex: Int?

    var sources: [String] {
        guard let calendar else { return ["Suggested name"] }
        var labels = ["Calendar"]
        if calendar.name == nil, calendar.suggestedSpeakerName != nil { labels.append("Name from email") }
        return labels
    }

    var accessibilityID: String {
        if let calendarIndex { return "speaker.rename.calendarCandidate.\(calendarIndex)" }
        return "speaker.rename.suggestion.\(id)"
    }

    static func choices(
        calendar: [CalendarParticipantIdentity],
        hints: [String]
    ) -> [Self] {
        // Same-named guests stay separate: each keeps its own calendar identity.
        var result: [Self] = calendar.indices.map { index in
            let candidate = calendar[index]
            return Self(id: "calendar:\(candidate.id)", name: candidate.suggestedSpeakerName,
                        calendar: candidate, calendarIndex: index)
        }
        var knownNames = Set(result.compactMap(\.name).map(nameKey))
        for hint in hints {
            let name = hint.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = nameKey(name)
            guard !key.isEmpty, knownNames.insert(key).inserted else { continue }
            result.append(Self(id: "hint:\(key)", name: name))
        }
        return result
    }

    static func nameKey(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
