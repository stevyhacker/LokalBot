import Foundation

struct CodingAgentSessionKey: Hashable, Sendable {
    var agent: CodingAgentKind
    var sessionID: String
}

struct CodingAgentReadResult: Sendable {
    var transcripts: [CodingAgentTranscript] = []
    var claimedSessions: Set<CodingAgentSessionKey> = []
    var filesRead = 0
    var bytesRead = 0
    var unreadableFiles: [String] = []
}

protocol CodingAgentSessionReader: Sendable {
    var agent: CodingAgentKind { get }
    func transcripts(in interval: DateInterval) -> CodingAgentReadResult
    func transcripts(in interval: DateInterval, cache: CodingAgentParseCache?) -> CodingAgentReadResult
}

extension CodingAgentSessionReader {
    func transcripts(in interval: DateInterval, cache: CodingAgentParseCache?) -> CodingAgentReadResult {
        transcripts(in: interval)
    }

    static func candidateFiles(
        _ urls: [URL], in interval: DateInterval, compressedRollouts: Bool = false
    ) -> [CodingAgentCandidateFile] {
        urls.compactMap { url in
            let compressed = compressedRollouts && CodingAgentCompressedTranscript.isCompressed(url)
            guard url.pathExtension == "jsonl" || compressed,
                  let values = try? url.resourceValues(forKeys: [
                      .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey,
                  ]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= interval.start
            else { return nil }
            let created = compressed
                ? min(CodingAgentCompressedTranscript.startBound(of: url), modified)
                : values.creationDate ?? modified
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
        let files = projectFolders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles])) ?? []
        }
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
            guard var window = summary.transcript(
                sessionID: candidate.url.deletingPathExtension().lastPathComponent, in: interval)
            else { continue }
            window.transcript.events.removeAll { event in event.recordKey.map(seenRecords.contains) == true }
            guard window.transcript.events.contains(where: { !$0.isAnnotation }) else { continue }
            seenRecords.formUnion(window.recordKeys)
            result.transcripts.append(window.transcript)
        }
        cache?.prune(keeping: selected, under: root)
        return result
    }
}

struct ClaudeCodeSessionSummary: CodingAgentFileSummary {
    struct Record: Sendable {
        var at: Date
        var key: Int?
        var label: Int32
    }

    struct Label: Equatable, Sendable {
        var workingDirectory: String?
        var branch: String?
    }

    private(set) var records: [Record] = []
    private(set) var labels: [Label] = []
    private(set) var events: [CodingAgentStoredEvent] = []
    private(set) var consultedLokalBot = false
    private(set) var title: String?
    private var titles: [String: String] = [:]

    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    mutating func consume(_ lines: CodingAgentJSONLines, retainingFrom start: Date) {
        var held = Set(records.lazy.compactMap(\.key))
        func admit(_ id: String?) -> (admitted: Bool, key: Int?) {
            guard let key = id.map(CodingAgentParseCache.recordKey) else { return (true, nil) }
            return (held.insert(key).inserted, key)
        }

        lines.forEach { line in
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
        let written = titles
        title = ["custom", "agent", "ai", "summary"].lazy
            .compactMap { written[$0].flatMap(CodingAgentText.title) }.first
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

    func transcript(
        sessionID: String, in interval: DateInterval
    ) -> (transcript: CodingAgentTranscript, recordKeys: Set<Int>)? {
        var transcript = CodingAgentTranscript(
            agent: .claudeCode, sessionID: sessionID, title: title, consultedLokalBot: consultedLokalBot,
            events: [])
        var recordKeys: Set<Int> = []
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
        if let command = CodingAgentText.terminalCommand(in: raw) {
            for action in CodingAgentText.actions(inCommand: command) {
                append(.action(action), at: at, record: record)
            }
        }
    }

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
