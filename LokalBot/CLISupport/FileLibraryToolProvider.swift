import Foundation

/// File-backed MCP provider. Read tools work while the app is closed;
/// `ask_library` delegates to an injected local-model engine.
struct FileLibraryToolProvider: LibraryToolProvider {
    var gate: AgentAccessGate
    var screenGate: ScreenMemoryAccessGate
    var personalGate: PersonalContextAccessGate
    var screenReader: any ScreenMemoryReading
    var now: () -> Date
    var ask: (String) async -> ToolResult

    init(
        gate: AgentAccessGate,
        screenGate: ScreenMemoryAccessGate? = nil,
        personalGate: PersonalContextAccessGate? = nil,
        screenReader: (any ScreenMemoryReading)? = nil,
        now: @escaping () -> Date = Date.init,
        ask: @escaping (String) async -> ToolResult
    ) {
        self.gate = gate
        self.screenGate = screenGate ?? ScreenMemoryAccessGate(root: gate.root)
        self.personalGate = personalGate ?? PersonalContextAccessGate(root: gate.root)
        self.screenReader = screenReader ?? SQLiteScreenMemoryReader(
            databaseURL: gate.root.appendingPathComponent("lokalbotv3.sqlite"))
        self.now = now
        self.ask = ask
    }

    static let accessDisabledMessage =
        "External agent access is off. Enable it in LokalBot → Settings → Privacy → " +
        "\"Allow external agents to read your meeting library\"."

    static let screenAccessDisabledMessage =
        "External screen-memory access is off. Enable it separately in LokalBot → " +
        "Settings → Privacy → \"Allow external agents to read screen memory\"."

