import Foundation

/// What one reader found for a day. Unreadable files are reported, never
/// fatal: an agent update that changes its format must not stop the digest.
struct CodingAgentReadResult: Sendable {
    var transcripts: [CodingAgentTranscript] = []
    var filesRead = 0
    var bytesRead = 0
    var unreadableFiles: [String] = []
}

protocol CodingAgentSessionReader: Sendable {
    var agent: CodingAgentKind { get }
    /// Sessions with activity inside `interval`, their events clipped to it.
    func transcripts(in interval: DateInterval) -> CodingAgentReadResult
    /// The same, reusing what earlier scans parsed: only bytes appended to
    /// a transcript since it was last read are parsed again.
    func transcripts(in interval: DateInterval, cache: CodingAgentParseCache?) -> CodingAgentReadResult
}

extension CodingAgentSessionReader {
    func transcripts(in interval: DateInterval, cache: CodingAgentParseCache?) -> CodingAgentReadResult {
        transcripts(in: interval)
    }

    /// Transcript files that may hold activity inside `interval`: written
    /// since it began, and created before it ended. Skipping by metadata
    /// keeps multi-gigabyte archives out of every scan.
    static func candidateFiles(
        _ urls: [URL], in interval: DateInterval
    ) -> [CodingAgentCandidateFile] {
        urls.compactMap { url in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [
                      .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey,
                  ]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= interval.start
            else { return nil }
            let created = values.creationDate ?? modified
            guard created < interval.end else { return nil }
            return CodingAgentCandidateFile(
                url: url, created: created, modified: modified, size: values.fileSize ?? 0)
        }
    }
}

struct CodingAgentCandidateFile: Sendable {
    var url: URL
    var created: Date
    var modified: Date
    var size: Int
}


/// Reads Claude Code sessions from `~/.claude/projects/<cwd-slug>/<id>.jsonl`.
///
/// Only user prompts, the agent's text replies, tool names and inputs for
/// file edits and shell commands, titles, and PR links are read. Tool
/// results are recognised from their opening bytes and contribute only a
/// timestamp. Subagent sidechains, meta records, and compaction summaries
/// are skipped.
struct ClaudeCodeSessionReader: CodingAgentSessionReader {
    var agent: CodingAgentKind { .claudeCode }
    var root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)) {
        self.root = root
    }

    func transcripts(in interval: DateInterval) -> CodingAgentReadResult {
        transcripts(in: interval, cache: nil)
    }

    func transcripts(in interval: DateInterval, cache: CodingAgentParseCache?) -> CodingAgentReadResult {
        var result = CodingAgentReadResult()
        let projectFolders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        // Top level of each project folder only: subagent transcripts live
        // in per-session subfolders and are not the person's sessions.
        let files = projectFolders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles])) ?? []
        }
        // A fork or resumed session copies earlier records under their
        // original ids. Reading older files first credits that history to
        // the session where it happened.
        let candidates = Self.candidateFiles(files, in: interval).sorted {
            $0.created == $1.created ? $0.url.path < $1.url.path : $0.created < $1.created
        }
        var seenRecords: Set<Int> = []
        var selected: Set<String> = []
        for candidate in candidates {
            selected.insert(candidate.url.path)
            let summary: ClaudeCodeSessionSummary
            do {
                let read = try CodingAgentParseCache.summary(
                    of: candidate, from: interval.start, cache: cache) { ClaudeCodeSessionSummary() }
                summary = read.summary
                if let bytes = read.bytesRead {
                    result.filesRead += 1
                    result.bytesRead += bytes
                }
            } catch {
                result.unreadableFiles.append(candidate.url.path)
                continue
            }
            // De-duplication against other files depends on the whole scan,
            // so it happens here rather than in the cached summary.
            guard var window = summary.transcript(
                sessionID: candidate.url.deletingPathExtension().lastPathComponent, in: interval)
            else { continue }
            window.transcript.events.removeAll { event in event.recordKey.map(seenRecords.contains) == true }
            // A file whose window holds only copies claims nothing.
            guard window.transcript.events.contains(where: { !$0.isAnnotation }) else { continue }
            seenRecords.formUnion(window.recordKeys)
            result.transcripts.append(window.transcript)
        }
        cache?.prune(keeping: selected, under: root)
        return result
    }
}

/// What the Claude Code reader keeps of one session file between scans:
/// each timed record's time, id, and labels, the events those records hold
/// with redundant activity compacted away, and the file's titles. A
/// window's transcript is built from it when a scan reads it.
struct ClaudeCodeSessionSummary: CodingAgentFileSummary {
    struct Record: Sendable {
        var at: Date
        /// The hashed record id, for dropping copies a fork or resumed
        /// session carries. Hashes are per process and never persisted.
        var key: Int?
        /// Index into `labels`, or `-1` for a record naming neither.
        var label: Int32
    }

