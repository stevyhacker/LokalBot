import Foundation

/// Renders tool output for the chat model. Pure value-in / string-out so the
/// formatting is unit-testable without the file system, indexes, or an engine.
/// Kept compact on purpose — observations are fed back into a small local model.
enum MeetingChatFormat {

    /// Ambient context folded into the system prompt: how many meetings exist and
    /// the most recent few, so list-style questions need no tool call.
    static func libraryOverview(_ meetings: [Meeting], limit: Int) -> String {
        guard !meetings.isEmpty else { return "The user has no recorded meetings yet." }
        let count = meetings.count
        var lines = ["The user has \(count) recorded meeting\(count == 1 ? "" : "s"). Most recent:"]
        for meeting in meetings.prefix(limit) {
            lines.append("- [\(SessionLookup.shortID(meeting.id))] \(meeting.title) — "
                + "\(dateLabel(meeting.startedAt)), \(meeting.durationLabel)")
        }
        if count > limit { lines.append("- … and \(count - limit) older.") }
        return lines.joined(separator: "\n")
    }

    static func list(_ meetings: [Meeting]) -> String {
        guard !meetings.isEmpty else { return "No meetings match." }
        return meetings.map { meeting in
            "- [\(SessionLookup.shortID(meeting.id))] \(meeting.title) — "
                + "\(dateLabel(meeting.startedAt)), \(meeting.durationLabel), \(meeting.appName)"
        }.joined(separator: "\n")
    }

