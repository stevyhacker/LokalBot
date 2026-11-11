import Foundation
import SQLite3

/// One saved coding-agent note as a search returns it.
struct AgentNoteHit: Identifiable, Hashable, Sendable {
    /// Stable id of the note, cited as `[note:id]`.
    var id: String
    /// `claude-code` or `codex`.
    var agent: String
    var title: String
    var summary: String?
    /// Claude Code's own label: user, feedback, project, or reference.
    var category: String?
    var workingDirectory: String?
    /// The agent's file the note was read from.
    var path: String
    var modified: Date
    /// A passage around the match, the matched words between « and ».
    var snippet: String

    var agentName: String { AgentNotesIndex.agentName(agent) }

    var projectName: String? {
        guard let workingDirectory else { return nil }
        let name = (workingDirectory as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// "Claude Code · LokalBot", for a row's second line.
    var sourceLabel: String {
        [agentName, projectName].compactMap { $0 }.joined(separator: " · ")
    }
}

enum AgentNotesIndexError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): "Agent notes are unavailable: \(message)"
        }
    }
}

/// Read side of the saved coding-agent notes: `agent-notes.sqlite` in the
/// library, written only by the app (`AgentMemoryStore`). Every call opens
/// the file read-only and closes it, so the CLI and the app can both search
/// while the app replaces notes.
struct AgentNotesIndex: Sendable {
    static let fileName = "agent-notes.sqlite"
    /// Column weights for title, summary and text.
    static let rank = "bm25(notes_fts, 10.0, 4.0, 1.0)"
    static let snippet = "snippet(notes_fts, 2, '«', '»', '…', 18)"

    var databaseURL: URL

    init(root: URL = SessionLookup.storageRootURL) {
        databaseURL = root.appendingPathComponent(Self.fileName)
    }

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    var exists: Bool { FileManager.default.fileExists(atPath: databaseURL.path) }

    static func agentName(_ agent: String) -> String {
        switch agent {
        case "claude-code": "Claude Code"
        case "codex": "Codex"
        default: agent
        }
    }

    /// Notes matching every word of `query`, best first; when none has every
    /// word, notes matching any. The last word also matches as a prefix, so
    /// results appear while it is typed.
    func search(_ query: String, agent: String? = nil, limit: Int) throws -> [AgentNoteHit] {
        guard limit > 0, exists else { return [] }
        // FTS5 cannot see words inside a run of CJK text; see `CJKSearch`.
        if CJKSearch.containsCJK(query) {
            return try substringSearch(query, agent: agent, limit: limit)
        }
        let terms = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let quoted = terms.enumerated().map { index, term -> String in
            let phrase = "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
            return index == terms.count - 1 && term.count >= 3 ? phrase + "*" : phrase
        }
        let every = try ftsSearch(match: quoted.joined(separator: " AND "), agent: agent, limit: limit)
        guard every.isEmpty, quoted.count > 1 else { return every }
        return try ftsSearch(match: quoted.joined(separator: " OR "), agent: agent, limit: limit)
    }

    /// The note with this id, its snippet the opening of its text.
    func hit(id: String) throws -> AgentNoteHit? {
        guard exists else { return nil }
        return try connection().query(
            "SELECT \(Self.columns), substr(n.text, 1, 240) FROM notes n WHERE n.id = ?1 LIMIT 1",
            bindings: [.text(id)], row: Self.hit).first
    }

    func text(of id: String) throws -> String? {
        guard exists else { return nil }
        return try connection().query("SELECT text FROM notes WHERE id = ?1 LIMIT 1", bindings: [.text(id)]) {
            Self.text($0, 0)
        }.first
    }

    /// How many notes are saved per agent.
    func counts() throws -> [String: Int] {
        guard exists else { return [:] }
        let rows = try connection().query("SELECT agent, COUNT(*) FROM notes GROUP BY agent") {
            (Self.text($0, 0), Int(sqlite3_column_int64($0, 1)))
        }
        return Dictionary(rows, uniquingKeysWith: +)
    }

    private static let columns =
        "n.id, n.agent, n.title, n.summary, n.category, n.working_directory, n.path, n.modified"

    private func ftsSearch(match: String, agent: String?, limit: Int) throws -> [AgentNoteHit] {
        var sql = """
            SELECT \(Self.columns), \(Self.snippet)
            FROM notes_fts JOIN notes n ON n.rowid = notes_fts.rowid
            WHERE notes_fts MATCH ?1
            """
        var bindings: [SQLiteValue] = [.text(match)]
        if let agent {
            bindings.append(.text(agent))
            sql += " AND n.agent = ?\(bindings.count)"
        }
        bindings.append(.int64(Int64(limit)))
        sql += " ORDER BY \(Self.rank), n.modified DESC LIMIT ?\(bindings.count)"
        return try connection().query(sql, bindings: bindings, row: Self.hit)
    }

