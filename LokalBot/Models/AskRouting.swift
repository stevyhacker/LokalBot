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

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .meetings: "Meetings"
        case .today: "Activity"
        case .screen: "Screen"
        }
    }
    var icon: String {
        switch self {
        case .meetings: "person.2"
        case .today: "chart.bar.doc.horizontal"
        case .screen: "rectangle.on.rectangle"
        }
    }

    static let defaults: Set<AskSourceScope> = [.meetings, .today, .screen]

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

/// Explicitly attached screen moments grant Screen access for that question;
/// the attachment itself is narrow evidence and never widens retrieval time.
enum AskScopeReconciler {
    static func addingScreenContext(
        to scopes: Set<AskSourceScope>,
        dayScope: Date?
    ) -> (scopes: Set<AskSourceScope>, dayScope: Date?) {
        var reconciledScopes = scopes
        reconciledScopes.insert(.screen)
        // The attached OCR excerpt is an explicit, narrow exception. Keep the
        // selected day on every retrieval tool instead of widening the whole
        // Meetings/Screen library to Any time.
        return (reconciledScopes, dayScope)
    }
}

enum AskEscalationScope {
    static func resolve(
        mode: AskMode,
        selectedSources: Set<AskSourceScope>,
        selectedDay: Date?
    ) -> (sources: Set<AskSourceScope>, dayScope: Date?) {

        return (selectedSources, selectedDay)
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
    private let screenSnapshotIDs: Set<Int64>?

    init(base: ChatToolRunner, scopes: Set<AskSourceScope>, dayScope: Date? = nil,
         dayScopeKey: String? = nil, meetingIDs: Set<UUID>? = nil,
         screenSnapshotIDs: Set<Int64>? = nil) {
        self.base = base
        self.scopes = scopes
        self.meetingIDs = meetingIDs
        self.screenSnapshotIDs = screenSnapshotIDs
        self.dayScopeKey = dayScopeKey ?? dayScope.map { AskDayScope.key(for: $0) }
    }

    var specs: [ChatToolSpec] { base.specs.filter { allows($0.name) } }

    func libraryOverview() -> String {
        // Source-limited and day-limited questions must not receive ambient
        // meeting titles outside the exact scope enforced by the tools below.
        guard scopes.contains(.meetings), dayScopeKey == nil, meetingIDs == nil else { return "" }
        return base.libraryOverview()
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
        }
        if let day = dayScopeKey {
            guard AskDateScope(storageKey: day) != nil else {
                return ChatToolResult(text: "The selected date scope is invalid. Choose a date again.", summary: "invalid date scope")
            }
            if ["search_meetings", "list_meetings", "get_meeting", "get_action_items",
                "search_screen"].contains(call.name) {
                arguments["_lokalbot_day_scope"] = day
            } else if call.name == "activity_summary" {
                arguments["day"] = day
                arguments["_lokalbot_day_scope"] = day
            }
        }
        if arguments != call.arguments {
            scopedCall = ChatToolCall(name: call.name, arguments: arguments)
        }
        return await base.run(scopedCall)
    }

    private func allows(_ tool: String) -> Bool {
        switch tool {
        case "search_meetings", "list_meetings", "get_meeting", "get_action_items":
            scopes.contains(.meetings)
        case "activity_summary":
            scopes.contains(.today)
        case "search_screen":
            scopes.contains(.screen)
        default:
            false
        }
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        AskDayScope.key(for: date, calendar: calendar)
    }
}

/// Which mode the Ask surface shows (spec §2.3 "one input, two response
/// modes"). Typing always means live search; an empty query falls back to
/// the active conversation, or the suggestion empty state when there is none.
enum AskPhase: Equatable {
    case idle, searching, conversation
}

/// Whether typed Ask input reads as a question rather than search keywords.
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

/// What Return does in Ask. Keywords open the highlighted result and never
/// start inference; a question asks through the same path as Command-Return,
/// unless the person picked a result with the arrow keys first.
enum AskReturnAction: Equatable {
    case openResult, ask, none

    static func resolve(query: String, resultCount: Int, pickedWithKeyboard: Bool) -> Self {
        if !pickedWithKeyboard, AskIntent.isQuestion(query) { return .ask }
        return resultCount > 0 ? .openResult : .none
    }
}

enum AskRouter {
    static func phase(query: String, hasMessages: Bool) -> AskPhase {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .searching
        }
        return hasMessages ? .conversation : .idle
    }
}

/// Kind facet chips over the unified Ask result list — replaces the old
/// Search scope segmented control and its separate Screen mode.
enum AskFacet: String, CaseIterable, Identifiable {
    case all = "All"
    case transcripts = "Transcripts"
    case summaries = "Summaries"
    case screen = "Screen"

    var id: String { rawValue }

    /// The FTS index kind this facet narrows to; `nil` for All (no filter)
    /// and Screen (which queries the OCR store instead of the FTS index).
    var kind: SearchIndex.Kind? {
        switch self {
        case .all, .screen: nil
        case .transcripts: .segment
        case .summaries: .summary
        }
    }
}
