import CryptoKit
import Foundation

/// A note a coding agent wrote for its own later sessions, as LokalBot keeps
/// it for search. The agent's file stays the source and is never changed.
struct AgentMemoryNote: Codable, Equatable, Identifiable, Sendable {
    /// Stable across scans: the agent, the file, and the section inside it.
    var id: String
    var agent: CodingAgentKind
    var title: String
    /// The agent's own one-line description of the note, when it wrote one.
    var summary: String?
    /// Claude Code's label for the note: user, feedback, project, or reference.
    var category: String?
    /// The folder the note is about, when the agent recorded it.
    var workingDirectory: String?
    /// The agent's file, for opening the note.
    var path: String
    var modifiedAt: Date
    /// The note's text with detected credentials redacted.
    var text: String

    /// The last folder name of `workingDirectory`, for a short label.
    var projectName: String? {
        guard let workingDirectory else { return nil }
        let name = (workingDirectory as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    static func identifier(agent: CodingAgentKind, relativePath: String, anchor: String = "") -> String {
        let material = [agent.rawValue, relativePath, anchor].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(material.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// What one scan of the agents' memory files found.
struct AgentMemoryScan: Sendable {
    var notes: [AgentMemoryNote] = []
    var filesRead = 0
    /// Files that exist but could not be read. While any are listed, notes
    /// missing from the scan are not taken as deleted.
    var unreadableFiles: [String] = []
    /// Notes left out by "Never read sessions in these folders".
    var excludedNotes = 0

    mutating func merge(_ other: AgentMemoryScan) {
        notes += other.notes
        filesRead += other.filesRead
        unreadableFiles += other.unreadableFiles
        excludedNotes += other.excludedNotes
    }
}

/// The person's project-folder exclusions, applied to notes. A note about a
/// folder inside an excluded one never leaves the reader.
struct AgentMemoryExclusions: Equatable, Sendable {
    /// Standardized absolute folder paths.
    let folders: [String]

    init(folders: [String] = []) {
        self.folders = folders.compactMap { rule in
            let expanded = (rule.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            let folder = (expanded as NSString).standardizingPath
            return folder.isEmpty || folder == "/" ? nil : folder
        }
    }

    func excludes(workingDirectory: String?) -> Bool {
        guard let workingDirectory else { return false }
        let path = (workingDirectory as NSString).standardizingPath
        return folders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Claude Code names a project folder after its working directory with
    /// every character that is not a letter or digit turned into "-". That
    /// loses which dashes were slashes, so a sibling such as `app-old` reads
    /// as inside `app` and is left out too: the safe direction.
    func excludes(claudeProjectSlug slug: String) -> Bool {
        folders.contains { folder in
            let excluded = Self.claudeProjectSlug(for: folder)
            return slug == excluded || slug.hasPrefix(excluded + "-")
        }
    }

    /// Whether `text` (a heading or a header line) names an excluded folder.
    func mentionsExcludedFolder(_ text: String) -> Bool {
        folders.contains { folder in
            var search = text.startIndex..<text.endIndex
            while let found = text.range(of: folder, range: search) {
                // The folder itself or something inside it, not a sibling
                // whose name merely starts the same (`app-old`, `app.bak`).
                let rest = text[found.upperBound...]
                let continuesName: Bool
                switch rest.first {
                case nil: continuesName = false
                case "."?: continuesName = rest.dropFirst().first.map { $0.isLetter || $0.isNumber } ?? false
                case let next?: continuesName = next.isLetter || next.isNumber || next == "-" || next == "_"
                }
                if !continuesName { return true }
                search = found.upperBound..<text.endIndex
            }
            return false
        }
    }

    static func claudeProjectSlug(for path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            let isPlain = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
            return isPlain ? Character(scalar) : "-"
        })
    }
}

/// Shared limits and text handling for the memory readers.
enum AgentMemoryText {
    /// A memory file larger than this is not a note someone wrote.
    static let maxFileBytes = 4 * 1_024 * 1_024
    static let maxNoteCharacters = 24_000
    static let maxTitleCharacters = 160
    static let maxSummaryCharacters = 400
    /// Per agent, so a runaway folder cannot fill the library.
    static let maxNotesPerAgent = 5_000

    enum ReadFailure: Error { case unreadable, tooLarge }

    static func contents(of url: URL) -> Result<String, ReadFailure> {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxFileBytes else { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        return .success(String(decoding: data, as: UTF8.self))
    }

    /// Credentials redacted, line endings folded, edges trimmed, capped at a
    /// line end. Markdown layout is kept so a quoted passage reads as written.
    static func body(_ raw: String) -> String {
        var text = ScreenContextPrivacy.redact(raw).text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxNoteCharacters else { return text }
        text = String(text.prefix(maxNoteCharacters))
        if let lineEnd = text.lastIndex(of: "\n") { text = String(text[..<lineEnd]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n…"
    }

    static func line(_ raw: String?, maxCharacters: Int) -> String? {
        guard let raw else { return nil }
        let text = CodingAgentText.sanitized(raw, maxCharacters: maxCharacters)
        return text.isEmpty ? nil : text
    }

    static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? Date(timeIntervalSince1970: 0)
    }

    /// One heading and the text under it, up to the next heading that starts
    /// a section.
    struct Section: Equatable {
        var level: Int
        var heading: String
        var body: String
    }

    /// Splits Markdown at headings of the given levels. Text before the first
    /// such heading comes back with level 0 and an empty heading. Headings
    /// inside fenced code are text.
    static func sections(of markdown: String, levels: Set<Int>) -> [Section] {
        var result: [Section] = []
        var current = Section(level: 0, heading: "", body: "")
        var lines: [Substring] = []
        var fence: String?
        func close() {
            current.body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if current.level > 0 || !current.body.isEmpty { result.append(current) }
            lines = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                lines.append(line)
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                lines.append(line)
                continue
            }
            let hashes = line.prefix { $0 == "#" }.count
            if hashes > 0, levels.contains(hashes), line.dropFirst(hashes).first == " " {
                close()
                current = Section(
                    level: hashes,
                    heading: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces),
                    body: "")
            } else {
                lines.append(line)
            }
        }
        close()
        return result
    }

    /// The value of a `key: value` line, without surrounding quotes.
    static func value(of key: String, in line: Substring) -> String? {
        guard line.hasPrefix(key + ":") else { return nil }
        return unquoted(line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces))
    }

    static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last else { return value }
        let inner = String(value.dropFirst().dropLast())
        switch first {
        case "\"":
            return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        case "'":
            return inner.replacingOccurrences(of: "''", with: "'")
        default:
            return value
        }
    }
}