    static func searchResults(query: String,
                              keyword: [SearchIndex.Hit],
                              semantic: [EmbeddingIndex.Hit],
                              meetings: [Meeting]) -> String {
        guard !keyword.isEmpty || !semantic.isEmpty else { return "No matches for “\(query)”." }
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func title(_ id: UUID) -> String { byID[id]?.title ?? "Unknown meeting" }

        var lines: [String] = []
        if !keyword.isEmpty {
            lines.append("Keyword matches:")
            for hit in keyword.prefix(8) {
                let stamp = hit.kind == .segment ? " @ \(Transcript.stamp(hit.start))" : ""
                let who = hit.speaker.isEmpty ? "" : " (\(hit.speaker))"
                lines.append("- [\(SessionLookup.shortID(hit.meetingID))] \(title(hit.meetingID))"
                    + "\(stamp) [\(hit.kind.rawValue)]\(who): \(keywordPassage(hit))")
            }
        }
        if !semantic.isEmpty {
            lines.append("Related (semantic) matches:")
            for hit in semantic.prefix(5) {
                let stamp = hit.start > 0 ? " @ \(Transcript.stamp(hit.start))" : ""
                lines.append("- [\(SessionLookup.shortID(hit.meetingID))] \(title(hit.meetingID))"
                    + "\(stamp): \(clean(hit.text))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func outcomes(_ entries: [(meeting: Meeting, outcomes: MeetingOutcomes)]) -> String {
        guard !entries.isEmpty else {
            return "No structured outcomes found. Outcomes are extracted when a meeting is "
                + "summarized, so meetings processed before this feature have none."
        }
        var lines: [String] = []
        for entry in entries {
            lines.append("# [\(SessionLookup.shortID(entry.meeting.id))] \(entry.meeting.title)"
                + " — \(dateLabel(entry.meeting.startedAt))")
            if !entry.outcomes.userActionItems.isEmpty {
                lines.append("My action items:")
                for item in entry.outcomes.userActionItems {
                    var notes: [String] = []
                    if let due = item.due { notes.append("due: \(due)") }
                    lines.append("- \(item.text)"
                        + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"))
                }
            }
            if !entry.outcomes.otherActionItems.isEmpty {
                lines.append("Other action items:")
                for item in entry.outcomes.otherActionItems {
                    var notes: [String] = []
                    if let owner = item.owner { notes.append("owner: \(owner)") }
                    if let due = item.due { notes.append("due: \(due)") }
                    lines.append("- \(item.text)"
                        + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"))
                }
            }
            if !entry.outcomes.decisions.isEmpty {
                lines.append("Decisions:")
                lines.append(contentsOf: entry.outcomes.decisions.map { "- \($0)" })
            }
            if !entry.outcomes.openQuestions.isEmpty {
                lines.append("Open questions:")
                lines.append(contentsOf: entry.outcomes.openQuestions.map { "- \($0)" })
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func threadedOutcomes(
        _ projections: [MeetingOutcomeProjection],
        statusFilter: ActionStatusFilter = .all
    ) -> String {
        let threads = ActionThreadClusterer.cluster(
            projections.flatMap(\.actionReferences))
            .filter(statusFilter.includes)
        var sections: [String] = []
        if !threads.isEmpty {
            var lines = ["# Action threads"]
            for thread in threads {
                var notes: [String] = []
                if let owner = thread.owner, !thread.isForUser {
                    notes.append("owner: \(owner)")
                }
                if let due = thread.due { notes.append("due: \(due)") }
                notes.append("status: \(thread.statusLabel.lowercased())")
                let sources = thread.references.map {
                    SessionLookup.shortID($0.meetingID)
                }.reduce(into: [String]()) { result, id in
                    if !result.contains(id) { result.append(id) }
                }
                notes.append("sources: " + sources.map { "[\($0)]" }.joined(separator: ", "))
                if thread.hasMixedStatus {
                    notes.append(thread.references.map {
                        "[\(SessionLookup.shortID($0.meetingID))]: \($0.status.rawValue)"
                    }.joined(separator: ", "))
                }
                lines.append("- \(thread.text) (\(notes.joined(separator: ", ")))")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        let nonActionEntries = projections.compactMap { projection
            -> (meeting: Meeting, outcomes: MeetingOutcomes)? in
            var outcomes = projection.outcomes
            outcomes.actionItems = []
            return outcomes.isEmpty
                ? nil
                : (meeting: projection.meeting, outcomes: outcomes)
        }
        if !nonActionEntries.isEmpty {
            sections.append(outcomes(nonActionEntries))
        }
        if sections.isEmpty, !projections.isEmpty {
            return "No \(statusFilter.description)action items found in this scope."
        }
        return sections.isEmpty ? outcomes([]) : sections.joined(separator: "\n\n")
    }

    static func meeting(_ meeting: Meeting, summary: String?, transcript: String?,
                        include: String, transcriptContinuation: String? = nil) -> String {
        let want = include.lowercased()
        let all = want.contains("all")
        var lines = [
            "# \(meeting.title)",
            "Date: \(dateLabel(meeting.startedAt)) · Duration: \(meeting.durationLabel)"
                + " · App: \(meeting.appName) · ID: \(SessionLookup.shortID(meeting.id))",
        ]
        if all || want.contains("summary") || (!want.contains("transcript")) {
            lines.append("")
            lines.append("## Summary")
            lines.append(summary?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "No summary available for this meeting yet.")
        }
        if all || want.contains("transcript") {
            lines.append("")
            lines.append("## Transcript")
            if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(capped(transcript, max: 6000))
            } else {
                lines.append("No transcript available for this meeting yet.")
            }
            if let transcriptContinuation {
                lines.append("")
                lines.append(transcriptContinuation)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One window of a structured transcript, starting at `start` seconds.
    /// `nextStart` is where the following window begins when the rest did not
    /// fit, so a long meeting is never presented to the model as complete.
    static func transcriptObservation(_ transcript: Transcript, from start: TimeInterval = 0,
                                      maximumCharacters: Int = 6_000)
        -> (text: String, seconds: [TimeInterval], nextStart: TimeInterval?) {
        var text = ""
        var seconds: [TimeInterval] = []
        var windowIsFull = false
        for display in Transcript.DisplayIndex(transcript: transcript).segments {
            let segmentStart = display.segment.start
            guard segmentStart.isFinite, segmentStart >= 0,
                  Int(exactly: segmentStart.rounded(.towardZero)) != nil else { continue }
            guard segmentStart >= start || display.segment.end > start else { continue }
            if windowIsFull { return (text, seconds, segmentStart) }
            let separator = text.isEmpty ? "" : "\n\n"
            let line = "**[\(Transcript.stamp(segmentStart))] \(display.speakerLabel):** " + display.text
            if line.count <= maximumCharacters - text.count - separator.count {
                text += separator + line
                seconds.append(segmentStart)
                continue
            }
            // The next window starts with this whole line. Only a line longer
            // than a window is cut, and reading then moves past it.
            guard text.isEmpty else { return (text, seconds, segmentStart) }
            text = String(line.prefix(max(0, maximumCharacters - 1))) + "…"
            seconds.append(segmentStart)
            windowIsFull = true
        }
        return (text, seconds, nil)
    }

    static func transcriptContinuation(next: TimeInterval) -> String {
        "[The transcript continues at \(Transcript.stamp(next)). To read on, call get_meeting with this id, "
            + "include=transcript and from=\(Transcript.stamp(next)).]"
    }

    // MARK: - Screen / activity formatters

    static func screenResults(query: String, hits: [ActivityStore.OCRHit]) -> String {
        guard !hits.isEmpty else {
            return "No screen-text matches for “\(query)”. Screen text is only kept "
                + "for the configured retention window."
        }
        var lines = ["Screen-text matches (from on-device screen captures):"]
        for hit in hits.prefix(12) {
            let title = hit.windowTitle.isEmpty ? "" : " · \(clean(hit.windowTitle))"
            lines.append("- [screen:\(hit.snapshotID)] [\(hit.app)\(title)] "
                + "\(dateLabel(hit.ts)): \(clean(hit.snippet))")
        }
        return lines.joined(separator: "\n")
    }

    /// One line per file: its citation marker, name, kind and date, folder,
    /// then the matched passage (or the words that matched, for a picture).
    static func fileResults(query: String, hits: [(hit: FileSearchHit, passage: String?)]) -> String {
        guard !hits.isEmpty else {
            return "No files matched “\(query)” in the folders chosen under Files."
        }
        var lines = ["Files matching “\(query)” (from folders the user chose to search):"]
        for (hit, passage) in hits {
            let date = hit.date.formatted(date: .abbreviated, time: .omitted)
            let body = clean(String((passage ?? hit.excerpt ?? "").prefix(700)))
            lines.append("- [file:\(hit.id)] \(hit.name) (\(hit.kindLabel), \(date)) in \(hit.folder)"
                + (body.isEmpty ? " — a picture without text" : ": \(body)"))
        }
        return lines.joined(separator: "\n")
    }

    static func activitySummary(dayLabel: String, blocks: [ActivityBlock],
                                meetings: [Meeting]) -> String {
        guard !blocks.isEmpty else {
            return "No app activity tracked on \(dayLabel)."
        }
        // Aggregate per app: total time plus the most-used window titles.
        var totals: [String: TimeInterval] = [:]
        var titles: [String: [String: TimeInterval]] = [:]
        for block in blocks {
            totals[block.app, default: 0] += block.duration
            if !block.title.isEmpty {
                titles[block.app, default: [:]][block.title, default: 0] += block.duration
            }
        }
        let tracked = totals.values.reduce(0, +)
        var lines = ["# Activity on \(dayLabel)",
                     "Tracked \(durationLabel(tracked)) across \(totals.count) app\(totals.count == 1 ? "" : "s")."]
        for (app, seconds) in totals.sorted(by: { $0.value > $1.value }).prefix(10) {
            let top = (titles[app] ?? [:])
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { clean($0.key) }
            let detail = top.isEmpty ? "" : " — \(top.joined(separator: "; "))"
            lines.append("- \(app): \(durationLabel(seconds))\(detail)")
        }
        if !meetings.isEmpty {
            lines.append("")
            lines.append("Recorded meetings that day:")
            for meeting in meetings {
                lines.append("- [\(SessionLookup.shortID(meeting.id))] \(meeting.title) — "
                    + "\(dateLabel(meeting.startedAt)), \(meeting.durationLabel)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "2h 05m" / "12m" / "40s".
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let (h, m) = (total / 3600, (total % 3600) / 60)
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    // MARK: - Helpers

    /// The whole transcript utterance or summary line around a keyword match.
    /// An FTS snippet keeps about 14 tokens and can cut a nearby "not" out of
    /// the observation. A line longer than the cap keeps the snippet.
    static func keywordPassage(_ hit: SearchIndex.Hit, maximumCharacters: Int = 600) -> String {
        var anchor = hit.snippet.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
        if anchor.hasPrefix("…") { anchor.removeFirst() }
        if anchor.hasSuffix("…") { anchor.removeLast() }
        guard let source = hit.sourceText, !anchor.isEmpty,
              let match = source.range(of: anchor) else { return clean(hit.snippet) }
        let start = source[..<match.lowerBound].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        let end = source[match.upperBound...].firstIndex(of: "\n") ?? source.endIndex
        let line = source[start..<end]
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return line.count <= maximumCharacters ? line : clean(hit.snippet)
    }

    /// Strip FTS5 «»-markers, collapse whitespace, and cap a single snippet.
    static func clean(_ snippet: String) -> String {
        let collapsed = snippet
            .replacingOccurrences(of: "«", with: "")
            .replacingOccurrences(of: "»", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 220 ? String(collapsed.prefix(220)) + "…" : collapsed
    }

    static func capped(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max)) + "\n…(truncated)"
    }

    static func dateLabel(_ date: Date) -> String { formatter.string(from: date) }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// The chat tool surface: natural-language search, listing, and reading
/// meetings, plus screen/activity context (OCR'd screen text and per-app time).
/// Backed by the app's live state — the loaded meeting list, the FTS5 keyword
/// index, the semantic embedding index, the activity store, and on-disk
/// artifacts — so the chat reflects exactly what the rest of the app sees.
@MainActor
final class MeetingChatTools: ChatToolRunner {
    private let meetingsProvider: () -> [Meeting]
    private let storage: StorageManager
    private let searchIndex: SearchIndex
    private let embeddingIndex: EmbeddingIndex
    private let activityStore: ActivityStore
    private let settingsProvider: () -> AppSettings
    /// The Files search, while Files is on and has folders; nil otherwise, and
    /// then `search_files` is not offered at all.
    private let filesProvider: () -> FileSearchService?
    /// Relative days ("last 7 days", "yesterday") resolve against this clock.
    private let now: () -> Date

    init(meetings: @escaping () -> [Meeting],
         storage: StorageManager,
         searchIndex: SearchIndex,
         embeddingIndex: EmbeddingIndex,
         activityStore: ActivityStore,
         settings: @escaping () -> AppSettings,
         files: @escaping () -> FileSearchService? = { nil },
         now: @escaping () -> Date = Date.init) {
        self.meetingsProvider = meetings
        self.storage = storage
        self.searchIndex = searchIndex
        self.embeddingIndex = embeddingIndex
        self.activityStore = activityStore
        self.settingsProvider = settings
        self.filesProvider = files
        self.now = now
    }

    var specs: [ChatToolSpec] {
        filesProvider() == nil ? Self.baseSpecs : Self.baseSpecs + [Self.searchFilesSpec]
    }

    static let searchFilesSpec = ChatToolSpec(
        name: "search_files",
        summary: "Search the folders the user chose under Files (documents, PDFs, pictures and screenshots on this Mac) by what they say or show. Returns matching files with the passage that matched.",
        arguments: [
            .init(name: "query", description: "What to look for, in natural language or keywords.", required: true),
        ])

    private static let baseSpecs: [ChatToolSpec] = [
        ChatToolSpec(
            name: "search_meetings",
            summary: "Search across every meeting transcript, summary and title. Accepts natural-language or keyword queries; returns matching meetings with timestamps and snippets.",
            arguments: [
                .init(name: "query", description: "What to look for, in natural language or keywords.", required: true),
            ]),
        ChatToolSpec(
            name: "list_meetings",
            summary: "List recorded meetings, newest first, optionally filtered by a title substring.",
            arguments: [
                .init(name: "query", description: "Optional case-insensitive title filter.", required: false),
                .init(name: "limit", description: "Maximum number to return (default 15).", required: false),
            ]),
        ChatToolSpec(
            name: "get_meeting",
            summary: "Read one meeting's summary, or its transcript one window at a time.",
            arguments: [
                .init(name: "id", description: "Meeting id from another tool's output, or 'latest' for the most recent.", required: true),
                .init(name: "include", description: "What to return: 'summary' (default), 'transcript', or 'all'.", required: false),
                .init(name: "from", description: "Transcript start time as HH:MM:SS, to continue a long transcript or jump to a search hit (default: the beginning).", required: false),
            ]),
        ChatToolSpec(
            name: "get_action_items",
            summary: "Saved action items with completion status, decisions and open questions. Use status=done for completed work, active for outstanding work, or all for history. Give an id for one meeting, or scan recent days.",
            arguments: [
                .init(name: "id", description: "Meeting id, or 'latest'. Omit to scan recent meetings.", required: false),
                .init(name: "days", description: "When no id: how many days back to scan (default 7).", required: false),
                .init(name: "status", description: "all (default), active (open or deferred), open, deferred, or done. Mixed threads include each source status.", required: false),
            ]),
        ChatToolSpec(
            name: "search_screen",
            summary: "Search text the user has SEEN on screen (OCR'd from on-device screen captures, outside of meetings too). Returns app, window and a snippet with a timestamp.",
            arguments: [
                .init(name: "query", description: "What to look for, in natural language or keywords.", required: true),
            ]),
        ChatToolSpec(
            name: "activity_summary",
            summary: "How the user spent their time in apps on a given day: per-app durations, top windows, and any recorded meetings.",
            arguments: [
                .init(name: "day", description: "'today' (default), 'yesterday', or a date like 2026-07-01.", required: false),
            ]),
    ]

    func libraryOverview() -> String {
        MeetingChatFormat.libraryOverview(meetingsProvider(), limit: 12)
    }

    func run(_ call: ChatToolCall) async -> ChatToolResult {
        switch call.name {
        case "search_meetings": return await search(call)
        case "list_meetings": return list(call)
        case "get_meeting": return get(call)
        case "get_action_items": return actionItems(call)
        case "search_screen": return searchScreen(call)
        case "activity_summary": return activitySummary(call)
        case "search_files": return await searchFiles(call)
        default: return ChatToolResult(text: "Unknown tool '\(call.name)'.", summary: "unknown tool")
        }
    }

    // MARK: - Tools

    private func search(_ call: ChatToolCall) async -> ChatToolResult {
        guard let query = call.string("query") else {
            return ChatToolResult(text: "Provide a 'query' argument.", summary: "missing query")
        }
        let meetings = scopedMeetings(meetingsProvider(), call: call)
        let hasDayScope = call.string("_lokalbot_day_scope") != nil
        let allowedIDs: Set<UUID>? = hasDayScope || call.string("_lokalbot_meeting_ids") != nil
            ? Set(meetings.map(\.id)) : nil
        var keyword = searchIndex.search(query, limit: 8, meetingIDs: allowedIDs)
        if keyword.isEmpty {
            // A natural-language question ANDs every stop word against the index and
            // misses; retry on content keywords with OR semantics (ranked by FTS)
            // before reporting nothing.
            keyword = searchIndex.search(
                query, limit: 8, matchAll: false, dropStopWords: true,
                meetingIDs: allowedIDs)
        }
        var semantic: [EmbeddingIndex.Hit] = []
        if settingsProvider().semanticSearchEnabled, embeddingIndex.hasEmbeddings {
            // Drop semantic chunks already surfaced by keyword search.
            let seen = Set(keyword.map { "\($0.meetingID)-\(Int($0.start))" })
            semantic = await embeddingIndex.search(query, limit: 5, meetingIDs: allowedIDs)
                .filter {
                    !seen.contains("\($0.meetingID)-\(Int($0.start))")
                }
        }
        let text = MeetingChatFormat.searchResults(query: query, keyword: keyword,
                                                   semantic: semantic, meetings: meetings)
        let count = keyword.count + semantic.count
        var evidence = ChatEvidence()
        for hit in keyword.prefix(8) { evidence.addMeeting(hit.meetingID, seconds: hit.kind == .segment ? hit.start : nil) }
        for hit in semantic.prefix(5) { evidence.addMeeting(hit.meetingID, seconds: hit.start > 0 ? hit.start : nil) }
        return ChatToolResult(text: text,
                              summary: "“\(query)” — \(count) match\(count == 1 ? "" : "es")", evidence: evidence)
    }

    private func list(_ call: ChatToolCall) -> ChatToolResult {
        var meetings = scopedMeetings(meetingsProvider(), call: call)
        if let filter = call.string("query") {
            meetings = meetings.filter { $0.title.localizedCaseInsensitiveContains(filter) }
        }
        let limit = max(1, min(call.int("limit") ?? 15, 50))
        meetings = Array(meetings.prefix(limit))
        var evidence = ChatEvidence()
        for meeting in meetings { evidence.addMeeting(meeting.id) }
        return ChatToolResult(text: MeetingChatFormat.list(meetings),
                              summary: "\(meetings.count) meeting\(meetings.count == 1 ? "" : "s")", evidence: evidence)
    }

    private func get(_ call: ChatToolCall) -> ChatToolResult {
        let meetings = scopedMeetings(meetingsProvider(), call: call)
        let idArgument = call.string("id") ?? "latest"
        guard let meeting = resolve(idArgument, in: meetings) else {
            return ChatToolResult(
                text: "No meeting matches '\(idArgument)'. Use list_meetings to see ids.",
                summary: "no match for \(idArgument)")
        }
        let folder = meeting.folderURL(in: storage)
        let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        var transcript = try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        let include = call.string("include") ?? "summary"
        var evidence = ChatEvidence()
        evidence.addMeeting(meeting.id)
        var continuation: String?
        if include.lowercased().contains("all") || include.lowercased().contains("transcript"),
           let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
           let structured = try? JSONDecoder().decode(Transcript.self, from: data) {
            let start = call.string("from").flatMap(ChatCitationParser.seconds(from:)) ?? 0
            let observation = MeetingChatFormat.transcriptObservation(structured, from: start)
            transcript = observation.text.isEmpty && start > 0
                ? "No transcript lines at or after \(Transcript.stamp(start))."
                : observation.text
            continuation = observation.nextStart.map(MeetingChatFormat.transcriptContinuation(next:))
            for seconds in observation.seconds { evidence.addMeeting(meeting.id, seconds: seconds) }
        }
        let text = MeetingChatFormat.meeting(meeting, summary: summary,
                                             transcript: transcript, include: include,
                                             transcriptContinuation: continuation)
        return ChatToolResult(text: text, summary: meeting.title, evidence: evidence)
    }

    private func actionItems(_ call: ChatToolCall) -> ChatToolResult {
        guard let statusFilter = ActionStatusFilter(rawValue: call.string("status")?.lowercased() ?? "all") else {
            return ChatToolResult(
                text: "Choose status: all, active, open, deferred, or done.",
                summary: "invalid status filter")
        }
        let meetings = scopedMeetings(meetingsProvider(), call: call)
        var scoped: [Meeting]
        var scopeLabel: String
        if let idArgument = call.string("id") {
            guard let meeting = resolve(idArgument, in: meetings) else {
                return ChatToolResult(
                    text: "No meeting matches '\(idArgument)'. Use list_meetings to see ids.",
                    summary: "no match for \(idArgument)")
            }
            scoped = [meeting]
            scopeLabel = meeting.title
        } else {
            if call.string("_lokalbot_meeting_ids") != nil {
                scoped = meetings
                scopeLabel = "Selected meetings"
            } else if let dayArgument = call.string("_lokalbot_day_scope"),
               let scope = AskDateScope(storageKey: dayArgument) {
                scoped = meetings
                scopeLabel = scope.dateLabel
            } else {
                let days = max(1, min(call.int("days") ?? 7, 90))
                let current = now()
                let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: current) ?? current
                scoped = meetings.filter { $0.startedAt >= cutoff }
                scopeLabel = "last \(days) days"
            }
        }
        let projections = scoped.compactMap { meeting in
            MeetingOutcomeProjection.load(for: meeting, storage: storage)
        }
        let threads = ActionThreadClusterer.cluster(
            projections.flatMap(\.actionReferences))
            .filter(statusFilter.includes)
        let count = threads.count
        var evidence = ChatEvidence()
        for reference in threads.flatMap(\.references) { evidence.addMeeting(reference.meetingID) }
        for projection in projections {
            var nonActions = projection.outcomes
            nonActions.actionItems = []
            if !nonActions.isEmpty { evidence.addMeeting(projection.meeting.id) }
        }
        return ChatToolResult(text: MeetingChatFormat.threadedOutcomes(projections, statusFilter: statusFilter),
                              summary: "\(scopeLabel) — \(count) action item\(count == 1 ? "" : "s")", evidence: evidence)
    }

    private func searchFiles(_ call: ChatToolCall) async -> ChatToolResult {
        guard let files = filesProvider() else {
            return ChatToolResult(text: "Files is off, so no folders can be searched.", summary: "files off")
        }
        guard let query = call.string("query") else {
            return ChatToolResult(text: "Provide a 'query' argument.", summary: "missing query")
        }
        var interval: DateInterval?
        if let dayArgument = call.string("_lokalbot_day_scope") {
            guard let scoped = AskDateScope(storageKey: dayArgument)?.interval() else {
                return ChatToolResult(text: "Invalid date scope.", summary: "invalid date scope")
            }
            interval = scoped
        }
        let vector = settingsProvider().semanticSearchEnabled
            ? await embeddingIndex.queryVector(query, priority: .agent) : nil
        let hits = await files.search(query, queryVector: vector, interval: interval, limit: 8)
        var found: [(hit: FileSearchHit, passage: String?)] = []
        for hit in hits { found.append((hit, await files.passage(of: hit))) }
        return ChatToolResult(
            text: MeetingChatFormat.fileResults(query: query, hits: found),
            summary: "“\(query)” — \(hits.count) file\(hits.count == 1 ? "" : "s")",
            evidence: ChatEvidence(fileIDs: Set(hits.map(\.id))))
    }

    private func searchScreen(_ call: ChatToolCall) -> ChatToolResult {
        guard let query = call.string("query") else {
            return ChatToolResult(text: "Provide a 'query' argument.", summary: "missing query")
        }
        var filter: ScreenSearchFilter
        if let dayArgument = call.string("_lokalbot_day_scope") {
            guard let interval = AskDateScope(storageKey: dayArgument)?.interval() else {
                return ChatToolResult(text: "Invalid date scope.", summary: "invalid date scope")
            }
            filter = ScreenSearchFilter(interval: interval)
        } else {
            filter = .all
        }
        if let raw = call.string("_lokalbot_screen_ids") {
            filter.snapshotIDs = Set(raw.split(separator: ",").compactMap { Int64($0) })
        }
        var hits = activityStore.searchOCR(query, limit: 12, filter: filter)
        if hits.isEmpty {
            // Same rescue as meeting search: a natural-language question ANDs
            // stop words and misses; retry on OR'd content keywords.
            hits = activityStore.searchOCR(
                query, limit: 12, matchAll: false, dropStopWords: true,
                filter: filter)
        }
        return ChatToolResult(
            text: MeetingChatFormat.screenResults(query: query, hits: hits),
            summary: "“\(query)” — \(hits.count) screen match\(hits.count == 1 ? "" : "es")",
            evidence: ChatEvidence(screenIDs: Set(hits.prefix(12).map(\.snapshotID))))
    }

    /// An attached screen stays citable only while it still exists and falls
    /// inside the question's dates.
    func attachedScreenEvidence(ids: Set<Int64>, dayScopeKey: String?) -> ChatEvidence {
        let scope = dayScopeKey.flatMap { AskDateScope(storageKey: $0) }
        guard dayScopeKey == nil || scope != nil else { return ChatEvidence() }
        return ChatEvidence(screenIDs: ids.filter { id in
            activityStore.screenshot(id: id).map { scope?.contains($0.ts) ?? true } ?? false
        })
    }

    private func activitySummary(_ call: ChatToolCall) -> ChatToolResult {
        let argument = call.string("_lokalbot_day_scope") ?? call.string("day") ?? "today"
        let scope = AskDateScope(storageKey: argument)
            ?? (call.string("_lokalbot_day_scope") == nil ? Self.parseDay(argument, now: now()).map { AskDateScope(day: $0) } : nil)
        guard let scope, let interval = scope.interval() else {
            return ChatToolResult(text: "Could not understand day or date scope '\(argument)'.", summary: "bad day argument")
        }
        let blocks = activityStore.blocks(in: interval).map {
            ActivityBlock(id: $0.id, app: $0.app, title: $0.title,
                          start: max($0.start, interval.start), end: min($0.end, interval.end))
        }
        let includeMeetings = call.string("_lokalbot_include_meetings") != "false"
        let meetings = includeMeetings
            ? scopedMeetings(meetingsProvider(), call: call).filter { scope.contains($0.startedAt) } : []
        let label = scope.dateLabel
        var evidence = ChatEvidence()
        if !blocks.isEmpty {
            for meeting in meetings { evidence.addMeeting(meeting.id) }
        }
        return ChatToolResult(
            text: MeetingChatFormat.activitySummary(dayLabel: label, blocks: blocks,
                                                    meetings: meetings),
            summary: "\(label) — \(blocks.count) activity block\(blocks.count == 1 ? "" : "s")", evidence: evidence)
    }

    private func scopedMeetings(_ meetings: [Meeting], call: ChatToolCall) -> [Meeting] {
        var meetings = meetings
        if let raw = call.string("_lokalbot_meeting_ids") {
            let ids = Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            meetings = meetings.filter { ids.contains($0.id) }
        }
        guard let dayArgument = call.string("_lokalbot_day_scope") else { return meetings }
        guard let scope = AskDateScope(storageKey: dayArgument) else { return [] }
        return meetings.filter { scope.contains($0.startedAt) }
    }

    /// 'today' / 'yesterday' / ISO date (YYYY-MM-DD) → a Date inside that day.
    static func parseDay(_ argument: String, now: Date = Date()) -> Date? {
        switch argument.lowercased() {
        case "today", "": return now
        case "yesterday": return Calendar.current.date(byAdding: .day, value: -1, to: now)
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: argument)
        }
    }

    /// Resolve by short id / full uuid / 'latest' (via `SessionLookup`, pinned to
    /// the in-memory list we pass it so it never touches the hard-coded library
    /// path), then fall back to a title substring match.
    private func resolve(_ idArgument: String, in meetings: [Meeting]) -> Meeting? {
        if let found = (try? SessionLookup.find(id: idArgument, in: meetings)) ?? nil {
            return found
        }
        return meetings.first { $0.title.localizedCaseInsensitiveContains(idArgument) }
    }
}
