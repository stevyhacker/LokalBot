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
    /// The same, reusing files parsed by an earlier scan of `interval`.
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

struct CodingAgentCandidateFile {
    var url: URL
    var created: Date
    var modified: Date
    var size: Int
}

/// Parsed transcripts from an earlier scan, reused while a file's size and
/// modification date are unchanged. A refresh then parses only the sessions
/// still being written instead of every file touched in the window.
final class CodingAgentParseCache: @unchecked Sendable {
    struct Entry: Sendable {
        var size: Int
        var modified: Date
        /// `nil` when the file holds no session of the person's in the
        /// window, such as a subagent thread.
        var transcript: CodingAgentTranscript?
        /// Every record id the file holds in the window, hashed, so a fork
        /// read later can drop the copies it carries.
        var recordKeys: Set<Int>
    }

    private let lock = NSLock()
    private var interval: DateInterval?
    private var entries: [String: Entry] = [:]

    func entry(for file: CodingAgentCandidateFile, interval: DateInterval) -> Entry? {
        lock.withLock {
            guard self.interval == interval, let entry = entries[file.url.path],
                  entry.size == file.size, entry.modified == file.modified else { return nil }
            return entry
        }
    }

    /// A new window replaces every entry: clipping depends on it.
    func store(_ entry: Entry, for file: CodingAgentCandidateFile, interval: DateInterval) {
        lock.withLock {
            if self.interval != interval {
                entries = [:]
                self.interval = interval
            }
            entries[file.url.path] = entry
        }
    }

    /// Forget files under `root` that a scan of `interval` no longer selected.
    func prune(keeping paths: Set<String>, under root: URL, interval: DateInterval) {
        let prefix = root.path + "/"
        lock.withLock {
            guard self.interval == interval else { return }
            entries = entries.filter { !$0.key.hasPrefix(prefix) || paths.contains($0.key) }
        }
    }

