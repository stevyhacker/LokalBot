import Foundation

struct AskMatches {
    enum Row {
        case meeting(MeetingRecallGroup)
        case screen(ScreenRecallGroup)
        case file(FileSearchHit)
        case agentNote(AgentNoteHit)
    }

    var meetings: [MeetingRecallGroup] = []
    var screens: [ScreenRecallGroup] = []
    var files: [FileSearchHit] = []
    var agentNotes: [AgentNoteHit] = []
    var isTruncated = false

    init() {}

    init(_ result: RecallSearch.Result) {
        meetings = result.meetings
        screens = result.screens
        files = result.files
        agentNotes = result.agentNotes
        isTruncated = result.isTruncated
    }

    var count: Int { meetings.count + screens.count + files.count + agentNotes.count }
    var isEmpty: Bool { count == 0 }
    var meetingPassageCount: Int { meetings.reduce(0) { $0 + $1.matches.count } }
    var screenIDs: Set<Int64> { Set(screens.flatMap(\.matches).map(\.snapshotID)) }

    func row(at index: Int) -> Row? {
        if meetings.indices.contains(index) { return .meeting(meetings[index]) }
        let screenIndex = index - meetings.count
        if screens.indices.contains(screenIndex) { return .screen(screens[screenIndex]) }
        let fileIndex = screenIndex - screens.count
        if files.indices.contains(fileIndex) { return .file(files[fileIndex]) }
        let noteIndex = fileIndex - files.count
        return agentNotes.indices.contains(noteIndex) ? .agentNote(agentNotes[noteIndex]) : nil
    }

    func countLabel(localize: (String) -> String = { $0 }) -> String {
        if isTruncated { return "\(count.formatted())+" }
        guard screens.isEmpty, files.isEmpty, agentNotes.isEmpty, !meetings.isEmpty else {
            return count.formatted()
        }
        if meetings.count == 1 {
            return String(format: localize("%lld in 1 meeting"), meetingPassageCount)
        }
        return String(format: localize("%1$lld in %2$lld meetings"), meetingPassageCount, meetings.count)
    }
}

struct AskMatchCursor: Equatable {
    enum Direction { case up, down }

    private(set) var index: Int?

    init(index: Int? = nil) { self.index = index }

    var isInMatches: Bool { index != nil }

    @discardableResult
    mutating func move(_ direction: Direction, count: Int) -> Bool {
        guard count > 0 else {
            index = nil
            return false
        }
        switch (direction, index) {
        case (.down, nil): index = 0
        case (.down, let current?): index = min(current + 1, count - 1)
        case (.up, nil): return false
        case (.up, let current?): index = current > 0 ? min(current, count) - 1 : nil
        }
        return true
    }

    mutating func clamp(count: Int) {
        guard let current = index else { return }
        index = count > 0 ? min(current, count - 1) : nil
    }

    mutating func returnToField() { index = nil }
}

struct AskScopeSummary: Equatable {
    var title: String
    var isNarrowed: Bool
    var hasFilters: Bool
    var narrowedTo: String?
    var widenTitle: String?

    static let maximumTitleLength = 34

    struct Input {
        var sources: Set<AskSourceScope>
        var available: [AskSourceScope]
        var meetingIDs: Set<UUID>?
        var screenIDs: Set<Int64>?
        var sourcesBeforeEvidence: Set<AskSourceScope>?
        var facet: AskFacet = .all
        var screenApp: String?
    }

