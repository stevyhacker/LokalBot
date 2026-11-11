import CryptoKit
import Foundation
import SQLite3

extension Notification.Name {
    /// Saved coding-agent notes were added, changed, or removed.
    static let agentNotesChanged = Notification.Name("agentNotesChanged")
}

/// Write side of the saved coding-agent notes (`agent-notes.sqlite` in the
/// library; `AgentNotesIndex` reads it). The file holds only what the readers
/// kept of the agents' own files, so it is rebuilt from them at any time and
/// deleted outright when the person turns the feature off.
struct AgentMemoryStore: Sendable {
    struct Change: Equatable, Sendable {
        var added = 0
        var updated = 0
        var removed = 0

        var isEmpty: Bool { added == 0 && updated == 0 && removed == 0 }
    }

    enum StoreError: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let path): "Could not open the agent notes at \(path)."
            }
        }
    }

    var databaseURL: URL

    init(root: URL) {
        databaseURL = root.appendingPathComponent(AgentNotesIndex.fileName)
    }

    /// Make the saved notes of `agents` match `scan`, and drop notes of any
    /// other agent. While a file could not be read, a note missing from the
    /// scan stays: an unreadable file is not a deleted one.
    @discardableResult
    func apply(_ scan: AgentMemoryScan, agents: Set<CodingAgentKind>) throws -> Change {
        guard let database = SQLiteDatabase(url: databaseURL) else {
            throw StoreError.unavailable(databaseURL.path)
        }
        try database.execute("""
            CREATE TABLE IF NOT EXISTS notes (
                rowid INTEGER PRIMARY KEY,
                id TEXT NOT NULL UNIQUE,
                agent TEXT NOT NULL,
                title TEXT NOT NULL,
                summary TEXT NOT NULL DEFAULT '',
                category TEXT NOT NULL DEFAULT '',
                working_directory TEXT NOT NULL DEFAULT '',
                path TEXT NOT NULL,
                modified REAL NOT NULL,
                text TEXT NOT NULL,
                digest TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS idx_notes_agent ON notes(agent);
            CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
                title, summary, text, tokenize='unicode61 remove_diacritics 2');
            """)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)

        let enabled = Set(agents.map(\.rawValue))
        var fresh: [String: AgentMemoryNote] = [:]
        for note in scan.notes where agents.contains(note.agent) { fresh[note.id] = note }
        let stored = try database.queryChecked("SELECT rowid, id, agent, digest FROM notes") { row in
            (rowID: sqlite3_column_int64(row, 0), id: Self.text(row, 1), agent: Self.text(row, 2),
             digest: Self.text(row, 3))
        }
        let storedByID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keepsMissing = !scan.unreadableFiles.isEmpty

        var change = Change()
        try database.withTransaction {
            for row in stored where fresh[row.id] == nil {
                guard !enabled.contains(row.agent) || !keepsMissing else { continue }
                try database.runChecked("DELETE FROM notes_fts WHERE rowid = ?1", bind: [row.rowID])
                try database.runChecked("DELETE FROM notes WHERE rowid = ?1", bind: [row.rowID])
                change.removed += 1
            }
            for note in fresh.values.sorted(by: { $0.id < $1.id }) {
                let digest = Self.digest(note)
                let existing = storedByID[note.id]
                guard existing?.digest != digest else { continue }
                if let existing {
                    try database.runChecked("DELETE FROM notes_fts WHERE rowid = ?1", bind: [existing.rowID])
                    try database.runChecked("DELETE FROM notes WHERE rowid = ?1", bind: [existing.rowID])
                    change.updated += 1
                } else {
                    change.added += 1
                }
                try database.runChecked("""
                    INSERT INTO notes (id, agent, title, summary, category, working_directory, path,
                                       modified, text, digest)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                    """, bind: [
                        note.id, note.agent.rawValue, note.title, note.summary ?? "", note.category ?? "",
                        note.workingDirectory ?? "", note.path, note.modifiedAt.timeIntervalSince1970,
                        note.text, digest,
                    ])
                try database.runChecked(
                    "INSERT INTO notes_fts (rowid, title, summary, text) VALUES (?1, ?2, ?3, ?4)",
                    bind: [database.lastInsertRowID(), note.title, note.summary ?? "", note.text])
            }
        }
        return change
    }

    /// Removes every saved note. The agents' own files are untouched.
    func deleteAll() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
    }

    private static func digest(_ note: AgentMemoryNote) -> String {
        let material = [
            note.agent.rawValue, note.title, note.summary ?? "", note.category ?? "",
            note.workingDirectory ?? "", note.path, String(note.modifiedAt.timeIntervalSince1970), note.text,
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}

/// Keeps the saved coding-agent notes in step with the agents' files.
///
/// Scans and writes run off the main actor, one at a time. Nothing under the
/// agents' folders is opened until the person turns the feature on, and
/// turning it off deletes what was saved.
@MainActor
final class AgentMemoryIngestor: ObservableObject {
    struct Configuration: Equatable, Sendable {
        var enabled = false
        var agents: Set<CodingAgentKind> = []
        var excludedFolders: [String] = []

        var reads: Bool { enabled && !agents.isEmpty }

        init(enabled: Bool = false, agents: Set<CodingAgentKind> = [], excludedFolders: [String] = []) {
            self.enabled = enabled
            self.agents = agents
            self.excludedFolders = excludedFolders
        }

        init(settings: AppSettings) {
            self.init(
                enabled: settings.codingAgentNotesEnabled,
                agents: settings.codingAgentNoteAgents,
                excludedFolders: settings.codingAgentExcludedFolderList)
        }
    }

    typealias Scan = @Sendable (Configuration) -> AgentMemoryScan

    static let refreshInterval: TimeInterval = 10 * 60

    /// Saved notes per agent, for Settings.
    @Published private(set) var counts: [CodingAgentKind: Int] = [:]
    @Published private(set) var lastError: String?

    private let store: AgentMemoryStore
    private let configuration: () -> Configuration
    private let scan: Scan
    private let waitUntilReady: @MainActor () async -> Void
    private var applied = Configuration()
    private var timer: Timer?
    private var latestRefresh: Task<Void, Never>?

    init(
        store: AgentMemoryStore,
        configuration: @escaping () -> Configuration,
        scan: @escaping Scan = { configuration in
            AgentMemoryScanner.standard(
                agents: configuration.agents, excludedFolders: configuration.excludedFolders).scan()
        },
        waitUntilReady: @escaping @MainActor () async -> Void = {}
    ) {
        self.store = store
        self.configuration = configuration
        self.scan = scan
        self.waitUntilReady = waitUntilReady
    }

    var total: Int { counts.values.reduce(0, +) }

    /// The setting changed, or the app launched: start reading, read again,
    /// or stop and delete.
    func start() {
        let next = configuration()
        let previous = applied
        applied = next
        timer?.invalidate()
        timer = nil
        guard next.reads else {
            if previous.reads || AgentNotesIndex(databaseURL: store.databaseURL).exists { removeAll() }
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { [weak self, waitUntilReady] in
            await waitUntilReady()
            await self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Read the agents' notes now. Refreshes run one after another.
    func refresh() async {
        let previous = latestRefresh
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performRefresh()
        }
        latestRefresh = task
        await task.value
    }

    private func performRefresh() async {
        let configuration = configuration()
        guard configuration.reads else { return }
        let scan = self.scan
        let store = self.store
        let result = await Task.detached(priority: .utility) { () -> Result<AgentMemoryStore.Change, Error> in
            let found = scan(configuration)
            return Result { try store.apply(found, agents: configuration.agents) }
        }.value
        // Turned off or narrowed while reading: what was just written must go.
        guard self.configuration() == configuration else {
            if !self.configuration().reads { removeAll() }
            return
        }
        switch result {
        case .success(let change):
            lastError = nil
            loadCounts()
            if !change.isEmpty { NotificationCenter.default.post(name: .agentNotesChanged, object: nil) }
        case .failure(let error):
            lastError = error.localizedDescription
            lokalbotLog("agent notes update failed: \(error.localizedDescription)")
        }
    }

    /// Deletion takes its turn with the refreshes, so turning the setting
    /// off and on again cannot delete what the new read just saved.
    private func removeAll() {
        let previous = latestRefresh
        let store = self.store
        counts = [:]
        lastError = nil
        latestRefresh = Task { @MainActor in
            await previous?.value
            store.deleteAll()
            NotificationCenter.default.post(name: .agentNotesChanged, object: nil)
        }
    }

    private func loadCounts() {
        let saved = (try? AgentNotesIndex(databaseURL: store.databaseURL).counts()) ?? [:]
        var counts: [CodingAgentKind: Int] = [:]
        for (agent, count) in saved {
            if let kind = CodingAgentKind(rawValue: agent) { counts[kind] = count }
        }
        self.counts = counts
    }
}

/// App-side owner of the Agent notes grant (Settings → External Agents). The
/// grant is only a marker: `lokalbot-cli` and its MCP server search the saved
/// notes themselves, without the app running, and find none while Read coding
/// agent notes is off because turning that off deletes them.
@MainActor
final class AgentNotesAccessManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?

    private let gate: AgentNotesAccessGate

    init(gate: AgentNotesAccessGate) {
        self.gate = gate
    }

    func start() {
        isEnabled = gate.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try gate.enable()
            } catch {
                lastError = "LokalBot couldn't turn on agent-notes access: \(error.localizedDescription)"
                return
            }
            isEnabled = true
            lastError = nil
        } else {
            gate.disable()
            isEnabled = false
            lastError = nil
        }
    }
}
