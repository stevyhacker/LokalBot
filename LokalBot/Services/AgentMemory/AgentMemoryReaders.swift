import Foundation

/// Reads the notes one coding agent keeps for itself.
protocol AgentMemoryReader: Sendable {
    var agent: CodingAgentKind { get }
    func scan(excluding exclusions: AgentMemoryExclusions) -> AgentMemoryScan
}

/// Collects notes from every enabled agent.
struct AgentMemoryScanner: Sendable {
    var readers: [any AgentMemoryReader]
    var exclusions = AgentMemoryExclusions()

    static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        agents: Set<CodingAgentKind> = Set(CodingAgentKind.allCases),
        excludedFolders: [String] = []
    ) -> AgentMemoryScanner {
        let readers: [any AgentMemoryReader] = CodingAgentKind.allCases
            .filter(agents.contains)
            .map { agent in
                switch agent {
                case .claudeCode:
                    ClaudeCodeMemoryReader(
                        root: home.appendingPathComponent(".claude/projects", isDirectory: true))
                case .codex:
                    CodexMemoryReader(
                        root: home.appendingPathComponent(".codex/memories", isDirectory: true))
                }
            }
        return AgentMemoryScanner(readers: readers, exclusions: AgentMemoryExclusions(folders: excludedFolders))
    }

    func scan() -> AgentMemoryScan {
        var scan = AgentMemoryScan()
        for reader in readers { scan.merge(reader.scan(excluding: exclusions)) }
        scan.notes.sort { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.id < rhs.id
        }
        return scan
    }
}

/// Reads Claude Code's notes from `~/.claude/projects/<cwd-slug>/memory/*.md`.
///
/// Each note is one Markdown file with a short header (name, description,
/// type). `MEMORY.md` is the folder's index of those files: it supplies
/// titles and is not a note itself. Nothing else in a project folder is read
/// except the opening of one session file, for the folder's real path.
struct ClaudeCodeMemoryReader: AgentMemoryReader {
    var agent: CodingAgentKind { .claudeCode }
    var root: URL

    static let indexFileName = "MEMORY.md"
    /// How much of a session file is read to find its working directory.
    static let sessionPeekBytes = 256 * 1_024