    static func make(_ input: Input, meetingTitle: (UUID) -> String?,
                     localize: (String) -> String = { $0 }) -> AskScopeSummary {
        let isNarrowed = input.meetingIDs != nil || input.screenIDs != nil
        let chosen = sourcesLabel(input.sources, available: input.available, localize: localize)
        let narrowedTo = isNarrowed
            ? narrowedLabel(input, meetingTitle: meetingTitle, localize: localize)
                ?? remainingSourcesLabel(input, localize: localize)
            : nil
        var parts = [shortened(narrowedTo ?? chosen)]
        if input.facet != .all { parts.append(localize(input.facet.rawValue)) }
        if let app = input.screenApp, !app.isEmpty { parts.append(app) }
        return AskScopeSummary(
            title: parts.joined(separator: " · "),
            isNarrowed: isNarrowed,
            hasFilters: input.facet != .all || !(input.screenApp ?? "").isEmpty,
            narrowedTo: narrowedTo.map(shortened),
            widenTitle: isNarrowed
                ? sourcesLabel(input.sourcesBeforeEvidence ?? AskSourceScope.defaults,
                               available: input.available, localize: localize)
                : nil)
    }

    static func sourcesLabel(_ sources: Set<AskSourceScope>, available: [AskSourceScope],
                             localize: (String) -> String = { $0 }) -> String {
        if sources.isSuperset(of: available) { return localize("All sources") }
        return available.filter(sources.contains).map { localize($0.displayName) }.joined(separator: ", ")
    }

