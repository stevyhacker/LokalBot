import Foundation

enum AskMode: String, CaseIterable, Identifiable, Sendable {
    case ask = "Ask"
    case keyword = "Keyword search"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ask: "Ask"
        case .keyword: "Search"
        }
    }
}

enum AskSourceScope: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case meetings = "Meetings"
    case today = "Today"
    case screen = "Screen"
    case files = "Files"
    case agentNotes = "Agent notes"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .meetings: "Meetings"
        case .today: "Activity"
        case .screen: "Screen"
        case .files: "Files"
        case .agentNotes: "Agent notes"
        }
    }
    var icon: String {
        switch self {
        case .meetings: "person.2"
        case .today: "chart.bar.doc.horizontal"
        case .screen: "rectangle.on.rectangle"
        case .files: "folder"
        case .agentNotes: "note.text"
        }
    }

    static let defaults: Set<AskSourceScope> = [.meetings, .today, .screen, .files, .agentNotes]

    static func available(filesEnabled: Bool, agentNotesEnabled: Bool = false) -> [AskSourceScope] {
        allCases.filter { source in
            switch source {
            case .files: filesEnabled
            case .agentNotes: agentNotesEnabled
            default: true
            }
        }
    }

    static func storageValue(for scopes: Set<AskSourceScope>) -> String {
        allCases.filter(scopes.contains).map(\.rawValue).joined(separator: "|")
    }

    static func scopes(fromStorageValue value: String) -> Set<AskSourceScope> {
        let decoded = Set(value.split(separator: "|").compactMap {
            AskSourceScope(rawValue: String($0))
        })
        return decoded.isEmpty ? defaults : decoded
    }
}

enum AskDayScope {
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func date(for key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            calendar: calendar,
            year: parts[0], month: parts[1], day: parts[2]))
    }

    static func isCanonicalKey(_ key: String) -> Bool {
        guard key.count == 10 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = date(for: key, calendar: calendar) else { return false }
        return self.key(for: date, calendar: calendar) == key
    }
}

@MainActor
final class ScopedChatToolRunner: ChatToolRunner {
    private let base: ChatToolRunner
    private let scopes: Set<AskSourceScope>
    private let dayScopeKey: String?
    private let meetingIDs: Set<UUID>?
    private let meetingScope: String?
    private let namesMeetingLimit: Bool
    private let activityNotBefore: Date?
    private let focus: String?
    private let screenSnapshotIDs: Set<Int64>?

    init(base: ChatToolRunner, scopes: Set<AskSourceScope>, dayScope: Date? = nil,
         dayScopeKey: String? = nil, meetingIDs: Set<UUID>? = nil, meetingScope: String? = nil,
         namesMeetingLimit: Bool = true, activityNotBefore: Date? = nil,
         focus: String? = nil, screenSnapshotIDs: Set<Int64>? = nil) {
        self.base = base
        self.scopes = scopes
        self.meetingIDs = meetingIDs
        self.meetingScope = meetingScope
        self.namesMeetingLimit = namesMeetingLimit
        self.activityNotBefore = activityNotBefore
        self.focus = focus
        self.screenSnapshotIDs = screenSnapshotIDs
        self.dayScopeKey = dayScopeKey ?? dayScope.map { AskDayScope.key(for: $0) }
    }

    var specs: [ChatToolSpec] { base.specs.filter { allows($0.name) } }

    func attachedScreenEvidence(ids: Set<Int64>, dayScopeKey: String?) -> ChatEvidence {
        guard scopes.contains(.screen) else { return ChatEvidence() }
        let allowed = screenSnapshotIDs.map { ids.intersection($0) } ?? ids
        return base.attachedScreenEvidence(ids: allowed, dayScopeKey: self.dayScopeKey ?? dayScopeKey)
    }

    func libraryOverview() -> String {
        guard scopes.contains(.meetings), dayScopeKey == nil, meetingIDs == nil else { return "" }
        return base.libraryOverview()
    }

    var limit: String? {
        var parts: [String] = []
        if let dayScopeKey, let dates = AskDateScope(storageKey: dayScopeKey) {
            parts.append("what happened \(dates.phrase)")
        }
        if let meetingIDs, namesMeetingLimit {
            parts.append(meetingScope ?? Self.chosenMeetings(meetingIDs.count))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", and to ")
    }

    func questionScope() -> String {
        [
            limit.map { ChatPrompt.questionScope(limit: $0, datesCanBeRemoved: dayScopeKey != nil) },
            focus.map(ChatPrompt.questionFocus),
        ].compactMap { $0 }.joined(separator: "\n")
    }

    private static func chosenMeetings(_ count: Int) -> String {
        switch count {
        case 0: "no meetings"
        case 1: "the one meeting chosen for it"
        default: "the \(count) meetings chosen for it"
        }
    }

