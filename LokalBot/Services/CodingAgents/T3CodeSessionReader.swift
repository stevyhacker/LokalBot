import Foundation
import SQLite3

struct T3CodeSessionReader: CodingAgentSessionReader {
    var agent: CodingAgentKind { .t3Code }
    var root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".t3/userdata", isDirectory: true)) {
        self.root = root
    }

    func transcripts(in interval: DateInterval) -> CodingAgentReadResult {
        transcripts(in: interval, cache: nil)
    }

    func transcripts(in interval: DateInterval, cache: CodingAgentParseCache?) -> CodingAgentReadResult {
        var result = CodingAgentReadResult()
        var seenThreadIDs: Set<String> = []

        let v2URL = root.appendingPathComponent("statev2.sqlite")
        if let meta = Self.databaseMetadata(at: v2URL), meta.modified >= interval.start {
            do {
                let db = try T3ReadOnlyDatabase(url: v2URL)
                result.filesRead += 1
                result.bytesRead += meta.size
                if try db.tableExists("orchestration_v2_projection_threads") {
                    let loaded = try Self.readV2(db: db, in: interval)
                    result.claimedSessions.formUnion(loaded.claimed)
                    for transcript in loaded.transcripts where seenThreadIDs.insert(transcript.sessionID).inserted {
                        result.transcripts.append(transcript)
                    }
                }
            } catch {
                result.unreadableFiles.append(v2URL.path)
            }
        }

        let v1URL = root.appendingPathComponent("state.sqlite")
        if let meta = Self.databaseMetadata(at: v1URL), meta.modified >= interval.start {
            do {
                let db = try T3ReadOnlyDatabase(url: v1URL)
                result.filesRead += 1
                result.bytesRead += meta.size
                if try db.tableExists("projection_threads") {
                    let loaded = try Self.readV1(db: db, in: interval, skipping: seenThreadIDs)
                    result.claimedSessions.formUnion(loaded.claimed)
                    for transcript in loaded.transcripts where seenThreadIDs.insert(transcript.sessionID).inserted {
                        result.transcripts.append(transcript)
                    }
                }
            } catch {
                result.unreadableFiles.append(v1URL.path)
            }
        }

        result.transcripts.sort { $0.sessionID < $1.sessionID }
        return result
    }

    private struct ThreadHeader {
        var id: String
        var title: String?
        var workingDirectory: String?
        var branch: String?
        var createdAt: Date?
        var pullRequestsJSON: String?
    }

    private static func readV2(
        db: T3ReadOnlyDatabase, in interval: DateInterval
    ) throws -> (transcripts: [CodingAgentTranscript], claimed: Set<CodingAgentSessionKey>) {
        let wideStart = isoUTC(interval.start.addingTimeInterval(-14 * 3_600))
        let wideEnd = isoUTC(interval.end.addingTimeInterval(14 * 3_600))

        var claimed: Set<CodingAgentSessionKey> = []
        if try db.tableExists("orchestration_v2_projection_provider_threads") {
            let sql = """
                SELECT driver, json_extract(payload_json, '$.nativeThreadRef.nativeId')
                FROM orchestration_v2_projection_provider_threads
                WHERE driver IN ('claudeAgent', 'codex')
                  AND updated_at >= ?1
                  AND (json_extract(payload_json, '$.createdAt') IS NULL
                       OR json_extract(payload_json, '$.createdAt') < ?2)
                  AND json_extract(payload_json, '$.nativeThreadRef.nativeId') IS NOT NULL
                """
            try db.forEachRow(sql, bind: [wideStart, wideEnd]) { stmt in
                guard let driver = Self.columnText(stmt, 0),
                      let nativeID = Self.columnText(stmt, 1), !nativeID.isEmpty,
                      let kind = Self.nativeAgentKind(for: driver) else { return }
                claimed.insert(CodingAgentSessionKey(agent: kind, sessionID: nativeID))
            }
        }

        let hasProjects = try db.tableExists("projection_projects")
        let threadsSQL = hasProjects
            ? """
                SELECT t.thread_id, t.title, t.created_at,
                       json_extract(t.payload_json, '$.branch'),
                       json_extract(t.payload_json, '$.worktreePath'),
                       json_extract(t.payload_json, '$.lineage.parentThreadId'),
                       json_extract(t.payload_json, '$.lineage.relationshipToParent'),
                       json_extract(t.payload_json, '$.pullRequests'),
                       p.workspace_root
                FROM orchestration_v2_projection_threads t
                LEFT JOIN projection_projects p ON t.project_id = p.project_id
                WHERE t.deleted_at IS NULL
                  AND t.updated_at >= ?1
                  AND t.created_at < ?2
                """
            : """
                SELECT t.thread_id, t.title, t.created_at,
                       json_extract(t.payload_json, '$.branch'),
                       json_extract(t.payload_json, '$.worktreePath'),
                       json_extract(t.payload_json, '$.lineage.parentThreadId'),
                       json_extract(t.payload_json, '$.lineage.relationshipToParent'),
                       json_extract(t.payload_json, '$.pullRequests'),
                       NULL
                FROM orchestration_v2_projection_threads t
                WHERE t.deleted_at IS NULL
                  AND t.updated_at >= ?1
                  AND t.created_at < ?2
                """

        var threads: [String: ThreadHeader] = [:]
        try db.forEachRow(threadsSQL, bind: [wideStart, wideEnd]) { stmt in
            guard let id = Self.columnText(stmt, 0), !id.isEmpty else { return }
            let parentID = Self.columnText(stmt, 5)
            let relationship = Self.columnText(stmt, 6)
            guard !Self.isSubagentThread(id: id, parentThreadID: parentID, relationship: relationship) else {
                return
            }
            let workspaceRoot = Self.nonEmpty(Self.columnText(stmt, 8))
            let worktreePath = Self.nonEmpty(Self.columnText(stmt, 4))
            let rawBranch = Self.nonEmpty(Self.columnText(stmt, 3))
            let branch = rawBranch == "HEAD" ? nil : rawBranch
            threads[id] = ThreadHeader(
                id: id,
                title: Self.columnText(stmt, 1).flatMap(CodingAgentText.title),
                workingDirectory: workspaceRoot ?? worktreePath,
                branch: branch,
                createdAt: CodingAgentTimestamp.date(Self.columnText(stmt, 2)),
                pullRequestsJSON: Self.columnText(stmt, 7))
        }
        guard !threads.isEmpty else { return ([], claimed) }

        var eventsByThread: [String: [CodingAgentEvent]] = [:]
        var consultedByThread: Set<String> = []

        for (threadID, header) in threads {
            for pr in Self.linkedPullRequests(in: header.pullRequestsJSON, fallback: header.createdAt)
            where interval.contains(pr.at) {
                eventsByThread[threadID, default: []].append(CodingAgentEvent(at: pr.at, kind: .pullRequest(pr.url)))
            }
        }
        if try db.tableExists("projection_thread_pull_requests") {
            let prSQL = """
                SELECT thread_id, url, linked_at
                FROM projection_thread_pull_requests
                WHERE linked_at >= ?1 AND linked_at < ?2
                """
            try db.forEachRow(prSQL, bind: [wideStart, wideEnd]) { stmt in
                guard let threadID = Self.columnText(stmt, 0), threads[threadID] != nil,
                      let url = Self.columnText(stmt, 1),
                      let at = CodingAgentTimestamp.date(Self.columnText(stmt, 2)),
                      interval.contains(at) else { return }
                for valid in CodingAgentText.pullRequestURLs(in: url) {
                    eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .pullRequest(valid)))
                }
            }
        }

        if try db.tableExists("orchestration_v2_projection_messages") {
            let msgSQL = """
                SELECT thread_id, role, created_at, updated_at,
                       json_extract(payload_json, '$.text'),
                       json_extract(payload_json, '$.createdBy'),
                       json_extract(payload_json, '$.creationSource')
                FROM orchestration_v2_projection_messages
                WHERE created_at >= ?1 AND created_at < ?2
                ORDER BY created_at, message_id
                """
            try db.forEachRow(msgSQL, bind: [wideStart, wideEnd]) { stmt in
                guard let threadID = Self.columnText(stmt, 0), threads[threadID] != nil,
                      let role = Self.columnText(stmt, 1),
                      let createdAt = CodingAgentTimestamp.date(Self.columnText(stmt, 2)) else { return }
                let updatedAt = CodingAgentTimestamp.date(Self.columnText(stmt, 3))
                let text = Self.columnText(stmt, 4) ?? ""
                let createdBy = Self.columnText(stmt, 5)
                let creationSource = Self.columnText(stmt, 6)

                if role == "user" {
                    guard interval.contains(createdAt) else { return }
                    if createdBy == "agent" {
                        if creationSource == "schedule" {
                            let label = CodingAgentText.sanitized(text, maxCharacters: 80)
                            let prompt = label.isEmpty ? "Scheduled task: unnamed" : "Scheduled task: \(label)"
                            eventsByThread[threadID, default: []].append(
                                CodingAgentEvent(at: createdAt, kind: .prompt(prompt)))
                        } else {
                            eventsByThread[threadID, default: []].append(
                                CodingAgentEvent(at: createdAt, kind: .activity))
                        }
                    } else if let prompt = CodingAgentText.prompt(text) {
                        eventsByThread[threadID, default: []].append(
                            CodingAgentEvent(at: createdAt, kind: .prompt(prompt)))
                    } else {
                        eventsByThread[threadID, default: []].append(
                            CodingAgentEvent(at: createdAt, kind: .activity))
                    }
                } else if role == "assistant" {
                    let at = updatedAt.flatMap { interval.contains($0) ? $0 : nil } ?? createdAt
                    guard interval.contains(at) else { return }
                    if let reply = CodingAgentText.reply(text) {
                        eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .reply(reply)))
                    } else {
                        eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .activity))
                    }
                }
            }
        }

        if try db.tableExists("orchestration_v2_projection_turn_items") {
            let itemSQL = """
                SELECT thread_id, type, updated_at,
                       json_extract(payload_json, '$.startedAt'),
                       json_extract(payload_json, '$.completedAt'),
                       CASE type
                           WHEN 'command_execution' THEN json_extract(payload_json, '$.input')
                           ELSE NULL
                       END,
                       CASE type
                           WHEN 'file_change' THEN json_extract(payload_json, '$.fileName')
                           ELSE NULL
                       END,
                       CASE type
                           WHEN 'file_change' THEN json_extract(payload_json, '$.changes')
                           ELSE NULL
                       END,
                       CASE type
                           WHEN 'dynamic_tool' THEN json_extract(payload_json, '$.toolName')
                           ELSE NULL
                       END,
                       CASE type
                           WHEN 'dynamic_tool' THEN json_extract(payload_json, '$.input')
                           ELSE NULL
                       END
                FROM orchestration_v2_projection_turn_items
                WHERE updated_at >= ?1
                  AND COALESCE(json_extract(payload_json, '$.startedAt'), updated_at) < ?2
                  AND type NOT IN ('user_message', 'assistant_message')
                ORDER BY ordinal, turn_item_id
                """
            try db.forEachRow(itemSQL, bind: [wideStart, wideEnd]) { stmt in
                guard let threadID = Self.columnText(stmt, 0),
                      let header = threads[threadID],
                      let type = Self.columnText(stmt, 1) else { return }
                let updatedAt = CodingAgentTimestamp.date(Self.columnText(stmt, 2))
                let startedAt = CodingAgentTimestamp.date(Self.columnText(stmt, 3))
                let completedAt = CodingAgentTimestamp.date(Self.columnText(stmt, 4))
                let rawAt = (type == "file_change" ? (completedAt ?? startedAt) : (startedAt ?? completedAt))
                    ?? updatedAt
                guard let at = rawAt, interval.contains(at) else { return }

                switch type {
                case "command_execution":
                    eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .toolCall))
                    if let command = Self.columnText(stmt, 5), !command.isEmpty {
                        if CodingAgentText.readsLokalBot(command: command) {
                            consultedByThread.insert(threadID)
                        }
                        for action in CodingAgentText.actions(inCommand: command) {
                            eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .action(action)))
                        }
                        for url in CodingAgentText.pullRequestURLs(in: command) {
                            eventsByThread[threadID, default: []].append(
                                CodingAgentEvent(at: at, kind: .pullRequest(url)))
                        }
                    }
                case "file_change":
                    eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .toolCall))
                    let paths = Self.fileChangePaths(
                        fileName: Self.columnText(stmt, 6), changesJSON: Self.columnText(stmt, 7))
                    for path in paths {
                        let named = CodingAgentText.displayPath(path, workingDirectory: header.workingDirectory)
                        eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .fileChange(named)))
                    }
                case "dynamic_tool":
                    eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .toolCall))
                    let toolName = Self.columnText(stmt, 8) ?? ""
                    if CodingAgentText.readsLokalBot(toolName: toolName) {
                        consultedByThread.insert(threadID)
                    }
                    let inputObject = Self.jsonObject(Self.columnText(stmt, 9))
                    let prEvents = CodingAgentText.pullRequestEvents(
                        toolName: toolName,
                        title: inputObject?["title"] as? String,
                        number: inputObject?["number"] as? Int,
                        url: inputObject?["url"] as? String,
                        urls: inputObject?["urls"] as? [String] ?? [])
                    for kind in prEvents {
                        eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: kind))
                    }
                case "file_search", "web_search", "subagent":
                    eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .toolCall))
                default:
                    eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .activity))
                }
            }

            let checkSQL = """
                SELECT DISTINCT thread_id, type,
                       CASE type
                           WHEN 'command_execution' THEN json_extract(payload_json, '$.input')
                           WHEN 'dynamic_tool' THEN json_extract(payload_json, '$.toolName')
                           ELSE NULL
                       END
                FROM orchestration_v2_projection_turn_items
                WHERE type IN ('command_execution', 'dynamic_tool')
                  AND payload_json LIKE '%lokalbot%'
                """
            try db.forEachRow(checkSQL) { stmt in
                guard let threadID = Self.columnText(stmt, 0),
                      threads[threadID] != nil,
                      !consultedByThread.contains(threadID),
                      let type = Self.columnText(stmt, 1),
                      let value = Self.columnText(stmt, 2) else { return }
                if (type == "command_execution" && CodingAgentText.readsLokalBot(command: value))
                    || (type == "dynamic_tool" && CodingAgentText.readsLokalBot(toolName: value)) {
                    consultedByThread.insert(threadID)
                }
            }
        }

        var transcripts: [CodingAgentTranscript] = []
        for (threadID, header) in threads {
            let rawEvents = eventsByThread[threadID] ?? []
            guard rawEvents.contains(where: { !$0.isAnnotation }) else { continue }
            let compacted = CodingAgentBurstBuilder.compactingActivity(rawEvents)
            transcripts.append(CodingAgentTranscript(
                agent: .t3Code,
                sessionID: threadID,
                title: header.title,
                workingDirectory: header.workingDirectory,
                branch: header.branch,
                consultedLokalBot: consultedByThread.contains(threadID),
                events: compacted))
        }
        return (transcripts, claimed)
    }

    private static func readV1(
        db: T3ReadOnlyDatabase, in interval: DateInterval, skipping existingIDs: Set<String>
    ) throws -> (transcripts: [CodingAgentTranscript], claimed: Set<CodingAgentSessionKey>) {
        let wideStart = isoUTC(interval.start.addingTimeInterval(-14 * 3_600))
        let wideEnd = isoUTC(interval.end.addingTimeInterval(14 * 3_600))

        var claimed: Set<CodingAgentSessionKey> = []
        if try db.tableExists("projection_thread_sessions") {
            let sql = """
                SELECT provider_name, provider_session_id, provider_thread_id
                FROM projection_thread_sessions
                WHERE updated_at >= ?1
                """
            try db.forEachRow(sql, bind: [wideStart]) { stmt in
                guard let provider = Self.columnText(stmt, 0),
                      let kind = Self.nativeAgentKind(for: provider) else { return }
                for col: Int32 in [1, 2] {
                    if let id = Self.nonEmpty(Self.columnText(stmt, col)) {
                        claimed.insert(CodingAgentSessionKey(agent: kind, sessionID: id))
                    }
                }
            }
        }

        let hasProjects = try db.tableExists("projection_projects")
        let threadsSQL = hasProjects
            ? """
                SELECT t.thread_id, t.title, t.branch, t.worktree_path, p.workspace_root
                FROM projection_threads t
                LEFT JOIN projection_projects p ON t.project_id = p.project_id
                WHERE t.deleted_at IS NULL AND t.updated_at >= ?1 AND t.created_at < ?2
                """
            : """
                SELECT t.thread_id, t.title, t.branch, t.worktree_path, NULL
                FROM projection_threads t
                WHERE t.deleted_at IS NULL AND t.updated_at >= ?1 AND t.created_at < ?2
                """

        var threads: [String: ThreadHeader] = [:]
        try db.forEachRow(threadsSQL, bind: [wideStart, wideEnd]) { stmt in
            guard let id = Self.columnText(stmt, 0), !id.isEmpty,
                  !existingIDs.contains(id),
                  !Self.isSubagentThread(id: id, parentThreadID: nil, relationship: nil) else { return }
            let workspaceRoot = Self.nonEmpty(Self.columnText(stmt, 4))
            let worktreePath = Self.nonEmpty(Self.columnText(stmt, 3))
            let rawBranch = Self.nonEmpty(Self.columnText(stmt, 2))
            threads[id] = ThreadHeader(
                id: id,
                title: Self.columnText(stmt, 1).flatMap(CodingAgentText.title),
                workingDirectory: workspaceRoot ?? worktreePath,
                branch: rawBranch == "HEAD" ? nil : rawBranch)
        }
        guard !threads.isEmpty else { return ([], claimed) }

        var eventsByThread: [String: [CodingAgentEvent]] = [:]
        if try db.tableExists("projection_thread_messages") {
            let sql = """
                SELECT thread_id, role, text, created_at, updated_at
                FROM projection_thread_messages
                WHERE created_at >= ?1 AND created_at < ?2
                ORDER BY created_at, message_id
                """
            try db.forEachRow(sql, bind: [wideStart, wideEnd]) { stmt in
                guard let threadID = Self.columnText(stmt, 0), threads[threadID] != nil,
                      let role = Self.columnText(stmt, 1),
                      let createdAt = CodingAgentTimestamp.date(Self.columnText(stmt, 3)) else { return }
                let text = Self.columnText(stmt, 2) ?? ""
                let updatedAt = CodingAgentTimestamp.date(Self.columnText(stmt, 4))
                if role == "user", interval.contains(createdAt) {
                    if let prompt = CodingAgentText.prompt(text) {
                        eventsByThread[threadID, default: []].append(CodingAgentEvent(at: createdAt, kind: .prompt(prompt)))
                    } else {
                        eventsByThread[threadID, default: []].append(CodingAgentEvent(at: createdAt, kind: .activity))
                    }
                } else if role == "assistant" {
                    let at = updatedAt.flatMap { interval.contains($0) ? $0 : nil } ?? createdAt
                    guard interval.contains(at) else { return }
                    if let reply = CodingAgentText.reply(text) {
                        eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .reply(reply)))
                    } else {
                        eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .activity))
                    }
                }
            }
        }

        if try db.tableExists("projection_thread_pull_requests") {
            let sql = """
                SELECT thread_id, url, linked_at
                FROM projection_thread_pull_requests
                WHERE linked_at >= ?1 AND linked_at < ?2
                """
            try db.forEachRow(sql, bind: [wideStart, wideEnd]) { stmt in
                guard let threadID = Self.columnText(stmt, 0), threads[threadID] != nil,
                      let url = Self.columnText(stmt, 1),
                      let at = CodingAgentTimestamp.date(Self.columnText(stmt, 2)),
                      interval.contains(at) else { return }
                for valid in CodingAgentText.pullRequestURLs(in: url) {
                    eventsByThread[threadID, default: []].append(CodingAgentEvent(at: at, kind: .pullRequest(valid)))
                }
            }
        }

        var transcripts: [CodingAgentTranscript] = []
        for (threadID, header) in threads {
            let rawEvents = eventsByThread[threadID] ?? []
            guard rawEvents.contains(where: { !$0.isAnnotation }) else { continue }
            transcripts.append(CodingAgentTranscript(
                agent: .t3Code,
                sessionID: threadID,
                title: header.title,
                workingDirectory: header.workingDirectory,
                branch: header.branch,
                events: CodingAgentBurstBuilder.compactingActivity(rawEvents)))
        }
        return (transcripts, claimed)
    }

    private static func databaseMetadata(at url: URL) -> (modified: Date, size: Int)? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
        ]), values.isRegularFile == true, let modified = values.contentModificationDate else { return nil }
        var latest = modified
        var totalSize = values.fileSize ?? 0
        let wal = URL(fileURLWithPath: url.path + "-wal")
        if let walValues = try? wal.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
            if let walModified = walValues.contentModificationDate, walModified > latest {
                latest = walModified
            }
            totalSize += walValues.fileSize ?? 0
        }
        return (latest, totalSize)
    }

    private static func isSubagentThread(id: String, parentThreadID: String?, relationship: String?) -> Bool {
        if let parentThreadID, !parentThreadID.isEmpty { return true }
        if relationship == "subagent" { return true }
        return id.hasPrefix("thread:delegated-task:") || id.hasPrefix("thread:subagent:")
    }

    private static func nativeAgentKind(for driver: String) -> CodingAgentKind? {
        switch driver.lowercased() {
        case "claudeagent", "claude", "claude-code": .claudeCode
        case "codex": .codex
        default: nil
        }
    }

    private static func linkedPullRequests(
        in json: String?, fallback: Date?
    ) -> [(url: String, at: Date)] {
        guard let json, let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var result: [(url: String, at: Date)] = []
        for entry in array {
            guard let rawURL = entry["url"] as? String,
                  let at = CodingAgentTimestamp.date(entry["linkedAt"] as? String) ?? fallback else { continue }
            for url in CodingAgentText.pullRequestURLs(in: rawURL) {
                result.append((url, at))
            }
        }
        return result
    }

    private static func fileChangePaths(fileName: String?, changesJSON: String?) -> [String] {
        var paths: [String] = []
        if let changesJSON, let data = changesJSON.data(using: .utf8),
           let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for entry in array {
                if let path = entry["path"] as? String, !path.isEmpty, !paths.contains(path) {
                    paths.append(path)
                }
            }
        }
        if paths.isEmpty, let fileName, !fileName.isEmpty {
            paths.append(fileName)
        }
        return paths
    }

    private static func jsonObject(_ raw: String?) -> [String: Any]? {
        guard let raw, raw.hasPrefix("{"), let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: pointer)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func isoUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private final class T3ReadOnlyDatabase {
    enum ReadError: Error {
        case open(Int32)
        case query(Int32)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let handle: OpaquePointer

    init(url: URL) throws {
        if let opened = Self.open(url: url, immutable: false) {
            handle = opened
            return
        }
        if let opened = Self.open(url: url, immutable: true) {
            handle = opened
            return
        }
        throw ReadError.open(SQLITE_CANTOPEN)
    }

    deinit {
        sqlite3_close(handle)
    }

    func tableExists(_ name: String) throws -> Bool {
        var exists = false
        try forEachRow(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1",
            bind: [name]
        ) { _ in exists = true }
        return exists
    }

    func forEachRow(_ sql: String, bind values: [String] = [], _ body: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepared == SQLITE_OK, let stmt else { throw ReadError.query(prepared) }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in values.enumerated() {
            let bound = sqlite3_bind_text(stmt, Int32(index + 1), value, -1, Self.transient)
            guard bound == SQLITE_OK else { throw ReadError.query(bound) }
        }
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            body(stmt)
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw ReadError.query(step) }
    }

    private static func open(url: URL, immutable: Bool) -> OpaquePointer? {
        let query = immutable ? "?mode=ro&immutable=1" : "?mode=ro"
        let uri = URL(fileURLWithPath: url.path).absoluteString + query
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(uri, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard status == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            return nil
        }
        sqlite3_busy_timeout(opened, 2_000)
        var stmt: OpaquePointer?
        let probe = sqlite3_prepare_v2(opened, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &stmt, nil)
        if probe == SQLITE_OK, let stmt {
            let step = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            if step == SQLITE_ROW || step == SQLITE_DONE { return opened }
        } else if let stmt {
            sqlite3_finalize(stmt)
        }
        sqlite3_close(opened)
        return nil
    }
}