    private static func narrowedLabel(_ input: Input, meetingTitle: (UUID) -> String?,
                                      localize: (String) -> String) -> String? {
        let meetings = input.meetingIDs ?? []
        let screens = input.screenIDs ?? []
        if screens.isEmpty, meetings.count == 1, let id = meetings.first,
           let title = meetingTitle(id)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        var parts: [String] = []
        if meetings.count == 1 {
            parts.append(String(format: localize("%lld meeting"), 1))
        } else if meetings.count > 1 {
            parts.append(String(format: localize("%lld meetings"), meetings.count))
        }
        if screens.count == 1 {
            parts.append(String(format: localize("%lld screen moment"), 1))
        } else if screens.count > 1 {
            parts.append(String(format: localize("%lld screen moments"), screens.count))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func remainingSourcesLabel(_ input: Input, localize: (String) -> String) -> String {
        var remaining = input.sources
        if input.meetingIDs?.isEmpty == true { remaining.remove(.meetings) }
        if input.screenIDs?.isEmpty == true { remaining.remove(.screen) }
        let names = input.available.filter(remaining.contains).map { localize($0.displayName) }
        return names.isEmpty ? localize("No matches") : names.joined(separator: ", ")
    }

    private static func shortened(_ text: String) -> String {
        guard text.count > maximumTitleLength else { return text }
        return String(text.prefix(maximumTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

struct AnswerSourceGroup: Identifiable, Equatable {
    struct Entry: Identifiable, Equatable {
        let number: Int
        let citation: ChatCitation
        var id: Int { number }
    }

    let kind: ChatCitation.Kind
    let key: String
    var entries: [Entry]

    var id: String { "\(kind.rawValue):\(key)" }
    var first: ChatCitation { entries[0].citation }
}

enum AnswerSources {
    static func groups(_ citations: [ChatCitation],
                       fileKey: (Int64) -> String? = { _ in nil }) -> [AnswerSourceGroup] {
        var order: [String] = []
        var groups: [String: AnswerSourceGroup] = [:]
        for (offset, citation) in citations.enumerated() {
            let key: String
            switch citation.kind {
            case .meeting: key = citation.meetingID.lowercased()
            case .screen: key = citation.sourceID
            case .file: key = citation.fileID.flatMap(fileKey) ?? "passage:\(citation.sourceID)"
            case .note: key = citation.sourceID
            }
            let entry = AnswerSourceGroup.Entry(number: offset + 1, citation: citation)
            let id = "\(citation.kind.rawValue):\(key)"
            if groups[id] == nil {
                order.append(id)
                groups[id] = AnswerSourceGroup(kind: citation.kind, key: key, entries: [entry])
            } else {
                groups[id]?.entries.append(entry)
            }
        }
        return order.compactMap { groups[$0] }
    }
}

struct CitationPassage: Equatable {
    struct Line: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var speaker: String
        var text: String
    }

    static let maximumLength = 420

    static func line(at seconds: TimeInterval, in lines: [Line]) -> Line? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let second = seconds.rounded(.towardZero)
        if let exact = lines.first(where: { $0.start.isFinite && $0.start.rounded(.towardZero) == second }) {
            return exact
        }
        if let spoken = lines.first(where: { $0.start <= seconds && seconds < $0.end }) {
            return spoken
        }
        return lines.last(where: { $0.start <= seconds })
    }

    static func quote(_ text: String?, limit: Int = maximumLength) -> String? {
        guard let text else { return nil }
        let plain = text
            .replacingOccurrences(of: "«", with: "")
            .replacingOccurrences(of: "»", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        guard plain.count > limit else { return plain }
        var cut = String(plain.prefix(limit))
        if let space = cut.lastIndex(where: \.isWhitespace), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension CitationPassage {
    static func transcriptLines(in folder: URL) -> [Line] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else { return [] }
        return lines(of: transcript)
    }

    static func lines(of transcript: Transcript) -> [Line] {
        Transcript.DisplayIndex(transcript: transcript).segments.map { display in
            Line(start: display.segment.start, end: display.segment.end,
                 speaker: display.speakerLabel, text: display.text)
        }
    }
}

struct AskSuggestion: Identifiable, Equatable {
    enum Kind: Equatable { case project, meeting, person, general, keyword }

    let kind: Kind
    let text: String

    var id: String { "\(kind).\(text)" }

    var symbol: String {
        switch self.kind {
        case .project: "folder"
        case .meeting: "waveform"
        case .person: "person.2"
        case .general: "sparkles"
        case .keyword: "magnifyingglass"
        }
    }
}

enum AskSuggestions {
    struct Input {
        var latestMeetingTitle: String?
        var personName: String?
        var projectName: String?
    }

    static func build(_ input: Input, fallback: [String],
                      localize: (String) -> String = { $0 }) -> [AskSuggestion] {
        let project = named(input.projectName)
        let meeting = named(input.latestMeetingTitle)
        let person = named(input.personName)
        var suggestions: [AskSuggestion] = []
        if let project {
            suggestions.append(.init(kind: .project, text: String(format: localize("Where does %@ stand?"), project)))
        }
        if let meeting {
            suggestions.append(.init(kind: .meeting, text: String(format: localize("What did we decide in %@?"), meeting)))
        }
        if let person {
            suggestions.append(.init(kind: .person, text: String(format: localize("What did %@ ask me to do?"), person)))
        }
        guard !suggestions.isEmpty else {
            return fallback.map { .init(kind: .general, text: localize($0)) }
        }
        if let word = keyword(from: [project, meeting].compactMap { $0 }) {
            suggestions.append(.init(kind: .keyword, text: word))
        }
        return suggestions
    }

    private static let genericWords: Set<String> = [
        "meeting", "meetings", "review", "standup", "weekly", "daily", "monthly", "sync", "call", "catch",
        "untitled", "notes", "recording", "project", "team", "with", "about", "from", "and", "the",
    ]

    static func keyword(from names: [String]) -> String? {
        let candidates = names.map { name in
            name.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 && $0.contains(where: \.isLetter) && !genericWords.contains($0.lowercased()) }
        }
        if let single = candidates.first(where: { $0.count == 1 })?.first { return single.lowercased() }
        return candidates.joined().max { $0.count < $1.count }?.lowercased()
    }

    private static func named(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name.count > 60 ? String(name.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : name
    }
}

enum AskDateLabel {
    static func moment(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                       locale: Locale = .current) -> String {
        date.formatted(dayStyle(date, now: now, calendar: calendar, locale: locale).hour().minute())
    }

    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                    locale: Locale = .current) -> String {
        date.formatted(dayStyle(date, now: now, calendar: calendar, locale: locale))
    }

    private static func dayStyle(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> Date.FormatStyle {
        var style = Date.FormatStyle()
        style.calendar = calendar
        style.locale = locale
        style.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear ? style.month(.abbreviated).day() : style.month(.abbreviated).day().year()
    }
}