    var tools: [ToolDefinition] {
        [
            Briefing.definition,
            ToolDefinition(
                name: "list_meetings",
                description: "List recorded meetings, newest first. Returns id, title, date, and duration for each; "
                    + "include \"summary\" adds each meeting's summary, so one call covers several meetings.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": [
                            "type": "integer",
                            "description": .string("Maximum meetings to return (default 20; with summaries default "
                                + "\(SessionFormatter.defaultSummaryListCount), at most "
                                + "\(SessionFormatter.maximumSummaryListCount))."),
                        ],
                        "include": [
                            "type": "string",
                            "description": .string("\"summary\" adds each meeting's summary. The summaries share "
                                + "\(SessionFormatter.listSummaryBudget) characters; a cut one has "
                                + "summary_truncated, and get_meeting reads it whole."),
                        ],
                        "since": [
                            "type": "string",
                            "description": "Only meetings on or after this local calendar day (YYYY-MM-DD).",
                        ],
                        "query": [
                            "type": "string",
                            "description": "Case-insensitive title substring filter.",
                        ],
                    ],
                ]),
            ToolDefinition(
                name: "get_meeting",
                description: "Fetch one meeting as markdown. Sections: metadata, summary, transcript. "
                    + "A long transcript comes in windows of max_characters; a cut window ends with the "
                    + "transcript_from value that continues it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "Short id from list_meetings, full UUID, or \"latest\".",
                        ],
                        "include": [
                            "type": "string",
                            "description": "Comma-separated subset of metadata,summary,transcript. Default: all three.",
                        ],
                        "transcript_from": [
                            "type": "string",
                            "description": "Optional HH:MM:SS; the transcript starts at the first line at or after it.",
                        ],
                        "max_characters": [
                            "type": "integer",
                            "description": "Transcript characters per call (default 40,000, maximum 200,000).",
                        ],
                    ],
                    "required": ["id"],
                ]),
            ToolDefinition(
                name: "search_meetings",
                description: "Word search across meeting titles, summaries, and transcripts. Meetings with every query word "
                    + "(any order, case- and accent-insensitive) come first, then partial matches; rare words weigh more, "
                    + "exact-phrase hits lead, and ties keep recency. Words of up to three letters or digits match "
                    + "only whole words. Wrap the query in double quotes for an exact phrase. "
                    + "Hits carry kind, snippet, and timestamp; one meeting gives at most five transcript hits.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Text to search for."],
                        "limit": ["type": "integer", "description": "Maximum hits (default 50)."],
                    ],
                    "required": ["query"],
                ]),
            ToolDefinition(
                name: "ask_library",
                description: "Ask a question and get an answer synthesized by LokalBot's local model from the meeting library, with meeting citations — raw transcripts never leave the Mac. Needs the LokalBot app running; the first call may take up to a minute while the model loads.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "question": [
                            "type": "string",
                            "description": "The question to answer from the user's meetings.",
                        ],
                    ],
                    "required": ["question"],
                ]),
            ToolDefinition(
                name: "get_action_items",
                description: "List action items extracted from recent meetings, with the user's saved corrections and status applied. Overdue and soon-due work comes first. Due phrases are resolved to a date only when unambiguous (due_date); otherwise only the spoken phrase is returned.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "status": [
                            "type": "string",
                            "description": "active (default: open or deferred), open, deferred, done, or all.",
                        ],
                        "owner": [
                            "type": "string",
                            "description": "\"me\" for the user's own commitments, \"others\", or a participant name substring. Default: anyone.",
                        ],
                        "days": [
                            "type": "integer",
                            "description": "Meetings from the last N days (default 30, maximum 365). Ignored with meeting_id.",
                        ],
                        "meeting_id": [
                            "type": "string",
                            "description": "Optional short id or full UUID to limit results to one meeting.",
                        ],
                        "limit": ["type": "integer", "description": "Maximum action threads (default 50, maximum 200)."],
                    ],
                ]),
            ToolDefinition(
                name: "list_people",
                description: "List people the user meets, joined from calendar attendee names, speaker names applied in LokalBot, and action owners. Returns names, meeting counts, last meeting, and open-action counts in each direction. Email addresses are never returned.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Optional name substring."],
                        "limit": ["type": "integer", "description": "Maximum people (default 50, maximum 200)."],
                    ],
                ]),
            ToolDefinition(
                name: "get_person",
                description: "One person's open commitments in both directions (what the user owes them and what they owe the user), recent decisions made in small meetings together, and shared meetings.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "person": ["type": "string", "description": "Person id from list_people, or a name."],
                    ],
                    "required": ["person"],
                ]),
            ToolDefinition(
                name: "search_screen",
                description: "Search locally captured screen text and window titles. Returns text snippets and context metadata only; never pixels or encrypted file paths. "
                    + "Repeated captures of the same window and text count once. Requires the separate screen-memory permission.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Text to search for."],
                        "day": ["type": "string", "description": "Optional local calendar day (YYYY-MM-DD)."],
                        "app": ["type": "string", "description": "Optional app-name substring."],
                        "limit": ["type": "integer", "description": "Maximum hits (default 40, maximum 200)."],
                    ],
                    "required": ["query"],
                ]),
            ToolDefinition(
                name: "get_timeline",
                description: "Get activity blocks and screen-context metadata for one local calendar day, oldest first. No pixels or encrypted file paths are returned. "
                    + "A list cut at the limit sets activity_truncated or screenshots_truncated; call again with after set to its last ended_at or captured_at to continue. "
                    + "Requires the separate screen-memory permission.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "day": ["type": "string", "description": "Local calendar day (YYYY-MM-DD); defaults to today."],
                        "after": ["type": "string", "description": "Optional ISO 8601 time; return only what follows it within the day."],
                        "limit": ["type": "integer", "description": "Maximum activity blocks and screenshots (default 200, maximum 500)."],
                    ],
                ]),
            ToolDefinition(
                name: "get_recent_activity",
                description: "Get recent app/window activity blocks, newest first. Requires the separate screen-memory permission.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "minutes": ["type": "integer", "description": "Lookback window in minutes (default 120, maximum 10080)."],
                        "limit": ["type": "integer", "description": "Maximum blocks (default 50, maximum 200)."],
                    ],
                ]),
            ToolDefinition(
                name: "get_app_usage",
                description: "Aggregate tracked time by app for one local calendar day. Requires the separate screen-memory permission.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "day": ["type": "string", "description": "Local calendar day (YYYY-MM-DD); defaults to today."],
                        "limit": ["type": "integer", "description": "Maximum apps (default 30, maximum 100)."],
                    ],
                ]),
            ToolDefinition(
                name: "get_screenshot_detail",
                description: "Get captured text and metadata for one context-moment id. It reports whether encrypted pixels exist but never returns decrypted pixels or a file path. Requires the separate screen-memory permission.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "snapshot_id": ["type": "integer", "description": "Screenshot id returned by search_screen or get_timeline."],
                    ],
                    "required": ["snapshot_id"],
                ]),
            PersonalContextTool.definition,
        ]
    }

    func call(name: String, arguments: JSONValue?) async -> ToolResult {
        if Self.meetingToolNames.contains(name), !gate.isAuthorized() {
            return .error(.accessDisabled, Self.accessDisabledMessage)
        }
        if Self.screenToolNames.contains(name), !screenGate.isAuthorized() {
            return .error(.screenAccessDisabled, Self.screenAccessDisabledMessage)
        }

        switch name {
        case "list_meetings":
            return listMeetings(arguments)
        case "get_meeting":
            return getMeeting(arguments)
        case "search_meetings":
            return searchMeetings(arguments)
        case "ask_library":
            guard let question = arguments?["question"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !question.isEmpty else {
                return .error(
                    .invalidArguments,
                    "ask_library requires a non-empty \"question\" string.")
            }
            return await ask(question)
        case "get_action_items":
            return getActionItems(arguments)
        case "list_people":
            return listPeople(arguments)
        case "get_person":
            return getPerson(arguments)
        case "search_screen":
            return searchScreen(arguments)
        case "get_timeline":
            return getTimeline(arguments)
        case "get_recent_activity":
            return getRecentActivity(arguments)
        case "get_app_usage":
            return getAppUsage(arguments)
        case "get_screenshot_detail":
            return getScreenshotDetail(arguments)
        case PersonalContextTool.name:
            return getPersonalContext(arguments)
        case Briefing.toolName:
            return .text(briefing())
        default:
            return .error(
                .unknownTool,
                "No tool named \"\(name)\". Available: \(tools.map(\.name).joined(separator: ", ")).")
        }
    }

    private static let meetingToolNames: Set<String> = [
        "list_meetings", "get_meeting", "search_meetings", "ask_library", "get_action_items",
        "list_people", "get_person",
    ]
    private static let screenToolNames: Set<String> = [
        "search_screen", "get_timeline", "get_recent_activity", "get_app_usage",
        "get_screenshot_detail",
    ]

    /// Never refused: with no grants it still says which permissions are off,
    /// so an agent learns what it could ask for. Each section checks its own
    /// grant inside `Briefing`. `lokalbot-cli brief` asks for `.cli` names.
    func briefing(vocabulary: Briefing.Vocabulary = .mcp) -> String {
        Briefing.render(Briefing.Context(
            root: gate.root,
            meetingAccess: gate.isAuthorized(),
            screenGate: screenGate,
            personalGate: personalGate,
            screenReader: screenReader,
            now: now(),
            vocabulary: vocabulary))
    }

    /// Independent of meeting and screen access, and of Agent Mode
    /// capabilities: only the Personal context marker and its projection.
    private func getPersonalContext(_ arguments: JSONValue?) -> ToolResult {
        guard personalGate.isEnabled else {
            return .error(.personalContextDisabled, PersonalContextTool.disabledMessage)
        }
        guard let task = arguments?["task"]?.stringValue else {
            return .error(.invalidArguments, "\(PersonalContextTool.name) requires a \"task\" string.")
        }
        var kinds: [String]?
        if let raw = arguments?["kinds"] {
            guard case .array(let values) = raw else {
                return .error(.invalidArguments, "\"kinds\" must be an array of strings.")
            }
            var parsed: [String] = []
            for value in values {
                guard let kind = value.stringValue else {
                    return .error(.invalidArguments, "\"kinds\" must be an array of strings.")
                }
                parsed.append(kind)
            }
            kinds = parsed
        }
        var maxItems: Int?
        if let raw = arguments?["max_items"] {
            guard let value = raw.intValue else {
                return .error(.invalidArguments,
                              "\"max_items\" must be an integer between 1 and \(PersonalContextTool.maximumItems).")
            }
            maxItems = value
        }
        switch PersonalContextTool.report(task: task, kinds: kinds, maxItems: maxItems, gate: personalGate) {
        case .success(let report):
            return .text(PersonalContextTool.json(report))
        case .failure(.disabled):
            return .error(.personalContextDisabled, PersonalContextTool.disabledMessage)
        case .failure(.unavailable):
            return .error(.personalContextUnavailable, PersonalContextTool.unavailableMessage)
        case .failure(.invalid(let message)):
            return .error(.invalidArguments, message)
        }
    }

    private func listMeetings(_ arguments: JSONValue?) -> ToolResult {
        let includeSummary: Bool
        do {
            includeSummary = try SessionFormatter.listIncludesSummary(arguments?["include"]?.stringValue ?? "")
        } catch SessionFormatter.ListIncludeError.unknown(let values) {
            return .error(.invalidArguments,
                          "Unknown include value(s): \(values.joined(separator: ", ")). "
                              + "list_meetings takes \"summary\".")
        } catch {
            return .error(.invalidArguments,
                          "list_meetings doesn't include transcripts. Read one meeting's with get_meeting.")
        }
        do {
            var meetings = try SessionLookup.loadAllMeetings()
            if let query = arguments?["query"]?.stringValue, !query.isEmpty {
                let needle = query.lowercased()
                meetings = meetings.filter { $0.title.lowercased().contains(needle) }
            }
            if let since = arguments?["since"]?.stringValue {
                guard let day = LibraryInputPolicy.localDay(since) else {
                    return .error(
                        .invalidArguments,
                        "\"since\" must be a real local calendar day formatted YYYY-MM-DD, got \"\(since)\".")
                }
                meetings = meetings.filter { $0.startedAt >= day }
            }
            let limit: Int
            switch includeSummary
                ? boundedLimit(arguments?["limit"], default: SessionFormatter.defaultSummaryListCount,
                               maximum: SessionFormatter.maximumSummaryListCount)
                : boundedLimit(arguments?["limit"], default: 20,
                               maximum: LibraryInputPolicy.maximumMeetingCount) {
            case .success(let value): limit = value
            case .failure(let result): return result
            }
            return .text(SessionFormatter.listJSON(Array(meetings.prefix(limit)), includeSummary: includeSummary))
        } catch {
            return .error(
                .meetingNotFound,
                "Could not read the meeting library: \(error.localizedDescription)")
        }
    }

    private func getMeeting(_ arguments: JSONValue?) -> ToolResult {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty,
              id.count <= 64 else {
            return .error(
                .invalidArguments,
                "get_meeting requires an \"id\" string (short id, full UUID, or \"latest\").")
        }
        var options = parseInclude(arguments?["include"]?.stringValue)
        switch boundedInteger(arguments?["max_characters"], name: "max_characters", default: 40_000, maximum: 200_000) {
        case .success(let value): options.transcriptCharacters = value
        case .failure(let result): return result
        }
        if let raw = arguments?["transcript_from"] {
            guard let text = raw.stringValue, let seconds = SessionFormatter.seconds(fromStamp: text) else {
                return .error(.invalidArguments, "\"transcript_from\" must be a time such as 00:42:10.")
            }
            options.transcriptFrom = seconds
        }

        do {
            let meetings = try SessionLookup.loadAllMeetings()
            let needle = id.lowercased()
            if needle != "latest", UUID(uuidString: needle) == nil {
                let matches = meetings.filter {
                    SessionLookup.shortID($0.id).hasPrefix(needle)
                }
                if matches.count > 1 {
                    let ids = matches.map { SessionLookup.shortID($0.id) }
                        .joined(separator: ", ")
                    return .error(
                        .ambiguousID,
                        "\"\(id)\" matches several meetings (\(ids)). Use a longer id.")
                }
            }
            guard let meeting = try SessionLookup.find(id: id, in: meetings) else {
                return .error(
                    .meetingNotFound,
                    "No meeting matches \"\(id)\". Use list_meetings or search_meetings to find ids.")
            }
            return .text(SessionFormatter.getMarkdown(meeting, options: options))
        } catch {
            return .error(
                .meetingNotFound,
                "Could not read the meeting library: \(error.localizedDescription)")
        }
    }

    private func parseInclude(_ include: String?) -> SessionFormatter.GetOptions {
        guard let include, !include.isEmpty else { return .all }
        let parts = Set(include.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) })
        return .init(
            includeSummary: parts.contains("summary"),
            includeTranscript: parts.contains("transcript"),
            includeMetadata: parts.contains("metadata"))
    }

    private func searchMeetings(_ arguments: JSONValue?) -> ToolResult {
        guard let query = arguments?["query"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty,
              query.count <= LibraryInputPolicy.maximumQueryCharacters else {
            return .error(
                .invalidArguments,
                "search_meetings requires a non-empty \"query\" string of at most \(LibraryInputPolicy.maximumQueryCharacters) characters.")
        }
        do {
            let limit: Int
            switch boundedLimit(arguments?["limit"], default: LibrarySearch.defaultLimit,
                                maximum: LibraryInputPolicy.maximumSearchHits) {
            case .success(let value): limit = value
            case .failure(let result): return result
            }
            return .text(SessionFormatter.searchJSON(
                try LibrarySearch.hits(query: query, limit: limit)))
        } catch {
            return .error(
                .meetingNotFound,
                "Could not read the meeting library: \(error.localizedDescription)")
        }
    }

    private func getActionItems(_ arguments: JSONValue?) -> ToolResult {
        var filter = ActionItemsReport.Filter()
        if let raw = arguments?["status"]?.stringValue {
            guard let status = ActionStatusFilter(rawValue: raw.lowercased()) else {
                return .error(
                    .invalidArguments,
                    "\"status\" must be one of all, active, open, deferred, or done.")
            }
            filter.status = status
        }
        if let owner = arguments?["owner"]?.stringValue {
            guard owner.count <= 120 else {
                return .error(.invalidArguments, "\"owner\" must be at most 120 characters.")
            }
            filter.owner = ActionItemsReport.OwnerFilter(owner)
        }
        switch boundedInteger(arguments?["days"], name: "days",
                              default: ActionItemsReport.defaultDays,
                              maximum: ActionItemsReport.maximumDays) {
        case .success(let value): filter.days = value
        case .failure(let result): return result
        }
        switch boundedInteger(arguments?["limit"], name: "limit", default: 50,
                              maximum: ActionItemsReport.maximumEntries) {
        case .success(let value): filter.limit = value
        case .failure(let result): return result
        }
        do {
            let meetings = try SessionLookup.loadAllMeetings()
            if let id = arguments?["meeting_id"]?.stringValue, !id.isEmpty {
                guard id.count <= 64, let meeting = try SessionLookup.find(id: id, in: meetings) else {
                    return .error(
                        .meetingNotFound,
                        "No meeting matches \"\(id)\". Use list_meetings or search_meetings to find ids.")
                }
                filter.meetingID = meeting.id
            }
            return .text(ActionItemsReport.json(ActionItemsReport.entries(
                meetings: meetings, root: SessionLookup.storageRootURL, filter: filter, now: now())))
        } catch {
            return .error(
                .meetingNotFound,
                "Could not read the meeting library: \(error.localizedDescription)")
        }
    }

    private func listPeople(_ arguments: JSONValue?) -> ToolResult {
        let query = arguments?["query"]?.stringValue
        if let query, query.count > 120 {
            return .error(.invalidArguments, "\"query\" must be at most 120 characters.")
        }
        let limit: Int
        switch boundedInteger(arguments?["limit"], name: "limit", default: 50,
                              maximum: PeopleReport.maximumEntries) {
        case .success(let value): limit = value
        case .failure(let result): return result
        }
        do {
            let people = PeopleReport.people(
                meetings: try SessionLookup.loadAllMeetings(), root: SessionLookup.storageRootURL, now: now())
            return .text(PeopleReport.json(PeopleReport.summaries(people, query: query, limit: limit)))
        } catch {
            return .error(.meetingNotFound, "Could not read the meeting library: \(error.localizedDescription)")
        }
    }

    private func getPerson(_ arguments: JSONValue?) -> ToolResult {
        guard let needle = arguments?["person"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !needle.isEmpty, needle.count <= 120 else {
            return .error(.invalidArguments, "get_person requires a \"person\" id or name of at most 120 characters.")
        }
        do {
            let people = PeopleReport.people(
                meetings: try SessionLookup.loadAllMeetings(), root: SessionLookup.storageRootURL, now: now())
            guard let person = PeopleReport.find(needle, in: people) else {
                return .error(.meetingNotFound,
                              "No single person matches \"\(needle)\". Use list_people to find ids.")
            }
            return .text(PeopleReport.json(PeopleReport.detail(person, now: now())))
        } catch {
            return .error(.meetingNotFound, "Could not read the meeting library: \(error.localizedDescription)")
        }
    }

    // MARK: - Screen memory (separately authorized)

    private func searchScreen(_ arguments: JSONValue?) -> ToolResult {
        guard let query = arguments?["query"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty,
              query.count <= LibraryInputPolicy.maximumQueryCharacters else {
            return .error(
                .invalidArguments,
                "search_screen requires a non-empty \"query\" string of at most \(LibraryInputPolicy.maximumQueryCharacters) characters.")
        }
        let limit: Int
        switch boundedInteger(arguments?["limit"], name: "limit", default: 40, maximum: 200) {
        case .success(let value): limit = value
        case .failure(let result): return result
        }
        let interval: DateInterval?
        if arguments?["day"] != nil {
            switch localDayInterval(arguments?["day"], name: "day") {
            case .success(let value): interval = value
            case .failure(let result): return result
            }
        } else {
            interval = nil
        }
        let app = arguments?["app"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let app, app.count > 200 {
            return .error(.invalidArguments, "\"app\" must be at most 200 characters.")
        }
        do {
            let scoped = scopedInterval(interval)
            if interval != nil, scoped == nil {
                return .text(encodeScreenMemory([ScreenMemorySearchHit]()))
            }
            let cutoff = screenAccessCutoff
            // A window captured every few seconds repeats one snippet many
            // times; read further and keep the most relevant copy of each.
            var seen = Set<String>()
            let hits = try screenReader.search(ScreenMemorySearchRequest(
                query: query,
                start: scoped?.start ?? cutoff,
                end: scoped?.end,
                app: app,
                limit: limit * 4))
                .filter { seen.insert("\($0.app)|\($0.windowTitle)|\($0.snippet)").inserted }
                .prefix(limit)
            // Enforce the profile again on returned rows. The SQLite reader
            // already applies the bound, but this keeps the authorization
            // boundary intact for alternate readers and future refactors.
            let authorizedHits = cutoff.map { boundary in
                hits.filter { $0.capturedAt >= boundary }
            } ?? Array(hits)
            return .text(encodeScreenMemory(authorizedHits))
        } catch {
            return screenMemoryFailure(error)
        }
    }

    private func getTimeline(_ arguments: JSONValue?) -> ToolResult {
        let interval: DateInterval
        switch localDayInterval(arguments?["day"], name: "day") {
        case .success(let value): interval = value
        case .failure(let result): return result
        }
        let limit: Int
        switch boundedInteger(arguments?["limit"], name: "limit", default: 200, maximum: 500) {
        case .success(let value): limit = value
        case .failure(let result): return result
        }
        var after: Date?
        if let raw = arguments?["after"] {
            guard let text = raw.stringValue, let value = ISO8601DateFormatter().date(from: text) else {
                return .error(.invalidArguments, "\"after\" must be an ISO 8601 time such as 2026-05-27T14:30:00Z.")
            }
            after = value
        }
        do {
            guard let scoped = scopedInterval(interval), scoped.end > (after ?? scoped.start) else {
                return .text(encodeScreenMemory(ScreenMemoryTimeline(
                    start: interval.start, end: interval.end,
                    activity: [], screenshots: [])))
            }
            return .text(encodeScreenMemory(try screenReader.timeline(
                from: max(scoped.start, after ?? scoped.start), to: scoped.end, limit: limit)))
        } catch {
            return screenMemoryFailure(error)
        }
    }

    private func getRecentActivity(_ arguments: JSONValue?) -> ToolResult {
        let minutes: Int
        switch boundedInteger(
            arguments?["minutes"], name: "minutes", default: 120, maximum: 10_080
        ) {
        case .success(let value): minutes = value
        case .failure(let result): return result
        }
        let limit: Int
        switch boundedInteger(arguments?["limit"], name: "limit", default: 50, maximum: 200) {
        case .success(let value): limit = value
        case .failure(let result): return result
        }
        do {
            let requested = now().addingTimeInterval(-TimeInterval(minutes * 60))
            let start = max(requested, screenAccessCutoff ?? requested)
            return .text(encodeScreenMemory(
                try screenReader.recentActivity(since: start, limit: limit)))
        } catch {
            return screenMemoryFailure(error)
        }
    }

    private func getAppUsage(_ arguments: JSONValue?) -> ToolResult {
        let interval: DateInterval
        switch localDayInterval(arguments?["day"], name: "day") {
        case .success(let value): interval = value
        case .failure(let result): return result
        }
        let limit: Int
        switch boundedInteger(arguments?["limit"], name: "limit", default: 30, maximum: 100) {
        case .success(let value): limit = value
        case .failure(let result): return result
        }
        do {
            guard let scoped = scopedInterval(interval) else {
                return .text(encodeScreenMemory([ScreenMemoryAppUsage]()))
            }
            return .text(encodeScreenMemory(try screenReader.appUsage(
                from: scoped.start, to: scoped.end, limit: limit)))
        } catch {
            return screenMemoryFailure(error)
        }
    }

    private func getScreenshotDetail(_ arguments: JSONValue?) -> ToolResult {
        guard let id = arguments?["snapshot_id"]?.intValue, id > 0 else {
            return .error(
                .invalidArguments,
                "get_screenshot_detail requires a positive integer \"snapshot_id\".")
        }
        do {
            guard let detail = try screenReader.screenshotDetail(snapshotID: Int64(id)) else {
                return .error(
                    .screenshotNotFound,
                    "No screen-context metadata matches id \(id). Use search_screen or get_timeline to find ids.")
            }
            if let cutoff = screenAccessCutoff, detail.capturedAt < cutoff {
                return .error(
                    .screenshotNotFound,
                    "No screen-context metadata matches id \(id) inside the granted screen-memory scope.")
            }
            return .text(encodeScreenMemory(detail))
        } catch {
            return screenMemoryFailure(error)
        }
    }

    private func screenMemoryFailure(_ error: Error) -> ToolResult {
        .error(
            .screenMemoryUnavailable,
            "Could not read local screen memory: \(error.localizedDescription)")
    }

    private func encodeScreenMemory<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private var screenAccessCutoff: Date? {
        switch screenGate.profile.scope {
        case .today:
            Calendar.current.startOfDay(for: now())
        case .recentWeek:
            now().addingTimeInterval(-7 * 86_400)
        case .retainedHistory:
            nil
        }
    }

    /// Nil means the requested interval sits wholly outside the granted scope.
    /// A nil input represents an open-ended search and remains nil when access is
    /// unbounded; callers pair it with `screenAccessCutoff` for bounded profiles.
    private func scopedInterval(_ requested: DateInterval?) -> DateInterval? {
        guard let requested else { return nil }
        guard let cutoff = screenAccessCutoff else { return requested }
        let start = max(requested.start, cutoff)
        guard requested.end > start else { return nil }
        return DateInterval(start: start, end: requested.end)
    }

    private enum DayIntervalResult {
        case success(DateInterval)
        case failure(ToolResult)
    }

    private func localDayInterval(_ raw: JSONValue?, name: String) -> DayIntervalResult {
        let calendar = Calendar.current
        let day: Date
        if let raw {
            guard let value = raw.stringValue,
                  let parsed = LibraryInputPolicy.localDay(value, calendar: calendar) else {
                return .failure(.error(
                    .invalidArguments,
                    "\"\(name)\" must be a real local calendar day formatted YYYY-MM-DD."))
            }
            day = parsed
        } else {
            day = now()
        }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return .success(DateInterval(start: start, end: end))
    }

    private enum LimitResult {
        case success(Int)
        case failure(ToolResult)
    }

    private func boundedLimit(_ raw: JSONValue?, default defaultValue: Int,
                              maximum: Int) -> LimitResult {
        boundedInteger(raw, name: "limit", default: defaultValue, maximum: maximum)
    }

    private func boundedInteger(_ raw: JSONValue?, name: String, default defaultValue: Int,
                                maximum: Int) -> LimitResult {
        guard let raw else { return .success(defaultValue) }
        guard let value = raw.intValue, (1...maximum).contains(value) else {
            return .failure(.error(
                .invalidArguments,
                "\"\(name)\" must be an integer between 1 and \(maximum)."))
        }
        return .success(value)
    }
}
