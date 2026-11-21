import Foundation

struct ChatEvidence: Sendable {
    var meetingIDs: Set<String> = []
    var meetingSeconds: [String: Set<Int>] = [:]
    var screenIDs: Set<Int64> = []
    var fileIDs: Set<Int64> = []
    var noteIDs: Set<String> = []

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
        fileIDs.formUnion(other.fileIDs)
        noteIDs.formUnion(other.noteIDs)
        for (id, seconds) in other.meetingSeconds { meetingSeconds[id, default: []].formUnion(seconds) }
    }

    func contains(_ citation: ChatCitation) -> Bool {
        if citation.kind == .screen {
            return citation.snapshotID.map(screenIDs.contains) ?? false
        }
        if citation.kind == .file {
            return citation.fileID.map(fileIDs.contains) ?? false
        }
        if citation.kind == .note {
            return noteIDs.contains(citation.sourceID.lowercased())
        }
        let id = citation.meetingID.lowercased()
        guard meetingIDs.contains(id) else { return false }
        guard let seconds = citation.seconds else { return true }
        guard let stamp = Int(exactly: seconds) else { return false }
        return meetingSeconds[id]?.contains(stamp) == true
    }
}

struct ChatCitation: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case meeting
        case screen
        case file
        case note
    }

    let kind: Kind
    let sourceID: String
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

    init(fileID: Int64) {
        kind = .file
        sourceID = String(fileID)
        seconds = nil
    }

    init(noteID: String) {
        kind = .note
        sourceID = noteID.lowercased()
        seconds = nil
    }

    var meetingID: String { sourceID }

    var snapshotID: Int64? {
        guard kind == .screen else { return nil }
        return Int64(sourceID)
    }

    var fileID: Int64? {
        guard kind == .file else { return nil }
        return Int64(sourceID)
    }

    var noteID: String? {
        kind == .note ? sourceID : nil
    }

    var id: String {
        "\(kind.rawValue):\(sourceID)@\(seconds.map { String(Int($0)) } ?? "-")"
    }

    var stampText: String? {
        seconds.map { Transcript.stamp($0) }
    }
}

enum ChatCitationParser {
    private static let pattern =
        #"\[(meeting|screen|file|note):([A-Za-z0-9_-]{1,64})(?:@(\d{1,2}(?::\d{2}){1,2}))?\]"#

    private static let groupedPattern: String = {
        let one = #"(?:meeting:)?[A-Za-z0-9_-]{1,64}(?:@\d{1,2}(?::\d{2}){1,2})?"#
        return #"\[meetings?:\s*("# + one + #"(?:\s*[,;]\s*"# + one + #")*)\]"#
    }()

    private static let markerRegex = try? NSRegularExpression(pattern: pattern)
    private static let groupedRegex = try? NSRegularExpression(pattern: groupedPattern)
    private static let anyMarkerRegex = try? NSRegularExpression(
        pattern: #"\[(?:meeting|screen|file|note):[^\]\n]*\]"#)

    static func extract(_ text: String, linked: Bool = false) -> (display: String, citations: [ChatCitation]) {
        guard text.contains("[meeting:") || text.contains("[screen:") || text.contains("[file:")
                || text.contains("[note:"),
              let regex = markerRegex else { return (text, []) }
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
            } else if kind == ChatCitation.Kind.file.rawValue,
                      stamp == nil,
                      let fileID = Int64(sourceID), fileID > 0 {
                citation = ChatCitation(fileID: fileID)
            } else if kind == ChatCitation.Kind.note.rawValue,
                      stamp == nil,
                      sourceID.count >= 8, sourceID.allSatisfy(\.isHexDigit) {
                citation = ChatCitation(noteID: sourceID)
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
            display += linked ? "[\(number)](lokalbot-citation://source/\(number))" : "[\(number)]"
        }
        display += ns.substring(from: cursor)
        return (cleaned(display), citations)
    }

    static func verified(_ text: String, evidence: ChatEvidence, streaming: Bool = false) -> String {
        var text = text
        if streaming, let bracket = text.lastIndex(of: "["),
           !text[bracket...].contains("]") {
            let suffix = text[bracket...]
            if ["[meeting:", "[meetings:", "[screen:", "[file:", "[note:"].contains(where: { $0.hasPrefix(suffix) || suffix.hasPrefix($0) }) {
                text = String(text[..<bracket])
            }
        }
        text = splitGrouped(text)
        guard let regex = anyMarkerRegex else { return text }
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

    private static func splitGrouped(_ text: String) -> String {
        guard text.contains("[meeting"),
              let regex = groupedRegex else { return text }
        var text = text
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let markers = ns.substring(with: match.range(at: 1))
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { part -> String in
                    let part = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    return "[meeting:\(part.hasPrefix("meeting:") ? String(part.dropFirst(8)) : part)]"
                }
            if let range = Range(match.range, in: text) {
                text.replaceSubrange(range, with: markers.joined(separator: " "))
            }
        }
        return text
    }

    static func seconds(from stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").map(String.init).compactMap(Int.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.dropFirst().allSatisfy({ (0..<60).contains($0) }), parts[0] >= 0 else { return nil }
        let rest = parts.count == 2 ? parts[1] : parts[1] * 60 + parts[2]
        let (scaled, scaleOverflowed) = parts[0].multipliedReportingOverflow(by: parts.count == 2 ? 60 : 3600)
        let (value, sumOverflowed) = scaled.addingReportingOverflow(rest)
        guard !scaleOverflowed, !sumOverflowed else { return nil }
        return TimeInterval(value)
    }

    private static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]+([.,;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\S)[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
