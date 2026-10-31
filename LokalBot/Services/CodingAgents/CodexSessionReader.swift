import Foundation

/// Reads Codex rollouts from `~/.codex/sessions/YYYY/MM/DD/*.jsonl` and
/// `~/.codex/archived_sessions/`.
///
/// A rollout stays in the folder of the day it started even when it is
/// resumed weeks later, so files are selected by modification date rather
/// than by folder. Subagent threads, including approval reviewers, are
/// skipped: their parent session reports the work. Titles come from
/// `session_index.jsonl`; credentials and the internal SQLite state are
/// never opened.
struct CodexSessionReader: CodingAgentSessionReader {
    var agent: CodingAgentKind { .codex }
    var root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)) {
        self.root = root
    }

    func transcripts(in interval: DateInterval) -> CodingAgentReadResult {
        transcripts(in: interval, cache: nil)
    }

    func transcripts(in interval: DateInterval, cache: CodingAgentParseCache?) -> CodingAgentReadResult {
        var result = CodingAgentReadResult()
        let files = ["sessions", "archived_sessions"].flatMap { folder -> [URL] in
            let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent(folder, isDirectory: true),
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles])
            return (enumerator?.allObjects as? [URL]) ?? []
        }
        let candidates = Self.candidateFiles(files, in: interval).sorted { $0.url.path < $1.url.path }
        var selected: Set<String> = []
        for candidate in candidates {
            selected.insert(candidate.url.path)
            do {
                let read = try CodingAgentParseCache.summary(
                    of: candidate, from: interval.start, cache: cache) { CodexRolloutSummary() }
                if let bytes = read.bytesRead {
                    result.filesRead += 1
                    result.bytesRead += bytes
                }
                if let transcript = read.summary.transcript(in: interval) { result.transcripts.append(transcript) }
            } catch {
                result.unreadableFiles.append(candidate.url.path)
            }
        }
        let index = root.appendingPathComponent("session_index.jsonl")
        selected.insert(index.path)
        cache?.prune(keeping: selected, under: root)
        if !result.transcripts.isEmpty {
            let titles = threadTitles(in: index, cache: cache)
            for index in result.transcripts.indices {
                result.transcripts[index].title = titles[result.transcripts[index].sessionID]
                    .flatMap(CodingAgentText.title)
            }
        }
        return result
    }

    /// Thread names by id; later lines are renames and win.
    private func threadTitles(in index: URL, cache: CodingAgentParseCache?) -> [String: String] {
        let always = DateInterval(start: .distantPast, end: .distantFuture)
        guard let file = Self.candidateFiles([index], in: always).first,
              let read = try? CodingAgentParseCache.summary(
                  of: file, from: .distantPast, cache: cache, empty: { CodexThreadTitles() })
        else { return [:] }
        return read.summary.titles
    }
}

/// What the Codex reader keeps of one rollout between scans: the session's
/// id and labels, and its events with redundant activity compacted away.
struct CodexRolloutSummary: CodingAgentFileSummary {
    private(set) var sessionID = ""
    private(set) var workingDirectory: String?
    private(set) var branch: String?
    private(set) var consultedLokalBot = false
    private(set) var isSubagent = false
    private(set) var events: [CodingAgentStoredEvent] = []

    /// Opening bytes of records that never carry evidence beyond their time.
    private static let timestampOnlyMarkers = [
        #""type":"function_call_output""#, #""type":"custom_tool_call_output""#,
        #""type":"reasoning""#, #""type":"token_count""#, #""type":"token_usage_record""#,
        #""item":{"type":"Reasoning""#, #""item":{"type":"AgentMessage""#,
        #""item":{"type":"UserMessage""#, #""item":{"type":"ImageView""#,
    ]

