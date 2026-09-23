import Foundation

/// Combines picker choices, never speaker attribution or persisted identities.
struct MeetingSpeakerSuggestion: Identifiable {
    let id: String
    let name: String?
    var calendar: CalendarParticipantIdentity?
    var calendarIndex: Int?
    var participant: MeetingParticipantName?

    var sources: [String] {
        var labels: [String] = []
        if let participant {
            labels.append(participant.source == .ocr ? "Screen" : "Meet")
            if participant.isSelf { labels.append("You") }
        }
        if let calendar {
            labels.append("Calendar")
            if calendar.name == nil, calendar.suggestedSpeakerName != nil { labels.append("Name from email") }
        }
        return labels.isEmpty ? ["Suggested name"] : labels
    }

    var accessibilityID: String {
        if let calendarIndex { return "speaker.rename.calendarCandidate.\(calendarIndex)" }
        if let participant { return "speaker.rename.meetParticipant.\(participant.id)" }
        return "speaker.rename.suggestion.\(id)"
    }

    static func choices(
        calendar: [CalendarParticipantIdentity],
        participants: [MeetingParticipantName],
        hints: [String]
    ) -> [Self] {
        let participants = MeetingParticipantName.merging([], participants)
        var usedCalendar = Set<Int>()
        var result: [Self] = participants.map { participant in
            let key = nameKey(participant.name)
            // Only an unambiguous, supplied display name can combine sources.
            // Email-derived guesses, historical OCR and self tiles stay separate.
            let matches = calendar.indices.filter { calendar[$0].name.map(nameKey) == key }
            let sameLabelCount = calendar.filter { $0.suggestedSpeakerName.map(nameKey) == key }.count
            let uniqueParticipant = participants.filter { nameKey($0.name) == key }.count == 1
            let index = !participant.isSelf && participant.source == .accessibility
                && uniqueParticipant && matches.count == 1 && sameLabelCount == 1 ? matches.first : nil
            if let index { usedCalendar.insert(index) }
            return Self(id: "participant:\(participant.id)", name: participant.name,
                        calendar: index.map { calendar[$0] }, calendarIndex: index, participant: participant)
        }
        for index in calendar.indices where !usedCalendar.contains(index) {
            let candidate = calendar[index]
            result.append(Self(id: "calendar:\(candidate.id)", name: candidate.suggestedSpeakerName,
                               calendar: candidate, calendarIndex: index))
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
