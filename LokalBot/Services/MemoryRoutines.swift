import Foundation
import SQLite3

struct MemoryRoutineRunRecord: Identifiable, Equatable, Sendable {
    var id: Int64
    var kind: AppSettings.MemoryRoutineKind
    var runToken: String
    var startedAt: Date
    var completedAt: Date?
    var status: String
    var outputPath: String?
    var error: String?
    var meetingID: UUID?
}

/// Durable audit trail for every routine attempt. A `running` row left by a
/// crash is intentionally not success, so the scheduler can retry it after the
/// next launch instead of silently losing a due output.
final class MemoryRoutineRunStore {
    private let database: SQLiteDatabase?
    private let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
        database = SQLiteDatabase(url: databaseURL)
        do {
            try requiredDatabase().execute("""
                CREATE TABLE IF NOT EXISTS memory_routine_runs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    run_token TEXT NOT NULL UNIQUE,
                    started_at REAL NOT NULL,
                    completed_at REAL,
                    status TEXT NOT NULL,
                    output_path TEXT NOT NULL DEFAULT '',
                    error TEXT NOT NULL DEFAULT '',
                    meeting_id TEXT NOT NULL DEFAULT '');
                CREATE INDEX IF NOT EXISTS idx_memory_routine_runs_started
                    ON memory_routine_runs(started_at DESC);
                """)
        } catch {
            lokalbotLog("routine history initialization failed: \(error.localizedDescription)")
        }
    }

    func hasSucceeded(runToken: String) -> Bool {
        do {
            return try requiredDatabase().hasRowChecked("""
                SELECT 1 FROM memory_routine_runs
                WHERE run_token = ?1 AND status = 'succeeded' LIMIT 1
                """, bind: [runToken])
        } catch {
            lokalbotLog("routine history lookup failed: \(error.localizedDescription)")
            return false
        }
    }

    /// A scheduled token is terminal after either success or failure. This
    /// prevents a bad destination or malformed source from becoming a tight
    /// retry loop; manual runs use unique tokens and remain available. A stale
    /// `running` row is deliberately non-terminal so launch recovery can retry.
    func hasFinished(runToken: String) -> Bool {
        do {
            return try requiredDatabase().hasRowChecked("""
                SELECT 1 FROM memory_routine_runs
                WHERE run_token = ?1 AND status IN ('succeeded', 'failed') LIMIT 1
                """, bind: [runToken])
        } catch {
            lokalbotLog("routine history lookup failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Reuse only the latest revision in this scope. A correction can be
    /// reverted (A -> B -> A), so an older success for A must not suppress it.
    func revisionToken(scope: String, fingerprint: String) throws -> String {
        let prefix = scope + ":revision:"
        let latest: String? = try requiredDatabase().queryChecked("""
            SELECT run_token FROM memory_routine_runs
            WHERE substr(run_token, 1, length(?1)) = ?1
            ORDER BY id DESC LIMIT 1
            """, bind: [prefix], row: { String(cString: sqlite3_column_text($0, 0)) }).first
        if let latest, latest.hasSuffix(":" + fingerprint) { return latest }
        return prefix + UUID().uuidString + ":" + fingerprint
    }

    func begin(
        kind: AppSettings.MemoryRoutineKind,
        runToken: String,
        meetingID: UUID?,
        at date: Date
    ) throws -> Int64 {
        let database = try requiredDatabase()
        try database.runChecked("""
            INSERT INTO memory_routine_runs (
                kind, run_token, started_at, completed_at, status,
                output_path, error, meeting_id
            ) VALUES (?1, ?2, ?3, NULL, 'running', '', '', ?4)
            ON CONFLICT(run_token) DO UPDATE SET
                started_at = excluded.started_at,
                completed_at = NULL,
                status = 'running',
                output_path = '',
                error = '',
                meeting_id = excluded.meeting_id
            """, bind: [kind.rawValue, runToken, date.timeIntervalSince1970,
                          meetingID?.uuidString ?? ""])
        guard let id: Int64 = try database.queryChecked(
            "SELECT id FROM memory_routine_runs WHERE run_token = ?1 LIMIT 1",
            bind: [runToken],
            row: { sqlite3_column_int64($0, 0) }).first else {
            throw SQLiteDatabase.DatabaseError.step(
                sql: nil, code: SQLITE_CORRUPT,
                message: "routine run insert did not produce a row id")
        }
        return id
    }

    func finish(id: Int64, outputURL: URL?, error: Error?, at date: Date) {
        do {
            try requiredDatabase().runChecked("""
                UPDATE memory_routine_runs
                SET completed_at = ?1, status = ?2, output_path = ?3, error = ?4
                WHERE id = ?5
                """, bind: [
                    date.timeIntervalSince1970,
                    error is CancellationError ? "cancelled" : error == nil ? "succeeded" : "failed",
                    outputURL?.path ?? "",
                    error?.localizedDescription ?? "",
                    id,
                ])
        } catch {
            lokalbotLog("routine history completion failed: \(error.localizedDescription)")
        }
    }

    func recent(limit: Int = 12) -> [MemoryRoutineRunRecord] {
        do {
            return try requiredDatabase().queryChecked("""
                SELECT id, kind, run_token, started_at, completed_at, status,
                       output_path, error, meeting_id
                FROM memory_routine_runs ORDER BY started_at DESC, id DESC LIMIT \(max(1, limit))
                """) { statement -> MemoryRoutineRunRecord? in
                guard let kindText = sqlite3_column_text(statement, 1),
                      let kind = AppSettings.MemoryRoutineKind(
                        rawValue: String(cString: kindText)) else { return nil }
                let completed = sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                let output = Self.optionalText(statement, 6)
                let error = Self.optionalText(statement, 7)
                let meetingID = Self.optionalText(statement, 8).flatMap(UUID.init(uuidString:))
                return MemoryRoutineRunRecord(
                    id: sqlite3_column_int64(statement, 0),
                    kind: kind,
                    runToken: String(cString: sqlite3_column_text(statement, 2)),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    completedAt: completed,
                    status: String(cString: sqlite3_column_text(statement, 5)),
                    outputPath: output,
                    error: error,
                    meetingID: meetingID)
            }
        } catch {
            lokalbotLog("routine history read failed: \(error.localizedDescription)")
            return []
        }
    }

    func runningCount() -> Int {
        do {
            return Int(try requiredDatabase().firstDoubleChecked("""
                SELECT COUNT(*) FROM memory_routine_runs WHERE status = 'running'
                """) ?? 0)
        } catch {
            return 0
        }
    }

    private func requiredDatabase() throws -> SQLiteDatabase {
        guard let database else {
            throw SQLiteDatabase.DatabaseError.unavailable(path: databaseURL.path)
        }
        return database
    }

    private static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }
}

enum MemoryRoutineError: LocalizedError {
    case destinationCollision(URL)
    case unsafeDestination(URL)
    case missingMeeting
    case timedOut

    var errorDescription: String? {
        switch self {
        case .destinationCollision(let url):
            "Routine output stopped because \(url.lastPathComponent) already exists with different content. The existing file was preserved."
        case .unsafeDestination(let url):
            "Routine output stopped because \(url.path) resolves outside the chosen folder or through a file symlink."
        case .missingMeeting:
            "The meeting needed by this routine is no longer in the local library."
        case .timedOut:
            "The routine exceeded its 30-second safety limit."
        }
    }
}

/// Fixed-scope local renderers. They do not invoke a shell, contact a network,
/// mutate meeting data, or accept arbitrary prompts. The sole write is one
/// private Markdown file under the user-selected destination.
enum MemoryRoutineRunner {
    static let generatedMarker = "<!-- Generated by LokalBot routine. -->"

    struct Prepared: Sendable {
        var folder: String
        var file: String
        var body: String

        var fingerprint: String { ContentFingerprint.digest(Data(body.utf8)) }
    }

    static func run(
        kind: AppSettings.MemoryRoutineKind,
        referenceDate: Date,
        storageRoot: URL,
        destinationRoot: URL,
        meetingID: UUID?,
        calendar: Calendar = .current
    ) throws -> URL {
        let prepared = try prepare(kind: kind, referenceDate: referenceDate,
                                   storageRoot: storageRoot, meetingID: meetingID, calendar: calendar)
        return try write(prepared, destinationRoot: destinationRoot)
    }

    static func prepare(
        kind: AppSettings.MemoryRoutineKind,
        referenceDate: Date,
        storageRoot: URL,
        meetingID: UUID?,
        calendar: Calendar = .current
    ) throws -> Prepared {
        try Task.checkCancellation()
        let storage = StorageManager(rootURL: storageRoot)
        let meetings = try SessionLookup.loadAllMeetings(root: storageRoot)
        try Task.checkCancellation()

        let output: (folder: String, file: String, text: String)
        switch kind {
        case .postMeetingFollowUp:
            guard let meetingID,
                  let meeting = meetings.first(where: { $0.id == meetingID }) else {
                throw MemoryRoutineError.missingMeeting
            }
            output = (
                "Post-meeting follow-ups",
                timestampKey(meeting.startedAt, calendar: calendar)
                    + "-\(SessionLookup.shortID(meeting.id))-follow-up.md",
                postMeeting(meeting, storage: storage))
        case .dailyStandup:
            output = (
                "Daily stand-ups",
                dayKey(referenceDate, calendar: calendar) + "-stand-up.md",
                try dailyStandup(
                    referenceDate, meetings: meetings, storage: storage,
                    storageRoot: storageRoot, calendar: calendar))
        case .weeklyWorkLog:
            output = (
                "Weekly work logs",
                dayKey(referenceDate, calendar: calendar) + "-work-log.md",
                try weeklyWorkLog(
                    referenceDate, meetings: meetings, storage: storage,
                    storageRoot: storageRoot, calendar: calendar))
        case .unfinishedActions:
            output = (
                "Unfinished actions",
                dayKey(referenceDate, calendar: calendar) + "-actions.md",
                unfinishedActions(
                    referenceDate, meetings: meetings, storage: storage,
                    calendar: calendar))
        case .localJournal:
            output = (
                "Journal",
                dayKey(referenceDate, calendar: calendar) + ".md",
                try localJournal(
                    referenceDate, storageRoot: storageRoot, calendar: calendar))
        }

        try Task.checkCancellation()
        let redacted = ScreenContextPrivacy.redact(output.text).text
        let body = generatedMarker + "\n\n" + redacted.trimmingCharacters(
            in: .whitespacesAndNewlines) + "\n"
        return Prepared(folder: output.folder, file: output.file, body: body)
    }

    static func write(_ output: Prepared, destinationRoot: URL) throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: destinationRoot.path) {
            try fileManager.createDirectory(
                at: destinationRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let resolvedRoot = destinationRoot.standardizedFileURL.resolvingSymlinksInPath()
        let requestedDirectory = destinationRoot.appendingPathComponent(
            output.folder, isDirectory: true)
        try fileManager.createDirectory(
            at: requestedDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let directory = requestedDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard isDescendant(directory, of: resolvedRoot) else {
            throw MemoryRoutineError.unsafeDestination(requestedDirectory)
        }
        let url = directory.appendingPathComponent(output.file, isDirectory: false)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        do {
            _ = try GeneratedFileWriter.write(Data(output.body.utf8), to: url, marker: generatedMarker)
        } catch GeneratedFileWriter.WriteError.unsafeDestination {
            throw MemoryRoutineError.unsafeDestination(url)
        } catch is GeneratedFileWriter.WriteError {
            throw MemoryRoutineError.destinationCollision(url)
        }
        return url
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard candidatePath != rootPath else { return false }
        return candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func postMeeting(_ meeting: Meeting, storage: StorageManager) -> String {
        let folder = meeting.folderURL(in: storage)
        let summary = (try? String(
            contentsOf: folder.appendingPathComponent("summary.md"),
            encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projection = MeetingOutcomeProjection.load(for: meeting, storage: storage)
        let outcomes = projection?.outcomes ?? MeetingOutcomes()
        var lines = [
            "# Follow-up draft — \(clean(meeting.title))",
            "",
            "Meeting: `\(SessionLookup.shortID(meeting.id))` · \(displayDate(meeting.startedAt))",
            "",
            "## Draft",
            "",
            "Thanks for the conversation. Here is my understanding of the outcomes:",
        ]
        if !outcomes.decisions.isEmpty {
            lines += ["", "### Decisions", ""]
            lines += outcomes.decisions.map { "- \(clean($0))" }
        }
        if let actions = projection?.actionReferences, !actions.isEmpty {
            lines += ["", "### Actions", ""]
            lines += actions.map(actionLine)
        }
        if !outcomes.openQuestions.isEmpty {
            lines += ["", "### Open questions", ""]
            lines += outcomes.openQuestions.map { "- \(clean($0))" }
        }
        if let summary, !summary.isEmpty {
            lines += ["", "## Source summary", "", String(summary.prefix(18_000))]
        }
        lines += ["", "_Draft only. Review recipients and wording before sending._"]
        return lines.joined(separator: "\n")
    }

    private static func dailyStandup(
        _ day: Date,
        meetings: [Meeting],
        storage: StorageManager,
        storageRoot: URL,
        calendar: Calendar
    ) throws -> String {
        let today = calendar.startOfDay(for: day)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
            ?? today.addingTimeInterval(-86_400)
        let interval = DateInterval(start: yesterday, end: today)
        let priorMeetings = meetings.filter { interval.contains($0.startedAt) }
            .sorted { $0.startedAt < $1.startedAt }
        let snapshot = try FileDailyMemoryExportSource(
            root: storageRoot,
            calendar: calendar).snapshot(
            for: yesterday,
            interval: interval)
        let actions = recentActions(
            since: calendar.date(byAdding: .day, value: -14, to: today) ?? .distantPast,
            meetings: meetings,
            storage: storage)
        var lines = [
            "# Daily stand-up — \(displayDate(day))",
            "",
            "## Yesterday",
            "",
        ]
        if priorMeetings.isEmpty {
            lines.append("- No recorded meetings.")
        } else {
            lines += priorMeetings.map {
                "- \(clean($0.title)) (`\(SessionLookup.shortID($0.id))`)"
            }
        }
        lines += [
            "- Tracked time: \(duration(snapshot.stats.trackedSeconds)) across \(snapshot.stats.appCount) apps.",
            "",
            "## Carry-forward actions",
            "",
        ]
        lines += actions.isEmpty ? ["- No extracted action candidates."] : actions.prefix(20).map(\.line)
        lines += [
            "",
            "## Today",
            "",
            "- [ ] Choose the priorities to carry forward from the list above.",
            "",
            "_This is a local draft. Nothing was assigned, sent, or marked complete._",
        ]
        return lines.joined(separator: "\n")
    }

    private static func weeklyWorkLog(
        _ day: Date,
        meetings: [Meeting],
        storage: StorageManager,
        storageRoot: URL,
        calendar: Calendar
    ) throws -> String {
        let end = day
        let start = calendar.date(byAdding: .day, value: -7, to: end)
            ?? end.addingTimeInterval(-7 * 86_400)
        let scoped = meetings.filter { $0.startedAt >= start && $0.startedAt <= end }
            .sorted { $0.startedAt < $1.startedAt }
        let reader = SQLiteScreenMemoryReader(
            databaseURL: storageRoot.appendingPathComponent("lokalbotv3.sqlite"))
        let usage = FileManager.default.fileExists(
            atPath: storageRoot.appendingPathComponent("lokalbotv3.sqlite").path)
            ? try reader.appUsage(from: start, to: end, limit: 20)
            : []
        var decisions: [String] = []
        var actionReferences: [OutcomeActionReference] = []
        for meeting in scoped {
            guard let projection = MeetingOutcomeProjection.load(
                for: meeting, storage: storage) else { continue }
            decisions += projection.outcomes.decisions.map {
                "- \(clean($0)) — `\(SessionLookup.shortID(meeting.id))`"
            }
            actionReferences += projection.actionReferences
        }
        let actions = ActionThreadClusterer.cluster(actionReferences).map(actionLine)
        var lines = [
            "# Weekly work log — ending \(displayDate(day))",
            "",
            "## Meetings (\(scoped.count))",
            "",
        ]
        lines += scoped.isEmpty ? ["_No recorded meetings._"] : scoped.map {
            "- \(displayDate($0.startedAt)): \(clean($0.title)) (`\(SessionLookup.shortID($0.id))`)"
        }
        lines += ["", "## Decisions", ""]
        lines += decisions.isEmpty ? ["_No extracted decisions._"] : decisions
        lines += ["", "## Action candidates", ""]
        lines += actions.isEmpty ? ["_No extracted actions._"] : actions
        lines += ["", "## App-time totals", ""]
        lines += usage.isEmpty ? ["_No tracked app activity._"] : usage.map {
            "- \(clean($0.app)): \(duration($0.durationSeconds))"
        }
        return lines.joined(separator: "\n")
    }

    private static func unfinishedActions(
        _ day: Date,
        meetings: [Meeting],
        storage: StorageManager,
        calendar: Calendar
    ) -> String {
        let cutoff = calendar.date(byAdding: .day, value: -14, to: day) ?? .distantPast
        let actions = recentActions(since: cutoff, meetings: meetings, storage: storage)
        var lines = [
            "# Unfinished action candidates — \(displayDate(day))",
            "",
            "Open and deferred actions from the last fourteen days, using your saved corrections and completion state.",
            "",
        ]
        lines += actions.isEmpty ? ["_No extracted action candidates._"] : actions.map(\.line)
        lines += ["", "_No source meeting or task system was modified._"]
        return lines.joined(separator: "\n")
    }

    private static func localJournal(
        _ day: Date,
        storageRoot: URL,
        calendar: Calendar
    ) throws -> String {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        let snapshot = try FileDailyMemoryExportSource(
            root: storageRoot,
            calendar: calendar).snapshot(
            for: start,
            interval: DateInterval(start: start, end: end))
        var lines = ["# Journal — \(displayDate(day))", "", "## Digest", ""]
        let digest = snapshot.digest?.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(digest?.isEmpty == false ? digest! : "_No day digest was generated._")
        lines += ["", "## Meetings", ""]
        lines += snapshot.meetings.isEmpty ? ["_No meetings._"] : snapshot.meetings.map {
            "- \(clean($0.title)) (`\($0.id)`)"
        }
        lines += ["", "## Saved moments", ""]
        lines += snapshot.savedMoments.isEmpty ? ["_No saved moments._"] : snapshot.savedMoments.map {
            let label = $0.windowTitle.isEmpty ? $0.app : "\($0.app) — \($0.windowTitle)"
            return "- \(clean(label)) (`screen:\($0.snapshotID)`)"
        }
        lines += [
            "", "## Day stats", "",
            "- Tracked time: \(duration(snapshot.stats.trackedSeconds))",
            "- Apps: \(snapshot.stats.appCount)",
            "- Context captures: \(snapshot.stats.screenshotCount)",
        ]
        return lines.joined(separator: "\n")
    }

    private struct ActionReference {
        var line: String
    }

    private static func recentActions(
        since cutoff: Date,
        meetings: [Meeting],
        storage: StorageManager
    ) -> [ActionReference] {
        let references = meetings
            .filter { $0.startedAt >= cutoff }
            .sorted { $0.startedAt > $1.startedAt }
            .flatMap { meeting -> [OutcomeActionReference] in
                guard let projection = MeetingOutcomeProjection.load(
                    for: meeting, storage: storage) else { return [] }
                return projection.actionReferences
            }
        return ActionThreadClusterer.cluster(references)
            .filter { $0.status != .done }
            .map {
                ActionReference(line: actionLine($0))
            }
    }

    private static func actionLine(_ thread: ActionThread) -> String {
        var suffix: [String] = []
        if let owner = thread.owner, !owner.isEmpty {
            suffix.append("owner: \(clean(owner))")
        }
        if let due = thread.due, !due.isEmpty {
            suffix.append("due: \(clean(due))")
        }
        if thread.status == .deferred { suffix.append("status: deferred") }
        let sources = thread.references.map {
            SessionLookup.shortID($0.meetingID)
        }.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        suffix.append("sources: " + sources.map { "`\($0)`" }.joined(separator: ", "))
        let marker = thread.status == .done ? "x" : " "
        return "- [\(marker)] \(clean(thread.text))"
            + (suffix.isEmpty ? "" : " (\(suffix.joined(separator: ", ")))")
    }

    private static func actionLine(_ reference: OutcomeActionReference) -> String {
        var suffix: [String] = []
        if let owner = reference.owner, !owner.isEmpty {
            suffix.append("owner: \(clean(owner))")
        }
        if let due = reference.due, !due.isEmpty {
            suffix.append("due: \(clean(due))")
        }
        if reference.status == .deferred { suffix.append("status: deferred") }
        let marker = reference.status == .done ? "x" : " "
        return "- [\(marker)] \(clean(reference.text))"
            + (suffix.isEmpty ? "" : " (\(suffix.joined(separator: ", ")))")
    }

    private static func clean(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func timestampKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d-%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func displayDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds.rounded()) / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

@MainActor
final class MemoryRoutineScheduler: ObservableObject {
    struct Configuration: Equatable, Sendable {
        var enabled: Bool
        var destinationPath: String
        var kinds: [AppSettings.MemoryRoutineKind]
        var hour: Int
        var weekday: Int

        var normalizedHour: Int { min(23, max(0, hour)) }
        var normalizedWeekday: Int { min(7, max(1, weekday)) }
    }

    struct Job: Sendable {
        var kind: AppSettings.MemoryRoutineKind
        var referenceDate: Date
        var meetingID: UUID?
        var runToken: String
    }

    typealias Prepare = @Sendable (Job) async throws -> MemoryRoutineRunner.Prepared

    @Published private(set) var isRunning = false
    @Published private(set) var currentKind: AppSettings.MemoryRoutineKind?
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var lastOutputURL: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var recentRuns: [MemoryRoutineRunRecord] = []
    @Published private(set) var dueCount = 0

    private let storageRoot: URL
    private let store: MemoryRoutineRunStore
    private let calendar: Calendar
    private let now: () -> Date
    private let canRun: () -> Bool
    private let prepare: Prepare
    private var configuration: Configuration?
    private var timer: Timer?
    private var runTask: Task<Void, Never>?
    private var activeRunID: Int64?
    private var errorHandler: ((String) -> Void)?
    private var generation = 0

    init(
        storageRoot: URL,
        databaseURL: URL,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        canRun: @escaping () -> Bool = { true },
        prepare: Prepare? = nil
    ) {
        self.storageRoot = storageRoot
        store = MemoryRoutineRunStore(databaseURL: databaseURL)
        self.calendar = calendar
        self.now = now
        self.canRun = canRun
        self.prepare = prepare ?? { job in
            try await Self.withTimeout {
                try MemoryRoutineRunner.prepare(
                    kind: job.kind, referenceDate: job.referenceDate, storageRoot: storageRoot,
                    meetingID: job.meetingID, calendar: calendar)
            }
        }
        recentRuns = store.recent()
    }

    var pendingCount: Int { dueCount + store.runningCount() }

    func configure(_ configuration: Configuration, onError: @escaping (String) -> Void) {
        if self.configuration != configuration { cancelCurrentRun() }
        self.configuration = configuration
        errorHandler = onError
        timer?.invalidate()
        timer = nil
        guard configuration.enabled, !configuration.destinationPath.isEmpty else {
            dueCount = 0
            return
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelCurrentRun()
    }

    /// Rebuild prepared output after a correction, completion, or deletion.
    /// Finished revisions remain in the audit trail; changed bytes get a new token.
    func reconsiderEvidence() {
        cancelCurrentRun()
        tick()
    }

    private func cancelCurrentRun() {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        if let activeRunID {
            store.finish(id: activeRunID, outputURL: nil, error: CancellationError(), at: now())
        }
        activeRunID = nil
        isRunning = false
        currentKind = nil
        dueCount = 0
    }

    func tick() {
        guard runTask == nil,
              let configuration, configuration.enabled,
              !configuration.destinationPath.isEmpty, canRun() else { return }
        let jobs = candidateJobs(configuration: configuration, at: now())
        guard !jobs.isEmpty else { return }
        start(jobs, configuration: configuration)
    }

    func runNow(_ kind: AppSettings.MemoryRoutineKind) {
        guard runTask == nil, kind != .postMeetingFollowUp,
              let configuration, configuration.enabled,
              configuration.kinds.contains(kind),
              !configuration.destinationPath.isEmpty, canRun() else { return }
        let date = now()
        start([Job(
            kind: kind, referenceDate: date, meetingID: nil,
            runToken: "manual:\(kind.rawValue):\(date.timeIntervalSince1970):\(UUID().uuidString)"
        )], configuration: configuration)
    }

    private func start(_ jobs: [Job], configuration: Configuration) {
        let runGeneration = generation
        let destination = URL(fileURLWithPath: configuration.destinationPath, isDirectory: true)
        let destinationID = ContentFingerprint.fields([destination.standardizedFileURL.path])
        isRunning = true
        dueCount = jobs.count
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for job in jobs {
                guard !Task.isCancelled, generation == runGeneration else { return }
                currentKind = job.kind
                let scope = "\(job.runToken):\(destinationID)"
                do {
                    let prepared = try await prepare(job)
                    try Task.checkCancellation()
                    guard generation == runGeneration else { return }
                    let token = try store.revisionToken(scope: scope, fingerprint: prepared.fingerprint)
                    if !store.hasFinished(runToken: token) {
                        activeRunID = try store.begin(
                            kind: job.kind, runToken: token, meetingID: job.meetingID, at: now())
                        let output = try await Self.withTimeout {
                            try MemoryRoutineRunner.write(prepared, destinationRoot: destination)
                        }
                        guard !Task.isCancelled, generation == runGeneration else { return }
                        if let activeRunID {
                            store.finish(id: activeRunID, outputURL: output, error: nil, at: now())
                        }
                        lastRunAt = now()
                        lastOutputURL = output
                        lastError = nil
                    }
                } catch is CancellationError {
                    guard generation == runGeneration else { return }
                    if let activeRunID {
                        store.finish(id: activeRunID, outputURL: nil, error: CancellationError(), at: now())
                    }
                } catch {
                    guard generation == runGeneration else { return }
                    // Preparation may fail before output has a fingerprint. Record
                    // the failure once; read-only preparation can recover next tick.
                    let fingerprint = "prepare-error:" + ContentFingerprint.fields([error.localizedDescription])
                    if activeRunID == nil,
                       let token = try? store.revisionToken(scope: scope, fingerprint: fingerprint),
                       !store.hasFinished(runToken: token) {
                        activeRunID = try? store.begin(
                            kind: job.kind, runToken: token, meetingID: job.meetingID, at: now())
                    }
                    if let activeRunID {
                        store.finish(id: activeRunID, outputURL: nil, error: error, at: now())
                        lastError = "Memory routine failed: \(error.localizedDescription)"
                        errorHandler?(lastError!)
                    }
                }
                activeRunID = nil
                dueCount -= 1
                recentRuns = store.recent()
            }
            guard generation == runGeneration else { return }
            isRunning = false
            currentKind = nil
            runTask = nil
            dueCount = 0
        }
    }

    private func candidateJobs(configuration: Configuration, at current: Date) -> [Job] {
        let enabled = Set(configuration.kinds)
        var jobs: [Job] = []
        if enabled.contains(.postMeetingFollowUp) {
            let cutoff = current.addingTimeInterval(-14 * 86_400)
            let meetings = (try? SessionLookup.loadAllMeetings(root: storageRoot)) ?? []
            for meeting in meetings where !meeting.isSample
                && meeting.startedAt >= cutoff && meeting.startedAt <= current {
                let summary = storageRoot.appendingPathComponent(meeting.relativePath)
                    .appendingPathComponent("summary.md")
                guard FileManager.default.fileExists(atPath: summary.path) else { continue }
                jobs.append(Job(
                    kind: .postMeetingFollowUp, referenceDate: meeting.startedAt, meetingID: meeting.id,
                    runToken: "scheduled:postMeetingFollowUp:\(meeting.id.uuidString)"))
            }
        }

        let today = calendar.startOfDay(for: current)
        let target = calendar.date(bySettingHour: configuration.normalizedHour, minute: 0, second: 0, of: current) ?? today
        if current >= target {
            for kind in AppSettings.MemoryRoutineKind.allCases where
                enabled.contains(kind) && !kind.isEventDriven && !kind.isWeekly {
                jobs.append(Job(
                    kind: kind, referenceDate: today, meetingID: nil,
                    runToken: "scheduled:\(kind.rawValue):\(Self.dayKey(today, calendar: calendar))"))
            }
        }
        if enabled.contains(.weeklyWorkLog),
           let weeklyTarget = mostRecentWeeklyTarget(
                at: current, weekday: configuration.normalizedWeekday, hour: configuration.normalizedHour) {
            jobs.append(Job(
                kind: .weeklyWorkLog, referenceDate: weeklyTarget, meetingID: nil,
                runToken: "scheduled:weeklyWorkLog:\(Self.dayKey(weeklyTarget, calendar: calendar))"))
        }
        return jobs
    }

    private func mostRecentWeeklyTarget(at current: Date, weekday: Int, hour: Int) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        components.second = 0
        return calendar.nextDate(after: current.addingTimeInterval(1), matching: components,
                                 matchingPolicy: .nextTime, direction: .backward)
    }

    private nonisolated static func withTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: .utility) {
                try Task.checkCancellation()
                return try operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw MemoryRoutineError.timedOut
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
