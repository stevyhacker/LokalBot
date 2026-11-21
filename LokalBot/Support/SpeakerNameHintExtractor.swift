import Foundation

enum SpeakerNameHintExtractor {
    private static let rosterHeadings = [
        "participants", "people", "members", "in this meeting", "meeting participants",
        "call participants", "attendees"
    ]

    private static let roleMarkers = [
        "(host)", "(co-host)", "(organizer)", "(presenter)", "(you)"
    ]

    private static let blockedLines: Set<String> = [
        "participants", "people", "members", "attendees", "chat", "reactions",
        "raise hand", "mute", "unmute", "camera", "share", "present", "record",
        "captions", "settings", "leave", "join", "invite", "copy link",
        "screen sharing", "you", "me", "host", "co-host", "organizer", "presenter"
    ]

    static func hints(calendarNames: [String] = [], ocrText: String = "", limit: Int = 12) -> [String] {
        unique((calendarNames.compactMap(normalizedName) + ocrRosterNames(from: ocrText)), limit: limit)
    }

    static func normalizedName(_ raw: String) -> String? {
        var name = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        name = name.replacingOccurrences(
            of: #"(?i)\s*\((host|co-host|organizer|presenter|you|me|muted|speaking)\)\s*"#,
            with: " ",
            options: .regularExpression)
        name = name.replacingOccurrences(
            of: #"(?i)\s+[-]\s+(host|co-host|organizer|presenter|muted|speaking).*$"#,
            with: "",
            options: .regularExpression)
        name = name.replacingOccurrences(
            of: #"(?i)\b(host|co-host|organizer|presenter|muted|speaking)$"#,
            with: "",
            options: .regularExpression)
        var trimSet = CharacterSet.whitespacesAndNewlines
        trimSet.formUnion(.punctuationCharacters)
        name = name
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: trimSet)

        guard (2...48).contains(name.count) else { return nil }
        let lower = name.lowercased()
        guard !blockedLines.contains(lower) else { return nil }
        guard !lower.contains("http"), !lower.contains("www."), !lower.contains("@") else { return nil }
        guard name.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }

        let words = name.split(separator: " ")
        guard (1...4).contains(words.count) else { return nil }
        guard words.allSatisfy({ word in
            String(word).rangeOfCharacter(from: .letters) != nil
        }) else { return nil }

        let scalars = name.unicodeScalars
        let letterCount = scalars.filter { CharacterSet.letters.contains($0) }.count
        guard letterCount >= 2, Double(letterCount) / Double(max(scalars.count, 1)) >= 0.65 else {
            return nil
        }
        return name
    }

    private static func ocrRosterNames(from text: String) -> [String] {
        let lines = text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var names: [String] = []
        var rosterWindow = 0
        for line in lines {
            let lower = line.lowercased()
            if rosterHeadings.contains(where: { lower.contains($0) }) {
                rosterWindow = 14
                continue
            }

            let hasRoleMarker = roleMarkers.contains { lower.contains($0) }
            guard rosterWindow > 0 || hasRoleMarker else { continue }
            if rosterWindow > 0 { rosterWindow -= 1 }
            if let name = normalizedName(line) {
                names.append(name)
            }
        }
        return unique(names, limit: 12)
    }

    private static func unique(_ names: [String], limit: Int) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in names {
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name)
            if result.count >= limit { break }
        }
        return result
    }
}