    /// A folder and branch records ran in. Records naming the same pair
    /// share one copy, so a long session holds each path once.
    struct Label: Equatable, Sendable {
        var workingDirectory: String?
        var branch: String?
    }

    private(set) var records: [Record] = []
    private(set) var labels: [Label] = []
    private(set) var events: [CodingAgentStoredEvent] = []
    /// Checked across the whole file, not just the window: text read from
    /// the library earlier can still be restated in today's replies.
    private(set) var consultedLokalBot = false
    private(set) var title: String?
    private var titles: [String: String] = [:]

    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    mutating func consume(_ lines: CodingAgentJSONLines, retainingFrom start: Date) {
        // A record the file already holds is a copy, with the same time; it
        // counts where it first appears.
        var held = Set(records.lazy.compactMap(\.key))
        func admit(_ id: String?) -> (admitted: Bool, key: Int?) {
            guard let key = id.map(CodingAgentParseCache.recordKey) else { return (true, nil) }
            return (held.insert(key).inserted, key)
        }

        lines.forEach { line in
            // Tool results carry most of the bytes; read only their time.
            if line.prefix(768, contains: #""type":"tool_result""#) {
                guard !line.prefix(768, contains: #""isSidechain":true"#),
                      let at = CodingAgentTimestamp.date(line.stringValue(forKey: "timestamp")),
                      at >= start else { return }
                let admitted = admit(line.stringValue(forKey: "uuid"))
                guard admitted.admitted else { return }
                let record = appendRecord(at: at, key: admitted.key, label: -1)
                events.append(CodingAgentStoredEvent(at: at, kind: .activity, record: record))
                return
            }
            guard let record = line.object(), let type = record["type"] as? String else { return }
            switch type {
            case "custom-title":
                titles["custom"] = record["customTitle"] as? String
            case "agent-name":
                titles["agent"] = record["agentName"] as? String
            case "ai-title":
                titles["ai"] = record["aiTitle"] as? String
            case "summary":
                titles["summary"] = record["summary"] as? String
            case "pr-link":
                if let url = record["prUrl"] as? String,
                   let at = CodingAgentTimestamp.date(record["timestamp"] as? String), at >= start {
                    events.append(CodingAgentStoredEvent(at: at, kind: .pullRequest(url), record: -1))
                }
            case "user", "assistant":
                inspectForLokalBotAccess(record)
                guard record["isSidechain"] as? Bool != true,
                      record["isMeta"] as? Bool != true,
                      record["isCompactSummary"] as? Bool != true,
                      let at = CodingAgentTimestamp.date(record["timestamp"] as? String),
                      at >= start else { return }
                let admitted = admit(record["uuid"] as? String)
                guard admitted.admitted else { return }
                // Each record names the folder and branch it ran in; its
                // events keep them, so a burst is labeled by its own work.
                let workingDirectory = record["cwd"] as? String
                let branch = (record["gitBranch"] as? String).flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 }
                let index = appendRecord(at: at, key: admitted.key, label: labelIndex(workingDirectory, branch))
                let content = (record["message"] as? [String: Any])?["content"]
                if type == "user" {
                    appendPrompt(content, at: at, record: index)
                } else {
                    appendAssistant(content, at: at, record: index, workingDirectory: workingDirectory)
                }
            default:
                break
            }
        }
        let titles = titles
        title = ["custom", "agent", "ai", "summary"].lazy
            .compactMap { titles[$0].flatMap(CodingAgentText.title) }.first
        events = CodingAgentBurstBuilder.compactingActivity(events)
    }

    mutating func trim(before start: Date) {
        guard records.contains(where: { $0.at < start }) || events.contains(where: { $0.at < start })
        else { return }
        var moved = [Int32](repeating: -1, count: records.count)
        var kept: [Record] = []
        for (index, record) in records.enumerated() where record.at >= start {
            moved[index] = Int32(kept.count)
            kept.append(record)
        }
        records = kept
        events = events.compactMap { event in
            guard event.at >= start else { return nil }
            var event = event
            if event.record >= 0 { event.record = moved[Int(event.record)] }
            return event
        }
    }