    private func substringSearch(_ query: String, agent: String?, limit: Int) throws -> [AgentNoteHit] {
        let terms = CJKSearch.terms(from: query)
        guard !terms.isEmpty else { return [] }
        var bindings: [SQLiteValue] = []
        let conditions = terms.map { term -> String in
            bindings.append(.text(CJKSearch.likePattern(for: term)))
            let pattern = "?\(bindings.count)"
            return "(n.text LIKE \(pattern) \(CJKSearch.likeEscapeClause)"
                + " OR n.title LIKE \(pattern) \(CJKSearch.likeEscapeClause))"
        }
        var sql = "SELECT \(Self.columns), n.text FROM notes n WHERE " + conditions.joined(separator: " AND ")
        if let agent {
            bindings.append(.text(agent))
            sql += " AND n.agent = ?\(bindings.count)"
        }
        bindings.append(.int64(Int64(limit)))
        sql += " ORDER BY n.modified DESC LIMIT ?\(bindings.count)"
        return try connection().query(sql, bindings: bindings) { row in
            var hit = Self.hit(row)
            hit.snippet = CJKSearch.snippet(in: hit.snippet, terms: terms) ?? String(hit.snippet.prefix(72))
            return hit
        }
    }

    private static func hit(_ row: OpaquePointer) -> AgentNoteHit {
        AgentNoteHit(
            id: text(row, 0), agent: text(row, 1), title: text(row, 2),
            summary: optionalText(row, 3), category: optionalText(row, 4),
            workingDirectory: optionalText(row, 5), path: text(row, 6),
            modified: Date(timeIntervalSince1970: sqlite3_column_double(row, 7)),
            snippet: text(row, 8))
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        let value = text(statement, column)
        return value.isEmpty ? nil : value
    }

    private func connection() throws -> Connection { try Connection(url: databaseURL) }

    private enum SQLiteValue {
        case int64(Int64)
        case text(String)
    }

    /// Query-only, so nothing here can grow a write path to the notes.
    private final class Connection {
        private let handle: OpaquePointer
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        init(url: URL) throws {
            var opened: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK, let opened else {
                let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                    ?? String(cString: sqlite3_errstr(result))
                if let opened { sqlite3_close(opened) }
                throw AgentNotesIndexError.unavailable(message)
            }
            handle = opened
            sqlite3_busy_timeout(handle, 5_000)
        }

        deinit { sqlite3_close(handle) }

        func query<T>(_ sql: String, bindings: [SQLiteValue] = [], row: (OpaquePointer) -> T) throws -> [T] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw AgentNotesIndexError.unavailable(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(statement) }
            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case .int64(let integer): sqlite3_bind_int64(statement, index, integer)
                case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
                }
            }
            var rows: [T] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: rows.append(row(statement))
                case SQLITE_DONE: return rows
                default: throw AgentNotesIndexError.unavailable(String(cString: sqlite3_errmsg(handle)))
                }
            }
        }
    }
}

/// Cross-process truth for the Agent notes grant: a marker the app sets from
/// Settings → External Agents. Separate from every other grant, and no Agent
/// Mode capability satisfies it.
struct AgentNotesAccessGate {
    static let markerName = "agent-notes-access-enabled"

    var root: URL

    init(root: URL = SessionLookup.storageRootURL) {
        self.root = root
    }

    var controlDirectory: URL { root.appendingPathComponent("control", isDirectory: true) }
    var accessMarkerURL: URL { controlDirectory.appendingPathComponent(Self.markerName) }
    var index: AgentNotesIndex { AgentNotesIndex(root: root) }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: accessMarkerURL.path)
    }

    func enable() throws {
        try FileManager.default.createDirectory(
            at: controlDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDirectory.path)
        try Data(UUID().uuidString.utf8).write(to: accessMarkerURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accessMarkerURL.path)
    }

    func disable() {
        try? FileManager.default.removeItem(at: accessMarkerURL)
    }
}

/// The agent-facing search over saved coding-agent notes, shared by the CLI
/// command and the MCP tool. Works without the app running.
enum AgentNotesSearchTool {
    static let name = "search_agent_notes"
    static let defaultLimit = 8
    static let maximumLimit = 30
    /// A note longer than this is cut, with an ellipsis.
    static let noteCharacters = 4_000
    static let agents = ["claude-code", "codex"]