    mutating func consume(_ lines: CodingAgentJSONLines, retainingFrom start: Date) {
        guard !isSubagent else { return }
        lines.forEach { line in
            guard !isSubagent else { return }
            if Self.timestampOnlyMarkers.contains(where: { line.prefix(400, contains: $0) }) {
                if let at = CodingAgentTimestamp.date(line.stringValue(forKey: "timestamp")), at >= start {
                    append(.activity, at: at)
                }
                return
            }
            guard let record = line.object(),
                  let payload = record["payload"] as? [String: Any] else { return }
            if record["type"] as? String == "session_meta" {
                // A subagent's `source` is an object such as
                // {"subagent":{"other":"guardian"}}; people start "vscode"/"cli".
                if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
                    isSubagent = true
                    events = []
                    return
                }
                sessionID = payload["id"] as? String ?? sessionID
                workingDirectory = payload["cwd"] as? String
                if let git = payload["git"] as? [String: Any],
                   let branch = git["branch"] as? String, !branch.isEmpty, branch != "HEAD" {
                    self.branch = branch
                }
                return
            }
            inspectForLokalBotAccess(record, payload: payload)
            guard let at = CodingAgentTimestamp.date(record["timestamp"] as? String), at >= start else { return }
            let before = events.count
            switch record["type"] as? String {
            case "response_item":
                appendResponseItem(payload, at: at)
            case "event_msg":
                if payload["type"] as? String == "item_completed",
                   let item = payload["item"] as? [String: Any] {
                    appendCompletedItem(item, at: at)
                }
            default:
                break
            }
            if events.count == before { append(.activity, at: at) }
        }
        events = CodingAgentBurstBuilder.compactingActivity(events)
    }

    mutating func trim(before start: Date) {
        events.removeAll { $0.at < start }
    }

    /// The session's transcript inside `interval`, or `nil` for a subagent
    /// thread or a window holding no work.
    func transcript(in interval: DateInterval) -> CodingAgentTranscript? {
        guard !isSubagent, !sessionID.isEmpty else { return nil }
        let inWindow = events.compactMap { stored in
            interval.contains(stored.at) ? CodingAgentEvent(at: stored.at, kind: stored.kind) : nil
        }
        guard inWindow.contains(where: { !$0.isAnnotation }) else { return nil }
        return CodingAgentTranscript(
            agent: .codex, sessionID: sessionID, workingDirectory: workingDirectory, branch: branch,
            consultedLokalBot: consultedLokalBot, events: inWindow)
    }

    private mutating func append(_ kind: CodingAgentEvent.Kind, at: Date) {
        events.append(CodingAgentStoredEvent(at: at, kind: kind, record: -1))
    }

    private mutating func appendResponseItem(_ payload: [String: Any], at: Date) {
        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String
            guard role == "user" || role == "assistant",
                  let content = payload["content"] as? [[String: Any]] else { return }
            // Codex sends injected instructions and context as separate
            // items of the same user message; each is judged on its own.
            let texts = content.compactMap { item -> String? in
                guard ["input_text", "output_text"].contains(item["type"] as? String ?? "") else {
                    return nil
                }
                return item["text"] as? String
            }
            if role == "user" {
                let prompts = texts.compactMap(CodingAgentText.prompt)
                if !prompts.isEmpty {
                    let joined = CodingAgentText.truncated(
                        prompts.joined(separator: " "), maxCharacters: CodingAgentText.promptCharacters)
                    append(.prompt(joined), at: at)
                }
            } else if let reply = CodingAgentText.reply(texts.joined(separator: "\n")) {
                append(.reply(reply), at: at)
            }
        case "function_call", "custom_tool_call":
            append(.toolCall, at: at)
            let body = (payload["arguments"] ?? payload["input"]) as? String ?? ""
            for path in Self.patchedFiles(in: body) {
                append(.fileChange(CodingAgentText.displayPath(path, workingDirectory: workingDirectory)), at: at)
            }
            if let command = Self.shellCommand(inArguments: body) {
                for action in CodingAgentText.actions(inCommand: command) {
                    append(.action(action), at: at)
                }
            }
            for url in CodingAgentText.pullRequestURLs(in: body) {
                append(.pullRequest(url), at: at)
            }
        default:
            break
        }
    }

    private mutating func appendCompletedItem(_ item: [String: Any], at: Date) {
        switch item["type"] as? String {
        case "CommandExecution":
            // Only the command; `aggregated_output` and friends are never read.
            guard let command = Self.command(in: item) else { return }
            for action in CodingAgentText.actions(inCommand: command) {
                append(.action(action), at: at)
            }
            for url in CodingAgentText.pullRequestURLs(in: command) {
                append(.pullRequest(url), at: at)
            }
        case "FileChange":
            // `changes` maps each path to its diff; only the keys are used.
            guard let changes = item["changes"] as? [String: Any] else { return }
            for path in changes.keys.sorted() {
                append(.fileChange(CodingAgentText.displayPath(path, workingDirectory: workingDirectory)), at: at)
            }
        default:
            break
        }
    }

    /// A completed command as the shell ran it. Codex records the argv as an
    /// array such as `["/bin/zsh", "-lc", "git push"]`; the script is last.
    private static func command(in item: [String: Any]) -> String? {
        if let argv = item["command"] as? [String] { return argv.last }
        return item["command"] as? String
    }

    /// `apply_patch` names each file on a header line.
    private static func patchedFiles(in body: String) -> [String] {
        guard body.contains("*** ") else { return [] }
        return body.components(separatedBy: "\n").compactMap { line in
            for header in ["*** Update File: ", "*** Add File: "] where line.hasPrefix(header) {
                return String(line.dropFirst(header.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    /// Shell tools pass JSON arguments with `cmd` (string) or `command`
    /// (string or argv).
    private static func shellCommand(inArguments body: String) -> String? {
        guard body.hasPrefix("{"), let data = body.data(using: .utf8),
              let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let command = (arguments["cmd"] ?? arguments["command"]) as? String { return command }
        return (arguments["command"] as? [String])?.last
    }

    private mutating func inspectForLokalBotAccess(_ record: [String: Any], payload: [String: Any]) {
        guard !consultedLokalBot else { return }
        let item = payload["item"] as? [String: Any]
        let server = item?["server"] as? String ?? ""
        let name = payload["name"] as? String ?? ""
        let command = item.flatMap(Self.command(in:))
            ?? Self.shellCommand(inArguments: (payload["arguments"] ?? payload["input"]) as? String ?? "")
            ?? ""
        if CodingAgentText.readsLokalBot(toolName: server)
            || CodingAgentText.readsLokalBot(toolName: name)
            || CodingAgentText.readsLokalBot(command: CodingAgentText.unwrappedShellCommand(command)) {
            consultedLokalBot = true
        }
    }
}

/// Thread names by id from `session_index.jsonl`; later lines are renames
/// and win, so appended lines fold into the names already read.
struct CodexThreadTitles: CodingAgentFileSummary {
    private(set) var titles: [String: String] = [:]

    mutating func consume(_ lines: CodingAgentJSONLines, retainingFrom start: Date) {
        lines.forEach { line in
            guard let record = line.object(), let id = record["id"] as? String,
                  let name = record["thread_name"] as? String, !name.isEmpty else { return }
            titles[id] = name
        }
    }

    mutating func trim(before start: Date) {}
}
