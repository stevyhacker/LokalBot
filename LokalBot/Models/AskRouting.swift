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
    /// The raw value stays `Today` so existing persisted conversations decode.
    /// In the UI this is the Activity source; calendar filtering is independent.
    case today = "Today"
    case screen = "Screen"
    /// The folders chosen under Files. Offered only while Files is on.
    case files = "Files"
    /// Notes the person's coding agents saved for themselves. Offered only
    /// while Read coding agent notes is on.
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

    /// Every source. Files and Agent notes are part of "All sources" whether
    /// or not they are on, so turning one on or off never makes an earlier
    /// question look narrowed.
    static let defaults: Set<AskSourceScope> = [.meetings, .today, .screen, .files, .agentNotes]

    /// The sources a person can choose now: Files and Agent notes only while
    /// each is on.
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

/// Stable civil-day persistence for Ask. A `Date` is an instant, so saving a
/// local midnight and formatting it after a time-zone change can silently move
/// the scope to the previous or next day. Store the selected YYYY-MM-DD instead.
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

/// A question-scoped tool catalogue. Disabled sources are absent from the
/// agent prompt and are still denied at execution as a second boundary.
@MainActor
final class ScopedChatToolRunner: ChatToolRunner {
    private let base: ChatToolRunner
    private let scopes: Set<AskSourceScope>
    private let dayScopeKey: String?
    private let meetingIDs: Set<UUID>?
    /// Says which meetings `meetingIDs` holds, e.g. "meetings from the last
    /// 30 days"; without it, "the meetings chosen for it".
    private let meetingScope: String?
    /// False when `meetingIDs` holds everything the asker may read and so is
    /// not worth telling the model about: it only leaves out what is never
    /// theirs, such as the sample meeting.
    private let namesMeetingLimit: Bool
    /// The first moment `activity_summary` may read, for an asker whose
    /// history starts there. Meetings are held by `meetingIDs`.
    private let activityNotBefore: Date?
    /// What the question was asked about, e.g. "the day 4 Nov 2026": where
    /// the answer starts, never a limit on the tools.
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

    /// Attached screens get the same boundary as `search_screen`: the screen
    /// source must be on and the pinned set still applies. A caller's date
    /// range applies only when this question has none of its own.
    func attachedScreenEvidence(ids: Set<Int64>, dayScopeKey: String?) -> ChatEvidence {
        guard scopes.contains(.screen) else { return ChatEvidence() }
        let allowed = screenSnapshotIDs.map { ids.intersection($0) } ?? ids
        return base.attachedScreenEvidence(ids: allowed, dayScopeKey: self.dayScopeKey ?? dayScopeKey)
    }

    func libraryOverview() -> String {
        // Source-limited and day-limited questions must not receive ambient
        // meeting titles outside the exact scope enforced by the tools below.
        guard scopes.contains(.meetings), dayScopeKey == nil, meetingIDs == nil else { return "" }
        return base.libraryOverview()
    }

    /// The dates and meetings the tools below are held to, in words that
    /// complete "limited to"; nil when nothing narrows the library.
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
        // A short list read as the whole library ("the only one in your
        // library"), so the meeting lists say what they were held to.
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

/// What the Ask page shows. A new question has the field in the middle with
/// suggestions or matches under it; a conversation keeps its thread on
/// screen with the field docked below and matches in a tray above the field.
/// Typing never replaces the conversation.
struct AskPhase: Equatable {
    enum Page: Equatable { case newQuestion, conversation }
    enum MatchesPlacement: Equatable { case underField, trayAboveField }

    var page: Page
    /// The field holds text, so its matches are listed.
    var isTyping: Bool

    var showsSuggestions: Bool { page == .newQuestion && !isTyping }
    var matchesPlacement: MatchesPlacement? {
        guard isTyping else { return nil }
        return page == .newQuestion ? .underField : .trayAboveField
    }
}

/// Whether typed input reads as a full question rather than search keywords:
/// two or more words ending in a question mark, or three or more words that
/// start with a question or request word. Return asks either way; this
/// decides what the answer reads (`AskAnswerScope`). `Benchmarks/search/Laya/run.py`
/// extracts this enum from the file and measures it.
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

/// What Return does in Ask: it asks. Only after the arrow keys moved into the
/// matches does it open the selected one. Quick Recall keeps its own rule.
enum AskReturnAction: Equatable {
    case openResult, ask, none

    static func resolve(query: String, resultCount: Int, pickedWithKeyboard: Bool) -> Self {
        if pickedWithKeyboard, resultCount > 0 { return .openResult }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .ask
    }
}

/// What an answer asked from the Ask field reads. A full question reads
/// everything in the sources and dates chosen in the composer's two menus,
/// whether or not matches are listed. A keyword or short phrase is a search
/// the person then asks about, so its answer reads the listed matches. A
/// "Remember …" statement is saved as it is and limits nothing. Scope that
/// was already set on purpose (a meeting handed over, an attached screen, the
/// menu's "Only …" state) is not this type's to change: it applies to both.
enum AskAnswerScope: Equatable {
    /// The chosen sources and dates, as the menus show them.
    case chosenSources
    /// The meetings, screen moments, files and notes listed as matches.
    case listedMatches

    /// A search is a word or a short phrase. Anything longer is treated as a
    /// question in any language, because `AskIntent` only knows English
    /// question words and a question typed without "?" in Serbian or Japanese
    /// would otherwise be answered from its matches alone.
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

/// The match types the sources menu can narrow the listed matches to.
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

    /// The FTS index kind this facet narrows to; `nil` for All (no filter),
    /// Screen (which queries the OCR store instead of the FTS index), Files
    /// (the file index) and Agent notes (their own index).
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