    /// The session's transcript inside `interval` and the ids of the records
    /// it holds there, or `nil` when the window holds no work.
    func transcript(
        sessionID: String, in interval: DateInterval
    ) -> (transcript: CodingAgentTranscript, recordKeys: Set<Int>)? {
        var transcript = CodingAgentTranscript(
            agent: .claudeCode, sessionID: sessionID, title: title, consultedLokalBot: consultedLokalBot,
            events: [])
        var recordKeys: Set<Int> = []
        // The session is labeled by the first record naming a folder. Files a
        // record without one edited are named relative to it, once it is known.
        var labeledBy = Int32.max
        for (index, record) in records.enumerated() where interval.contains(record.at) {
            if let key = record.key { recordKeys.insert(key) }
            if transcript.workingDirectory == nil, let folder = label(at: record.label)?.workingDirectory {
                transcript.workingDirectory = folder
                labeledBy = Int32(index)
            }
        }
        let sessionFolder = transcript.workingDirectory
        transcript.events = events.compactMap { stored in
            guard interval.contains(stored.at) else { return nil }
            guard stored.record >= 0 else { return CodingAgentEvent(at: stored.at, kind: stored.kind) }
            let record = records[Int(stored.record)]
            let named = label(at: record.label)
            var kind = stored.kind
            if named?.workingDirectory == nil, case .fileChange(let path) = kind {
                kind = .fileChange(CodingAgentText.displayPath(
                    path, workingDirectory: labeledBy < stored.record ? sessionFolder : nil))
            }
            return CodingAgentEvent(
                at: stored.at, kind: kind, recordKey: record.key,
                workingDirectory: named?.workingDirectory, branch: named?.branch)
        }
        guard transcript.events.contains(where: { !$0.isAnnotation }) else { return nil }
        return (transcript, recordKeys)
    }

    private func label(at index: Int32) -> Label? {
        index >= 0 ? labels[Int(index)] : nil
    }

    private mutating func labelIndex(_ workingDirectory: String?, _ branch: String?) -> Int32 {
        guard workingDirectory != nil || branch != nil else { return -1 }
        let label = Label(workingDirectory: workingDirectory, branch: branch)
        if let index = labels.lastIndex(of: label) { return Int32(index) }
        labels.append(label)
        return Int32(labels.count - 1)
    }

    private mutating func appendRecord(at: Date, key: Int?, label: Int32) -> Int32 {
        records.append(Record(at: at, key: key, label: label))
        return Int32(records.count - 1)
    }

    private mutating func append(_ kind: CodingAgentEvent.Kind, at: Date, record: Int32) {
        events.append(CodingAgentStoredEvent(at: at, kind: kind, record: record))
    }

    private mutating func appendPrompt(_ content: Any?, at: Date, record: Int32) {
        let raw: String
        if let text = content as? String {
            raw = text
        } else if let blocks = content as? [[String: Any]] {
            raw = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return
        }
        if let prompt = CodingAgentText.prompt(raw) {
            append(.prompt(prompt), at: at, record: record)
        } else {
            append(.activity, at: at, record: record)
        }
        // A command the person ran in the agent's terminal mode is theirs,
        // and still work in this session.
        if let command = CodingAgentText.terminalCommand(in: raw) {
            for action in CodingAgentText.actions(inCommand: command) {
                append(.action(action), at: at, record: record)
            }
        }
    }

    /// An edited file is named relative to the record's folder. A record
    /// without one keeps the path as written, named when a window is read.
    private mutating func appendAssistant(
        _ content: Any?, at: Date, record: Int32, workingDirectory: String?
    ) {
        guard let blocks = content as? [[String: Any]] else { return }
        var appended = false
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, let reply = CodingAgentText.reply(text) {
                    append(.reply(reply), at: at, record: record)
                    appended = true
                }
            case "tool_use":
                appended = true
                append(.toolCall, at: at, record: record)
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                if Self.editTools.contains(name),
                   let path = (input["file_path"] ?? input["notebook_path"]) as? String {
                    let named = workingDirectory.map { CodingAgentText.displayPath(path, workingDirectory: $0) }
                    append(.fileChange(named ?? path), at: at, record: record)
                } else if name == "Bash", let command = input["command"] as? String {
                    for action in CodingAgentText.actions(inCommand: command) {
                        append(.action(action), at: at, record: record)
                    }
                    for url in CodingAgentText.pullRequestURLs(in: command) {
                        append(.pullRequest(url), at: at, record: record)
                    }
                }
            default:
                break
            }
        }
        if !appended { append(.activity, at: at, record: record) }
    }

    private mutating func inspectForLokalBotAccess(_ record: [String: Any]) {
        guard !consultedLokalBot, record["type"] as? String == "assistant",
              let blocks = (record["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return }
        for block in blocks where block["type"] as? String == "tool_use" {
            let name = block["name"] as? String ?? ""
            let command = (block["input"] as? [String: Any])?["command"] as? String ?? ""
            if CodingAgentText.readsLokalBot(toolName: name)
                || (name == "Bash" && CodingAgentText.readsLokalBot(command: command)) {
                consultedLokalBot = true
                return
            }
        }
    }
}
