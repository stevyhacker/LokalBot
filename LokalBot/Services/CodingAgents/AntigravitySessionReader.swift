import Foundation

/// Reads Antigravity sessions from `~/.gemini/antigravity/brain`,
/// `~/.gemini/antigravity-cli/brain`, and `~/.gemini/antigravity-ide/brain`,
/// plus sibling `annotations/<id>.pbtxt` files for conversation titles.
///
/// Only `transcript.jsonl` (never `transcript_full.jsonl`), user prompts,
/// assistant text replies, and tool call inputs for file edits, shell commands,
/// and PR tools are read. Reasoning (`thinking`), tool output, file contents,
/// credentials, settings, and databases are never opened or kept.
struct AntigravitySessionReader: CodingAgentSessionReader {
    var agent: CodingAgentKind { .antigravity }
    /// Antigravity state folders, each holding `brain/` and `annotations/`.
    var roots: [URL]

    static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AntigravitySessionReader {
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        return AntigravitySessionReader(roots: [
            gemini.appendingPathComponent("antigravity", isDirectory: true),
            gemini.appendingPathComponent("antigravity-cli", isDirectory: true),
            gemini.appendingPathComponent("antigravity-ide", isDirectory: true),
        ])
    }

    init(roots: [URL]) {
        self.roots = roots
    }

    init(root: URL) {
        self.roots = [root]
    }

    func transcripts(in interval: DateInterval) -> CodingAgentReadResult {
        transcripts(in: interval, cache: nil)
    }

    func transcripts(in interval: DateInterval, cache: CodingAgentParseCache?) -> CodingAgentReadResult {
        var result = CodingAgentReadResult()
        // Deduplicate by conversation id across antigravity / -cli / -ide:
        // the copy written last wins so the same session is never read twice.
        var chosen: [String: (candidate: CodingAgentCandidateFile, root: URL)] = [:]
        for root in roots {
            let brain = root.appendingPathComponent("brain", isDirectory: true)
            let conversations = (try? FileManager.default.contentsOfDirectory(
                at: brain, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            var files: [URL] = []
            for conversation in conversations {
                guard (try? conversation.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                    continue
                }
                let transcript = conversation
                    .appendingPathComponent(".system_generated", isDirectory: true)
                    .appendingPathComponent("logs", isDirectory: true)
                    .appendingPathComponent("transcript.jsonl")
                files.append(transcript)
            }
            for candidate in Self.candidateFiles(files, in: interval) {
                let id = Self.conversationID(of: candidate.url)
                guard !id.isEmpty else { continue }
                if let existing = chosen[id], existing.candidate.modified >= candidate.modified { continue }
                chosen[id] = (candidate, root)
            }
        }

        let ordered = chosen.sorted { $0.value.candidate.url.path < $1.value.candidate.url.path }
        var selected: Set<String> = []
        for (conversationID, entry) in ordered {
            selected.insert(entry.candidate.url.path)
            do {
                let read = try CodingAgentParseCache.summary(
                    of: entry.candidate, from: interval.start, cache: cache
                ) { AntigravitySessionSummary() }
                if let bytes = read.bytesRead {
                    result.filesRead += 1
                    result.bytesRead += bytes
                }
                if var transcript = read.summary.transcript(sessionID: conversationID, in: interval) {
                    if let title = Self.annotationTitle(for: conversationID, under: entry.root) {
                        transcript.title = title
                    }
                    result.transcripts.append(transcript)
                }
            } catch {
                result.unreadableFiles.append(entry.candidate.url.path)
            }
        }
        for root in roots {
            cache?.prune(keeping: selected, under: root)
        }
        return result
    }

    private static func conversationID(of transcriptURL: URL) -> String {
        // .../<root>/brain/<id>/.system_generated/logs/transcript.jsonl
        transcriptURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .lastPathComponent
    }

    /// Reads the `title: "..."` field from `<root>/annotations/<id>.pbtxt`.
    static func annotationTitle(for conversationID: String, under root: URL) -> String? {
        let file = root
            .appendingPathComponent("annotations", isDirectory: true)
            .appendingPathComponent("\(conversationID).pbtxt")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1_024),
              let contents = String(data: data, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("title:") else { continue }
            let rest = trimmed.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
            guard let decoded = decodeJSONStringLiteral(rest) else { continue }
            return CodingAgentText.title(decoded)
        }
        return nil
    }

    /// Decodes a JSON/pbtxt quoted string literal such as `"Fix \"bug\""`.
    static func decodeJSONStringLiteral(_ raw: String) -> String? {
        guard raw.count >= 2, raw.first == "\"", raw.last == "\"" else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
    }
}

/// What the Antigravity reader keeps of one transcript file between scans:
/// per-record working directories, compacted events, and whether the session
/// consulted LokalBot's library.
struct AntigravitySessionSummary: CodingAgentFileSummary {
    struct Record: Sendable {
        var at: Date
        /// Index into `workingDirectories`, or `-1` for none.
        var directory: Int32
    }