    func scan(excluding exclusions: AgentMemoryExclusions) -> AgentMemoryScan {
        var scan = AgentMemoryScan()
        let manager = FileManager.default
        let projects = ((try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for project in projects {
            let folder = project.appendingPathComponent("memory", isDirectory: true)
            let files = ((try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension.lowercased() == "md" && $0.lastPathComponent != Self.indexFileName }
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !files.isEmpty else { continue }
            let slug = project.lastPathComponent
            let workingDirectory = Self.workingDirectory(ofProject: project)
            guard !exclusions.excludes(claudeProjectSlug: slug),
                  !exclusions.excludes(workingDirectory: workingDirectory) else {
                scan.excludedNotes += files.count
                continue
            }
            let titles = Self.indexTitles(folder.appendingPathComponent(Self.indexFileName))
            for file in files {
                guard scan.notes.count < AgentMemoryText.maxNotesPerAgent else { return scan }
                switch AgentMemoryText.contents(of: file) {
                case .failure(.tooLarge): continue
                case .failure(.unreadable): scan.unreadableFiles.append(file.path)
                case .success(let contents):
                    scan.filesRead += 1
                    let relative = "\(slug)/memory/\(file.lastPathComponent)"
                    if let note = Self.note(
                        contents: contents, file: file, relativePath: relative,
                        indexTitle: titles[file.lastPathComponent], workingDirectory: workingDirectory) {
                        scan.notes.append(note)
                    }
                }
            }
        }
        return scan
    }

    static func note(
        contents: String, file: URL, relativePath: String, indexTitle: String?, workingDirectory: String?
    ) -> AgentMemoryNote? {
        let parsed = frontMatter(of: contents)
        let text = AgentMemoryText.body(parsed.body)
        guard !text.isEmpty else { return nil }
        let heading = AgentMemoryText.sections(of: parsed.body, levels: [1]).first { $0.level == 1 }?.heading
        let name = parsed.fields["name"].map { $0.replacingOccurrences(of: "-", with: " ") }
        let fallback = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
        let title = [indexTitle, heading, name].compactMap { $0 }
            .compactMap { AgentMemoryText.line($0, maxCharacters: AgentMemoryText.maxTitleCharacters) }
            .first ?? fallback
        let category = (parsed.fields["type"] ?? parsed.fields["metadata.type"])?.lowercased()
        return AgentMemoryNote(
            id: AgentMemoryNote.identifier(agent: .claudeCode, relativePath: relativePath),
            agent: .claudeCode,
            title: title,
            summary: AgentMemoryText.line(
                parsed.fields["description"], maxCharacters: AgentMemoryText.maxSummaryCharacters),
            category: category.flatMap { ["user", "feedback", "project", "reference"].contains($0) ? $0 : nil },
            workingDirectory: workingDirectory,
            path: file.path,
            modifiedAt: AgentMemoryText.modificationDate(of: file),
            text: text)
    }

    /// The leading `---` block as flat fields (`name`, `metadata.type`), and
    /// the text after it. A file without the block is all body.
    static func frontMatter(of contents: String) -> (fields: [String: String], body: String) {
        let lines = contents.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([:], contents) }
        var fields: [String: String] = [:]
        var parent: String?
        for line in lines[1..<end] {
            let indented = line.first == " " || line.first == "\t"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon])
            let value = AgentMemoryText.unquoted(trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            if !indented { parent = value.isEmpty ? key : nil }
            guard !value.isEmpty else { continue }
            fields[indented ? "\(parent ?? "").\(key)" : key] = value
        }
        return (fields, lines[(end + 1)...].joined(separator: "\n"))
    }

    /// File name to title, from index lines such as
    /// `- [Release gotchas](release-gotchas.md) — per-release lessons`.
    static func indexTitles(_ index: URL) -> [String: String] {
        guard case .success(let contents) = AgentMemoryText.contents(of: index) else { return [:] }
        var titles: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            guard let open = line.firstIndex(of: "["),
                  let close = line[open...].range(of: "]("),
                  let end = line[close.upperBound...].firstIndex(of: ")") else { continue }
            let title = line[line.index(after: open)..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let file = String(line[close.upperBound..<end])
            if !title.isEmpty, titles[file] == nil { titles[file] = title }
        }
        return titles
    }

    /// The folder a project's sessions ran in. The project folder's name is
    /// that path with its separators lost, so the path is read from the
    /// newest session file and kept only if it produces the same name.
    static func workingDirectory(ofProject project: URL) -> String? {
        let sessions = ((try? FileManager.default.contentsOfDirectory(
            at: project, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { AgentMemoryText.modificationDate(of: $0) > AgentMemoryText.modificationDate(of: $1) }
        for session in sessions.prefix(3) {
            guard let handle = try? FileHandle(forReadingFrom: session) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: sessionPeekBytes) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            var search = text.startIndex..<text.endIndex
            while let key = text.range(of: "\"cwd\":\"", range: search) {
                search = key.upperBound..<text.endIndex
                guard let path = jsonString(startingAt: key.upperBound, in: text) else { continue }
                if AgentMemoryExclusions.claudeProjectSlug(for: path) == project.lastPathComponent { return path }
            }
        }
        return nil
    }

    /// Decodes the JSON string whose first character is at `start`.
    private static func jsonString(startingAt start: String.Index, in text: String) -> String? {
        var index = start
        while index < text.endIndex, text[index] != "\"" {
            if text[index] == "\\" { index = text.index(after: index) }
            guard index < text.endIndex else { return nil }
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return nil }
        let literal = "\"" + text[start..<index] + "\""
        return try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
    }
}

/// Reads Codex's memories from `~/.codex/memories`.
///
/// - `MEMORY.md`: one note per top-level heading (a task group).
/// - `memory_summary.md`: one note per section.
/// - `rollout_summaries/*.md`: one note per session summary.
///
/// `raw_memories.md` repeats the session summaries and is not read. The
/// `skills` and `extensions` folders hold procedures and tools, not notes.
struct CodexMemoryReader: AgentMemoryReader {
    var agent: CodingAgentKind { .codex }
    var root: URL

    func scan(excluding exclusions: AgentMemoryExclusions) -> AgentMemoryScan {
        var scan = AgentMemoryScan()
        read(root.appendingPathComponent("MEMORY.md"), into: &scan) { contents, file in
            Self.taskGroups(contents: contents, file: file, exclusions: exclusions)
        }
        read(root.appendingPathComponent("memory_summary.md"), into: &scan) { contents, file in
            Self.summarySections(contents: contents, file: file, exclusions: exclusions)
        }
        let folder = root.appendingPathComponent("rollout_summaries", isDirectory: true)
        let summaries = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in summaries {
            guard scan.notes.count < AgentMemoryText.maxNotesPerAgent else { break }
            read(file, into: &scan) { contents, file in
                Self.rolloutSummary(contents: contents, file: file, exclusions: exclusions)
            }
        }
        return scan
    }

    private func read(
        _ file: URL, into scan: inout AgentMemoryScan,
        parse: (String, URL) -> (notes: [AgentMemoryNote], excluded: Int)
    ) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        switch AgentMemoryText.contents(of: file) {
        case .failure(.tooLarge): return
        case .failure(.unreadable): scan.unreadableFiles.append(file.path)
        case .success(let contents):
            scan.filesRead += 1
            let parsed = parse(contents, file)
            scan.notes += parsed.notes
            scan.excludedNotes += parsed.excluded
        }
    }

    /// `MEMORY.md`: each `# Task Group: …` with its `scope:` line as the
    /// summary and the folder from `applies_to: cwd=…`.
    static func taskGroups(
        contents: String, file: URL, exclusions: AgentMemoryExclusions
    ) -> (notes: [AgentMemoryNote], excluded: Int) {
        let modified = AgentMemoryText.modificationDate(of: file)
        var notes: [AgentMemoryNote] = []
        var excluded = 0
        var seen: [String: Int] = [:]
        for section in AgentMemoryText.sections(of: contents, levels: [1]) where section.level == 1 {
            var scope: String?
            var workingDirectory: String?
            for line in section.body.split(separator: "\n").prefix(12) {
                if scope == nil { scope = AgentMemoryText.value(of: "scope", in: line) }
                if workingDirectory == nil, let applies = AgentMemoryText.value(of: "applies_to", in: line) {
                    workingDirectory = cwd(in: applies)
                }
            }
            guard !exclusions.excludes(workingDirectory: workingDirectory),
                  !exclusions.mentionsExcludedFolder(section.heading) else {
                excluded += 1
                continue
            }
            let text = AgentMemoryText.body(section.body)
            guard !text.isEmpty else { continue }
            let heading = section.heading.replacingOccurrences(of: "Task Group: ", with: "")
            seen[section.heading, default: 0] += 1
            let anchor = seen[section.heading] == 1 ? section.heading : "\(section.heading)#\(seen[section.heading] ?? 0)"
            notes.append(AgentMemoryNote(
                id: AgentMemoryNote.identifier(agent: .codex, relativePath: file.lastPathComponent, anchor: anchor),
                agent: .codex,
                title: AgentMemoryText.line(heading, maxCharacters: AgentMemoryText.maxTitleCharacters) ?? "Codex memory",
                summary: AgentMemoryText.line(scope, maxCharacters: AgentMemoryText.maxSummaryCharacters),
                category: nil,
                workingDirectory: workingDirectory,
                path: file.path,
                modifiedAt: modified,
                text: text))
        }
        return (notes, excluded)
    }

    /// `memory_summary.md`: one note per `##` or `###` section. A section
    /// headed by a folder path is about that folder.
    static func summarySections(
        contents: String, file: URL, exclusions: AgentMemoryExclusions
    ) -> (notes: [AgentMemoryNote], excluded: Int) {
        let modified = AgentMemoryText.modificationDate(of: file)
        var notes: [AgentMemoryNote] = []
        var excluded = 0
        var parent = ""
        var seen: [String: Int] = [:]
        for section in AgentMemoryText.sections(of: contents, levels: [2, 3]) where section.level > 0 {
            if section.level == 2 { parent = section.heading }
            let workingDirectory = section.heading.hasPrefix("/")
                ? section.heading.components(separatedBy: " / ").first : nil
            guard !exclusions.excludes(workingDirectory: workingDirectory),
                  !exclusions.mentionsExcludedFolder(section.heading) else {
                excluded += 1
                continue
            }
            let text = AgentMemoryText.body(section.body)
            guard !text.isEmpty else { continue }
            let anchorBase = section.level == 3 ? "\(parent)/\(section.heading)" : section.heading
            seen[anchorBase, default: 0] += 1
            let anchor = seen[anchorBase] == 1 ? anchorBase : "\(anchorBase)#\(seen[anchorBase] ?? 0)"
            notes.append(AgentMemoryNote(
                id: AgentMemoryNote.identifier(agent: .codex, relativePath: file.lastPathComponent, anchor: anchor),
                agent: .codex,
                title: AgentMemoryText.line(section.heading, maxCharacters: AgentMemoryText.maxTitleCharacters)
                    ?? "Codex memory summary",
                summary: section.level == 3
                    ? AgentMemoryText.line(parent, maxCharacters: AgentMemoryText.maxSummaryCharacters) : nil,
                category: nil,
                workingDirectory: workingDirectory,
                path: file.path,
                modifiedAt: modified,
                text: text))
        }
        return (notes, excluded)
    }

    /// A session summary: `key: value` header lines (`cwd`, `updated_at`),
    /// a blank line, then the summary under its `#` title.
    static func rolloutSummary(
        contents: String, file: URL, exclusions: AgentMemoryExclusions
    ) -> (notes: [AgentMemoryNote], excluded: Int) {
        let lines = contents.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var workingDirectory: String?
        var updated: Date?
        var bodyStart = 0
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") {
                bodyStart = index
                break
            }
            if let value = AgentMemoryText.value(of: "cwd", in: line) { workingDirectory = value }
            if let value = AgentMemoryText.value(of: "updated_at", in: line) { updated = CodingAgentTimestamp.date(value) }
            bodyStart = index + 1
        }
        guard !exclusions.excludes(workingDirectory: workingDirectory) else { return ([], 1) }
        let body = lines[bodyStart...].joined(separator: "\n")
        let text = AgentMemoryText.body(body)
        guard !text.isEmpty else { return ([], 0) }
        let heading = AgentMemoryText.sections(of: body, levels: [1]).first { $0.level == 1 }?.heading
        let fallback = file.deletingPathExtension().lastPathComponent
        return ([AgentMemoryNote(
            id: AgentMemoryNote.identifier(
                agent: .codex, relativePath: "rollout_summaries/\(file.lastPathComponent)"),
            agent: .codex,
            title: AgentMemoryText.line(heading, maxCharacters: AgentMemoryText.maxTitleCharacters) ?? fallback,
            summary: nil,
            category: nil,
            workingDirectory: workingDirectory,
            path: file.path,
            modifiedAt: updated ?? AgentMemoryText.modificationDate(of: file),
            text: text)], 0)
    }

    /// The folder in `cwd=/path; reuse_rule=…`.
    static func cwd(in appliesTo: String) -> String? {
        guard let start = appliesTo.range(of: "cwd=") else { return nil }
        let rest = appliesTo[start.upperBound...]
        let path = rest.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") || path.hasPrefix("~") ? path : nil
    }
}