    static let disabledMessage =
        "Agent-notes access is off. The user can turn it on in LokalBot → Settings → External Agents: "
        + "\"Allow external agents to read your LokalBot data\", then tick Agent notes."
    static let unavailableMessage =
        "Agent-notes access is on, but \"Read coding agent notes\" is off in LokalBot or nothing has been read "
        + "yet. The user can turn it on in LokalBot → Settings → Screen & Activity."
    static let note =
        "Notes the user's coding agents (Claude Code, Codex) wrote for their own later sessions, found by "
        + "their words. A note is what an agent recorded at the time, not a verified fact: check it against "
        + "the current code or files before relying on it. Paths point at the agents' own files; LokalBot "
        + "never changes them."

    static var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: "Search the notes the user's coding agents (Claude Code and Codex) saved for their own "
                + "later sessions: project decisions, how-tos, preferences and pointers. Returns matching notes, "
                + "best first, with their text. Use it to find what another agent or an earlier session already "
                + "learned. Requires the separate agent-notes permission.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words to find."],
                    "agent": [
                        "type": "string",
                        "enum": .array(agents.map { .string($0) }),
                        "description": "Optional: only this agent's notes.",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": .string("Maximum notes (default \(defaultLimit), maximum \(maximumLimit))."),
                    ],
                ],
                "required": ["query"],
            ])
    }

    enum Failure: LocalizedError, Equatable {
        case disabled
        case unavailable
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .disabled: AgentNotesSearchTool.disabledMessage
            case .unavailable: AgentNotesSearchTool.unavailableMessage
            case .invalid(let message): message
            }
        }

        /// What a CLI command throws for a refusal, with its code. Nil for
        /// bad arguments, which the command reports as a usage error.
        var commandError: CodedCommandError? {
            switch self {
            case .disabled:
                CodedCommandError(code: .agentNotesAccessDisabled, message: AgentNotesSearchTool.disabledMessage)
            case .unavailable:
                CodedCommandError(code: .agentNotesUnavailable, message: AgentNotesSearchTool.unavailableMessage)
            case .invalid: nil
            }
        }
    }

    struct Report: Encodable {
        struct Item: Encodable {
            var id: String
            var agent: String
            var title: String
            var summary: String?
            /// Claude Code's own label: user, feedback, project, or reference.
            var type: String?
            /// The folder the note is about, when the agent recorded it.
            var project: String?
            var path: String
            var modified: String
            var excerpt: String
            var text: String?
        }

        var query: String
        var matchedBy = "words"
        var results: [Item]
        var note: String

        enum CodingKeys: String, CodingKey {
            case query, results, note
            case matchedBy = "matched_by"
        }
    }

    static func report(
        query rawQuery: String, agent rawAgent: String? = nil, limit: Int? = nil, gate: AgentNotesAccessGate
    ) -> Result<Report, Failure> {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= LibraryInputPolicy.maximumQueryCharacters else {
            return .failure(.invalid(
                "\"query\" must be a non-empty string of at most \(LibraryInputPolicy.maximumQueryCharacters) characters."))
        }
        let count = limit ?? defaultLimit
        guard (1...maximumLimit).contains(count) else {
            return .failure(.invalid("\"limit\" must be an integer between 1 and \(maximumLimit)."))
        }
        let agent = rawAgent?.lowercased()
        if let agent, !agents.contains(agent) {
            return .failure(.invalid("\"agent\" must be one of \(agents.joined(separator: ", "))."))
        }
        guard gate.isEnabled else { return .failure(.disabled) }
        let index = gate.index
        guard index.exists else { return .failure(.unavailable) }
        let stamp = ISO8601DateFormatter()
        do {
            let items = try index.search(query, agent: agent, limit: count).map { hit -> Report.Item in
                Report.Item(
                    id: hit.id, agent: hit.agent, title: hit.title, summary: hit.summary, type: hit.category,
                    project: hit.workingDirectory, path: hit.path, modified: stamp.string(from: hit.modified),
                    excerpt: hit.snippet, text: (try? index.text(of: hit.id)).flatMap { $0 }.map(clipped))
            }
            return .success(Report(query: query, results: items, note: note))
        } catch {
            return .failure(.unavailable)
        }
    }

    static func json(_ report: Report) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A plain-text table for `lokalbot-cli search-notes --table`.
    static func table(_ report: Report) -> String {
        guard !report.results.isEmpty else { return "No agent notes matched \"\(report.query)\"." }
        return report.results.map { item in
            let project = item.project.map { " · \($0)" } ?? ""
            let excerpt = item.excerpt.replacingOccurrences(of: "\n", with: " ")
            return "\(item.agent)\t\(String(item.modified.prefix(10)))\t\(item.title)\(project)\n\t\(excerpt)\n\t\(item.path)"
        }.joined(separator: "\n")
    }

    private static func clipped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > noteCharacters else { return trimmed }
        return String(trimmed.prefix(noteCharacters)) + "…"
    }
}