    func run(_ call: ChatToolCall) async -> ChatToolResult {
        guard allows(call.name) else {
            return ChatToolResult(
                text: "That local source was not enabled for this question.",
                summary: "source not enabled")
        }
        var scopedCall = call
        var arguments = call.arguments.filter { !$0.key.hasPrefix("_lokalbot_") }
        if let meetingIDs {
            arguments["_lokalbot_meeting_ids"] = meetingIDs.map(\.uuidString).sorted().joined(separator: ",")
        }
        if let screenSnapshotIDs {
            arguments["_lokalbot_screen_ids"] = screenSnapshotIDs.sorted().map(String.init).joined(separator: ",")
        }
        if call.name == "activity_summary" {
            arguments["_lokalbot_include_meetings"] = scopes.contains(.meetings)
                ? "true"
                : "false"
            if let activityNotBefore {
                arguments["_lokalbot_not_before"] = String(activityNotBefore.timeIntervalSince1970)
            }
        }
        if let day = dayScopeKey {
            guard AskDateScope(storageKey: day) != nil else {
                return ChatToolResult(text: "The selected date scope is invalid. Choose a date again.", summary: "invalid date scope")
            }
            if ["search_meetings", "list_meetings", "get_meeting", "get_action_items",
                "search_screen", "search_files"].contains(call.name) {
                arguments["_lokalbot_day_scope"] = day
            } else if call.name == "activity_summary" {
                arguments["day"] = day
                arguments["_lokalbot_day_scope"] = day
            }
        }
        if arguments != call.arguments {
            scopedCall = ChatToolCall(name: call.name, arguments: arguments)
        }
        let result = await base.run(scopedCall)
        guard let limit, ["search_meetings", "list_meetings", "get_action_items"].contains(call.name) else {
            return result
        }
        return ChatToolResult(
            text: "Limited to \(limit) for this question; nothing outside that limit is shown.\n\(result.text)",
            summary: result.summary, evidence: result.evidence)
    }

    private func allows(_ tool: String) -> Bool {
        switch tool {
        case "search_meetings", "list_meetings", "get_meeting", "get_action_items":
            scopes.contains(.meetings)
        case "activity_summary":
            scopes.contains(.today)
        case "search_screen":
            scopes.contains(.screen)
        case "search_files":
            scopes.contains(.files)
        case "search_agent_notes":
            scopes.contains(.agentNotes)
        default:
            false
        }
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        AskDayScope.key(for: date, calendar: calendar)
    }
}

struct AskPhase: Equatable {
    enum Page: Equatable { case newQuestion, conversation }
    enum MatchesPlacement: Equatable { case underField, trayAboveField }

    var page: Page
    var isTyping: Bool

    var showsSuggestions: Bool { page == .newQuestion && !isTyping }
    var matchesPlacement: MatchesPlacement? {
        guard isTyping else { return nil }
        return page == .newQuestion ? .underField : .trayAboveField
    }
}

enum AskIntent {
    private static let questionStarts: Set<String> = [
        "what", "why", "how", "when", "where", "who", "whom", "whose", "which",
        "did", "do", "does", "is", "are", "was", "were", "can", "could", "should",
        "would", "will", "has", "have", "had", "summarize", "summarise", "explain",
        "list", "tell", "compare", "remind", "draft",
    ]

    static func isQuestion(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard let first = words.first else { return false }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return words.count >= 2 }
        let lead = first.lowercased().trimmingCharacters(in: .punctuationCharacters)
        return words.count >= 3 && questionStarts.contains(lead)
    }
}

enum AskReturnAction: Equatable {
    case openResult, ask, none

    static func resolve(query: String, resultCount: Int, pickedWithKeyboard: Bool) -> Self {
        if pickedWithKeyboard, resultCount > 0 { return .openResult }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .ask
    }
}

enum AskAnswerScope: Equatable {
    case chosenSources
    case listedMatches

    static let fullQuestionWordCount = 4

    static func isFullQuestion(_ query: String) -> Bool {
        AskIntent.isQuestion(query)
            || query.split(whereSeparator: \.isWhitespace).count >= fullQuestionWordCount
    }

    static func resolve(query: String, hasMatches: Bool, isRememberStatement: Bool) -> Self {
        guard hasMatches, !isRememberStatement, !isFullQuestion(query) else { return .chosenSources }
        return .listedMatches
    }
}

enum AskRouter {
    static func phase(query: String, hasMessages: Bool) -> AskPhase {
        AskPhase(page: hasMessages ? .conversation : .newQuestion,
                 isTyping: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

enum AskFacet: String, CaseIterable, Identifiable {
    case all = "All"
    case transcripts = "Transcripts"
    case summaries = "Summaries"
    case notes = "Notes"
    case outcomes = "Outcomes"
    case screen = "Screen"
    case files = "Files"
    case agentNotes = "Agent notes"

    var id: String { rawValue }

    var kind: SearchIndex.Kind? {
        switch self {
        case .all, .screen, .files, .agentNotes: nil
        case .transcripts: .segment
        case .summaries: .summary
        case .notes: .notes
        case .outcomes: .outcome
        }
    }
}