    private(set) var records: [Record] = []
    private(set) var workingDirectories: [String] = []
    private(set) var events: [CodingAgentStoredEvent] = []
    private(set) var consultedLokalBot = false
    private var currentWorkingDirectory: String?
    private var hasExplicitCwd = false

    private static let maxLineBytes = 16 * 1024 * 1024
    private static let editTools: Set<String> = [
        "write_file", "edit_file", "write_to_file",
        "replace_file_content", "multi_replace_file_content",
        "Write", "Edit", "MultiEdit",
    ]
    private static let shellTools: Set<String> = ["run_command", "bash", "shell", "Bash"]

    private static let interestingTypeMarkers: [Data] = [
        Data(#""type":"USER_INPUT""#.utf8),
        Data(#""type": "USER_INPUT""#.utf8),
        Data(#""type":"PLANNER_RESPONSE""#.utf8),
        Data(#""type": "PLANNER_RESPONSE""#.utf8),
    ]

    mutating func consume(_ lines: CodingAgentJSONLines, retainingFrom start: Date) {
        lines.forEach { line in
            let interesting = line.bytes.count <= Self.maxLineBytes
                && Self.interestingTypeMarkers.contains { line.bytes.range(of: $0) != nil }
            if !interesting {
                if let at = Self.fastTimestamp(line), at >= start {
                    let index = appendRecord(at: at, directory: directoryIndex(currentWorkingDirectory))
                    events.append(CodingAgentStoredEvent(at: at, kind: .activity, record: index))
                }
                return
            }
            guard let record = line.object(),
                  let type = record["type"] as? String else { return }
            if type == "PLANNER_RESPONSE" {
                inspectForLokalBotAccess(record)
            }
            guard let at = CodingAgentTimestamp.date(record["created_at"] as? String),
                  at >= start else { return }
            switch type {
            case "USER_INPUT":
                let index = appendRecord(at: at, directory: directoryIndex(currentWorkingDirectory))
                if record["source"] as? String == "SYSTEM" {
                    append(.activity, at: at, record: index)
                    return
                }
                if let raw = record["content"] as? String, let prompt = CodingAgentText.prompt(raw) {
                    append(.prompt(prompt), at: at, record: index)
                } else {
                    append(.activity, at: at, record: index)
                }
            case "PLANNER_RESPONSE":
                appendPlannerResponse(record, at: at)
            default:
                break
            }
        }
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

    func transcript(sessionID: String, in interval: DateInterval) -> CodingAgentTranscript? {
        var transcript = CodingAgentTranscript(
            agent: .antigravity, sessionID: sessionID, title: nil,
            consultedLokalBot: consultedLokalBot, events: [])
        var labeledBy = Int32.max
        for (index, record) in records.enumerated() where interval.contains(record.at) {
            if transcript.workingDirectory == nil, let folder = directory(at: record.directory) {
                transcript.workingDirectory = folder
                labeledBy = Int32(index)
            }
        }
        let sessionFolder = transcript.workingDirectory
        transcript.events = events.compactMap { stored in
            guard interval.contains(stored.at) else { return nil }
            guard stored.record >= 0 else { return CodingAgentEvent(at: stored.at, kind: stored.kind) }
            let record = records[Int(stored.record)]
            let folder = directory(at: record.directory)
            var kind = stored.kind
            if folder == nil, case .fileChange(let path) = kind {
                kind = .fileChange(CodingAgentText.displayPath(
                    path, workingDirectory: labeledBy < stored.record ? sessionFolder : nil))
            }
            return CodingAgentEvent(at: stored.at, kind: kind, workingDirectory: folder)
        }
        guard transcript.events.contains(where: { !$0.isAnnotation }) else { return nil }
        return transcript
    }

    private mutating func appendPlannerResponse(_ record: [String: Any], at: Date) {
        let toolCalls = record["tool_calls"] as? [[String: Any]] ?? []
        // Update working directory from this response's tool calls before
        // labeling the record, so file changes and replies on this step carry it.
        for call in toolCalls {
            let name = call["name"] as? String ?? ""
            let args = call["args"] as? [String: Any] ?? [:]
            updateWorkingDirectory(toolName: name, args: args)
        }
        let workingDirectory = currentWorkingDirectory
        let index = appendRecord(at: at, directory: directoryIndex(workingDirectory))
        var appended = false

        // Never read `thinking`: reasoning stays private.
        if let content = record["content"] as? String, let reply = CodingAgentText.reply(content) {
            append(.reply(reply), at: at, record: index)
            appended = true
        }
        for call in toolCalls {
            appended = true
            append(.toolCall, at: at, record: index)
            let name = call["name"] as? String ?? ""
            let args = call["args"] as? [String: Any] ?? [:]
            if Self.editTools.contains(name),
               let path = Self.stringArg(args, keys: ["Path", "TargetFile", "file_path", "path"]),
               !Self.isInternalArtifactPath(path) {
                let named = workingDirectory.map { CodingAgentText.displayPath(path, workingDirectory: $0) }
                append(.fileChange(named ?? path), at: at, record: index)
            } else if Self.shellTools.contains(name),
                      let command = Self.commandArg(args) {
                for action in CodingAgentText.actions(inCommand: command) {
                    append(.action(action), at: at, record: index)
                }
                for url in CodingAgentText.pullRequestURLs(in: command) {
                    append(.pullRequest(url), at: at, record: index)
                }
            } else {
                let prEvents = CodingAgentText.pullRequestEvents(
                    toolName: name,
                    title: Self.stringArg(args, keys: ["title"]),
                    number: Self.intArg(args, keys: ["number"]),
                    url: Self.stringArg(args, keys: ["url"]),
                    urls: Self.stringArrayArg(args, keys: ["urls"]))
                for kind in prEvents {
                    append(kind, at: at, record: index)
                }
            }
        }
        if !appended { append(.activity, at: at, record: index) }
    }

    private mutating func updateWorkingDirectory(toolName: String, args: [String: Any]) {
        if Self.shellTools.contains(toolName),
           let cwd = Self.stringArg(args, keys: ["Cwd", "cwd"]),
           let valid = Self.usableCwd(cwd) {
            currentWorkingDirectory = valid
            hasExplicitCwd = true
            return
        }
        guard !hasExplicitCwd else { return }
        if let dir = Self.stringArg(args, keys: ["DirectoryPath", "SearchPath"]),
           let inferred = CodingAgentText.inferredProjectDirectory(for: dir, isDirectory: true) {
            currentWorkingDirectory = currentWorkingDirectory ?? inferred
            return
        }
        if let path = Self.stringArg(args, keys: ["Path", "TargetFile", "AbsolutePath", "file_path", "path"]),
           let inferred = CodingAgentText.inferredProjectDirectory(for: path, isDirectory: false) {
            currentWorkingDirectory = currentWorkingDirectory ?? inferred
        }
    }

    private mutating func inspectForLokalBotAccess(_ record: [String: Any]) {
        guard !consultedLokalBot, let toolCalls = record["tool_calls"] as? [[String: Any]] else { return }
        for call in toolCalls {
            let name = call["name"] as? String ?? ""
            let args = call["args"] as? [String: Any] ?? [:]
            if CodingAgentText.readsLokalBot(toolName: name) {
                consultedLokalBot = true
                return
            }
            if Self.shellTools.contains(name),
               let command = Self.commandArg(args),
               CodingAgentText.readsLokalBot(command: command) {
                consultedLokalBot = true
                return
            }
        }
    }

    private func directory(at index: Int32) -> String? {
        index >= 0 ? workingDirectories[Int(index)] : nil
    }

    private mutating func directoryIndex(_ value: String?) -> Int32 {
        guard let value, !value.isEmpty else { return -1 }
        if let index = workingDirectories.lastIndex(of: value) { return Int32(index) }
        workingDirectories.append(value)
        return Int32(workingDirectories.count - 1)
    }

    private mutating func appendRecord(at: Date, directory: Int32) -> Int32 {
        records.append(Record(at: at, directory: directory))
        return Int32(records.count - 1)
    }

    private mutating func append(_ kind: CodingAgentEvent.Kind, at: Date, record: Int32) {
        events.append(CodingAgentStoredEvent(at: at, kind: kind, record: record))
    }

    private static func fastTimestamp(_ line: CodingAgentJSONLines.Line) -> Date? {
        if let value = line.stringValue(forKey: "created_at") {
            return CodingAgentTimestamp.date(value)
        }
        guard line.bytes.count <= 65_536,
              let keyRange = line.bytes.range(of: Data("\"created_at\": \"".utf8)) else { return nil }
        let start = keyRange.upperBound
        guard let end = line.bytes[start...].firstIndex(of: 0x22),
              let value = String(data: line.bytes[start..<end], encoding: .utf8) else { return nil }
        return CodingAgentTimestamp.date(value)
    }

    /// Antigravity encodes tool-call argument values as JSON literals inside
    /// strings (e.g. `"\"/path/to/file\""`), though plain strings also appear.
    private static func unquoteArg(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        if text.count >= 2, text.first == "\"", text.last == "\"",
           let decoded = AntigravitySessionReader.decodeJSONStringLiteral(text) {
            return decoded
        }
        return text
    }

    private static func stringArg(_ args: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = unquoteArg(args[key]), !value.isEmpty { return value }
        }
        return nil
    }

    private static func intArg(_ args: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = args[key] as? Int { return value }
            if let text = unquoteArg(args[key]), let value = Int(text.trimmingCharacters(in: .whitespaces)) {
                return value
            }
        }
        return nil
    }

    private static func stringArrayArg(_ args: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            if let list = args[key] as? [String] { return list }
            if let text = args[key] as? String, text.hasPrefix("["),
               let list = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) {
                return list
            }
        }
        return []
    }

    private static func commandArg(_ args: [String: Any]) -> String? {
        if let text = stringArg(args, keys: ["CommandLine", "command", "cmd"]) { return text }
        if let argv = args["command"] as? [String] { return argv.last }
        return nil
    }

    private static func usableCwd(_ cwd: String) -> String? {
        let normalized = (cwd as NSString).standardizingPath
        let lowered = normalized.lowercased()
        guard !lowered.contains("/.gemini/"), !lowered.contains("/.t3/userdata/") else { return nil }
        return normalized
    }

    private static func isInternalArtifactPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.contains("/.system_generated/")
            || lowered.contains("/.gemini/antigravity")
            || lowered.contains("/.t3/userdata/")
    }
}
