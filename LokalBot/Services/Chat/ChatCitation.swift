import Foundation

/// App-owned provenance for the exact observations supplied in one turn.
/// Source text and model output never grant citation authority themselves.
struct ChatEvidence: Sendable {
    var meetingIDs: Set<String> = []
    var meetingSeconds: [String: Set<Int>] = [:]
    var screenIDs: Set<Int64> = []

    mutating func addMeeting(_ id: UUID, seconds: TimeInterval? = nil) {
        let key = SessionLookup.shortID(id).lowercased()
        meetingIDs.insert(key)
        if let seconds, seconds.isFinite, seconds >= 0,
           let stamp = Int(exactly: seconds.rounded(.towardZero)) {
            meetingSeconds[key, default: []].insert(stamp)
        }
    }

    mutating func merge(_ other: ChatEvidence) {
        meetingIDs.formUnion(other.meetingIDs)
        screenIDs.formUnion(other.screenIDs)
        for (id, seconds) in other.meetingSeconds { meetingSeconds[id, default: []].formUnion(seconds) }
    }

    func contains(_ citation: ChatCitation) -> Bool {
        if citation.kind == .screen {
            return citation.snapshotID.map(screenIDs.contains) ?? false
        }
        let id = citation.meetingID.lowercased()
        guard meetingIDs.contains(id) else { return false }
        guard let seconds = citation.seconds else { return true }
        guard let stamp = Int(exactly: seconds) else { return false }
        return meetingSeconds[id]?.contains(stamp) == true
    }
}

/// Inline citation markers the assistant emits — `[meeting:ID]`,
/// `[meeting:ID@HH:MM:SS]`, or `[screen:ID]` (see ChatPrompt's citation
/// instructions).
/// Messages are persisted with the markers in place; the chat UI replaces each
/// one in situ with a stable numbered reference and renders a matching source
/// table that deep-links to the cited evidence.
struct ChatCitation: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case meeting
        case screen
    }

    let kind: Kind
    let sourceID: String
    /// Seconds into the meeting, when the marker carried an `@HH:MM:SS` stamp.
    let seconds: TimeInterval?

    init(meetingID: String, seconds: TimeInterval?) {
        kind = .meeting
        sourceID = meetingID
        self.seconds = seconds
    }

    init(snapshotID: Int64) {
        kind = .screen
        sourceID = String(snapshotID)
        seconds = nil
    }

    /// Backwards-compatible meeting accessor used by the existing deep-link
    /// route. Callers should check `kind == .meeting` first.
    var meetingID: String { sourceID }

    var snapshotID: Int64? {
        guard kind == .screen else { return nil }
        return Int64(sourceID)
    }

    var id: String {
        "\(kind.rawValue):\(sourceID)@\(seconds.map { String(Int($0)) } ?? "-")"
    }

    var stampText: String? {
        seconds.map { Transcript.stamp($0) }
    }
}

/// Pure marker parsing, kept out of the views so it's unit-testable.
enum ChatCitationParser {
    /// Meeting IDs match SessionLookup's short ids; screen IDs are positive
    /// SQLite row IDs. Meeting stamps accept M:SS, MM:SS, or HH:MM:SS.
    private static let pattern =
        #"\[(meeting|screen):([A-Za-z0-9_-]{1,64})(?:@(\d{1,2}(?::\d{2}){1,2}))?\]"#

    /// Replace markers with ordered `[n]` references and return the matching,
    /// deduped citations. Repeated sources retain their first source number.
    static func extract(_ text: String) -> (display: String, citations: [ChatCitation]) {
        guard text.contains("[meeting:") || text.contains("[screen:"),
              let regex = try? NSRegularExpression(pattern: pattern) else { return (text, []) }
        let ns = text as NSString
        var citations: [ChatCitation] = []
        var display = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: match.range(at: 1))
            let sourceID = ns.substring(with: match.range(at: 2))
            let stamp = match.range(at: 3).location == NSNotFound
                ? nil : ns.substring(with: match.range(at: 3))
            let citation: ChatCitation?
            if kind == ChatCitation.Kind.screen.rawValue,
               stamp == nil,
               let snapshotID = Int64(sourceID), snapshotID > 0 {
                citation = ChatCitation(snapshotID: snapshotID)
            } else if kind == ChatCitation.Kind.meeting.rawValue,
                      sourceID.count >= 3,
                      stamp == nil || stamp.flatMap(seconds(from:)) != nil {
                citation = ChatCitation(
                    meetingID: sourceID,
                    seconds: stamp.flatMap(seconds(from:)))
            } else {
                citation = nil
            }
            guard let citation else { continue }

            display += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let number: Int
            if let existing = citations.firstIndex(of: citation) {
                number = existing + 1
            } else {
                citations.append(citation)
                number = citations.count
            }
            display += "[\(number)]"
        }
        display += ns.substring(from: cursor)
        return (cleaned(display), citations)
    }

    /// Apply before publishing partials or persisting final output. An invalid
    /// marker is never rendered as a source link, even for a real but unseen ID.
    static func verified(_ text: String, evidence: ChatEvidence, streaming: Bool = false) -> String {
        var text = text
        if streaming, let bracket = text.lastIndex(of: "["),
           !text[bracket...].contains("]") {
            let suffix = text[bracket...]
            if "[meeting:".hasPrefix(suffix) || "[screen:".hasPrefix(suffix)
                || suffix.hasPrefix("[meeting:") || suffix.hasPrefix("[screen:") {
                text = String(text[..<bracket])
            }
        }
        guard let regex = try? NSRegularExpression(pattern: #"\[(?:meeting|screen):[^\]\n]*\]"#) else { return text }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let marker = ns.substring(with: match.range)
            let citation = extract(marker).citations.first
            if citation.map(evidence.contains) != true,
               let range = Range(match.range, in: text) {
                text.replaceSubrange(range, with: "(source not verified)")
            }
        }
        return text
    }

    /// "1:23" → 83, "00:14:32" → 872. Nil for out-of-range fields.
    static func seconds(from stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").map(String.init).compactMap(Int.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.dropFirst().allSatisfy({ (0..<60).contains($0) }), parts[0] >= 0 else { return nil }
        let value = parts.count == 2
            ? parts[0] * 60 + parts[1]
            : parts[0] * 3600 + parts[1] * 60 + parts[2]
        return TimeInterval(value)
    }

    /// Tidy the gaps removed markers leave behind: the space before trailing
    /// punctuation and doubled interior spaces. Line-leading indentation is
    /// preserved — it's meaningful to the markdown renderer.
    private static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]+([.,;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\S)[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