    static func recordKey(_ id: String) -> Int {
        var hasher = Hasher()
        hasher.combine(id)
        return hasher.finalize()
    }
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

    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

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
            let entry: CodingAgentParseCache.Entry
            if let cached = cache?.entry(for: candidate, interval: interval) {
                entry = cached
            } else {
                do {
                    let lines = try CodingAgentJSONLines(contentsOf: candidate.url)
                    result.filesRead += 1
                    result.bytesRead += candidate.size
                    let parsed = parse(
                        lines, sessionID: candidate.url.deletingPathExtension().lastPathComponent,
                        interval: interval)
                    entry = .init(size: candidate.size, modified: candidate.modified,
                                  transcript: parsed.transcript, recordKeys: parsed.recordKeys)
                    cache?.store(entry, for: candidate, interval: interval)
                } catch {
                    result.unreadableFiles.append(candidate.url.path)
                    continue
                }
            }
            guard var transcript = entry.transcript else { continue }
            transcript.events.removeAll { event in event.recordKey.map(seenRecords.contains) == true }
            // A file whose window holds only copies claims nothing.
            guard transcript.events.contains(where: { !$0.isAnnotation }) else { continue }
            seenRecords.formUnion(entry.recordKeys)
            result.transcripts.append(transcript)
        }
        cache?.prune(keeping: selected, under: root, interval: interval)
        return result
    }

    /// One file's transcript before de-duplication against other files,
    /// which depends on the whole scan and so happens after caching.
    func parse(
        _ lines: CodingAgentJSONLines,
        sessionID: String,
        interval: DateInterval
    ) -> (transcript: CodingAgentTranscript?, recordKeys: Set<Int>) {
        var transcript = CodingAgentTranscript(agent: .claudeCode, sessionID: sessionID, events: [])
        var titles: [String: String] = [:]
        var recordKeys: Set<Int> = []

        /// The record's key, or `nil` for a record this file already held.
        func admit(_ id: String?) -> Int?? {
            guard let id else { return .some(nil) }
            let key = CodingAgentParseCache.recordKey(id)
            return recordKeys.insert(key).inserted ? .some(key) : nil
        }

        lines.forEach { line in
            // Tool results carry most of the bytes; read only their time.
            if line.prefix(768, contains: #""type":"tool_result""#) {
                guard !line.prefix(768, contains: #""isSidechain":true"#),
                      let at = CodingAgentTimestamp.date(line.stringValue(forKey: "timestamp")),
                      interval.contains(at),
                      let key = admit(line.stringValue(forKey: "uuid")) else { return }
                transcript.events.append(CodingAgentEvent(at: at, kind: .activity, recordKey: key))
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
                   let at = CodingAgentTimestamp.date(record["timestamp"] as? String),
                   interval.contains(at) {
                    transcript.events.append(CodingAgentEvent(at: at, kind: .pullRequest(url)))
                }
            case "user", "assistant":
                inspectForLokalBotAccess(record, transcript: &transcript)
                guard record["isSidechain"] as? Bool != true,
                      record["isMeta"] as? Bool != true,
                      record["isCompactSummary"] as? Bool != true,
                      let at = CodingAgentTimestamp.date(record["timestamp"] as? String),
                      interval.contains(at),
                      let key = admit(record["uuid"] as? String) else { return }
                // Each record names the folder and branch it ran in; its
                // events keep them, so a burst is labeled by its own work.
                let workingDirectory = record["cwd"] as? String
                if transcript.workingDirectory == nil {
                    transcript.workingDirectory = workingDirectory
                }
                let branch = (record["gitBranch"] as? String).flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 }
                let content = (record["message"] as? [String: Any])?["content"]
                let firstNew = transcript.events.count
                if type == "user" {
                    appendPrompt(content, at: at, to: &transcript)
                } else {
                    appendAssistant(
                        content, at: at, workingDirectory: workingDirectory ?? transcript.workingDirectory,
                        to: &transcript)
                }
                for index in firstNew..<transcript.events.count {
                    transcript.events[index].recordKey = key
                    transcript.events[index].workingDirectory = workingDirectory
                    transcript.events[index].branch = branch
                }
            default:
                break
            }
        }

        transcript.title = ["custom", "agent", "ai", "summary"].lazy
            .compactMap { titles[$0].flatMap(CodingAgentText.title) }.first
        transcript.events = CodingAgentBurstBuilder.compactingActivity(transcript.events)
        guard transcript.events.contains(where: { !$0.isAnnotation }) else {
            return (nil, recordKeys)
        }
        return (transcript, recordKeys)
    }

    private func appendPrompt(_ content: Any?, at: Date, to transcript: inout CodingAgentTranscript) {
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
            transcript.events.append(CodingAgentEvent(at: at, kind: .prompt(prompt)))
        } else {
            transcript.events.append(CodingAgentEvent(at: at, kind: .activity))
        }
        // A command the person ran in the agent's terminal mode is theirs,
        // and still work in this session.
        if let command = CodingAgentText.terminalCommand(in: raw) {
            for action in CodingAgentText.actions(inCommand: command) {
                transcript.events.append(CodingAgentEvent(at: at, kind: .action(action)))
            }
        }
    }

    private func appendAssistant(
        _ content: Any?, at: Date, workingDirectory: String?, to transcript: inout CodingAgentTranscript
    ) {
        guard let blocks = content as? [[String: Any]] else { return }
        var appended = false
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, let reply = CodingAgentText.reply(text) {
                    transcript.events.append(CodingAgentEvent(at: at, kind: .reply(reply)))
                    appended = true
                }
            case "tool_use":
                appended = true
                transcript.events.append(CodingAgentEvent(at: at, kind: .toolCall))
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                if Self.editTools.contains(name),
                   let path = (input["file_path"] ?? input["notebook_path"]) as? String {
                    transcript.events.append(CodingAgentEvent(
                        at: at,
                        kind: .fileChange(CodingAgentText.displayPath(
                            path, workingDirectory: workingDirectory))))
                } else if name == "Bash", let command = input["command"] as? String {
                    for action in CodingAgentText.actions(inCommand: command) {
                        transcript.events.append(CodingAgentEvent(at: at, kind: .action(action)))
                    }
                    for url in CodingAgentText.pullRequestURLs(in: command) {
                        transcript.events.append(CodingAgentEvent(at: at, kind: .pullRequest(url)))
                    }
                }
            default:
                break
            }
        }
        if !appended { transcript.events.append(CodingAgentEvent(at: at, kind: .activity)) }
    }

    /// Checked across the whole file, not just the day: text read from the
    /// library earlier can still be restated in today's replies.
    private func inspectForLokalBotAccess(_ record: [String: Any], transcript: inout CodingAgentTranscript) {
        guard !transcript.consultedLokalBot, record["type"] as? String == "assistant",
              let blocks = (record["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return }
        for block in blocks where block["type"] as? String == "tool_use" {
            let name = block["name"] as? String ?? ""
            let command = (block["input"] as? [String: Any])?["command"] as? String ?? ""
            if CodingAgentText.readsLokalBot(toolName: name)
                || (name == "Bash" && CodingAgentText.readsLokalBot(command: command)) {
                transcript.consultedLokalBot = true
                return
            }
        }
    }
}
