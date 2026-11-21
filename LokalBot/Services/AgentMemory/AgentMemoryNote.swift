import CryptoKit
import Foundation

struct AgentMemoryNote: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var agent: CodingAgentKind
    var title: String
    var summary: String?
    var category: String?
    var workingDirectory: String?
    var path: String
    var modifiedAt: Date
    var text: String

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

struct AgentMemoryScan: Sendable {
    var notes: [AgentMemoryNote] = []
    var filesRead = 0
    var unreadableFiles: [String] = []
    var excludedNotes = 0

    mutating func merge(_ other: AgentMemoryScan) {
        notes += other.notes
        filesRead += other.filesRead
        unreadableFiles += other.unreadableFiles
        excludedNotes += other.excludedNotes
    }
}

struct AgentMemoryExclusions: Equatable, Sendable {
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

    func excludes(claudeProjectSlug slug: String) -> Bool {
        folders.contains { folder in
            let excluded = Self.claudeProjectSlug(for: folder)
            return slug == excluded || slug.hasPrefix(excluded + "-")
        }
    }

    func mentionsExcludedFolder(_ text: String) -> Bool {
        folders.contains { folder in
            var search = text.startIndex..<text.endIndex
            while let found = text.range(of: folder, range: search) {
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

enum AgentMemoryText {
    static let maxFileBytes = 4 * 1_024 * 1_024
    static let maxNoteCharacters = 24_000
    static let maxTitleCharacters = 160
    static let maxSummaryCharacters = 400
    static let maxNotesPerAgent = 5_000

    enum ReadFailure: Error { case unreadable, tooLarge }

    static func contents(of url: URL) -> Result<String, ReadFailure> {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxFileBytes else { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        return .success(String(decoding: data, as: UTF8.self))
    }

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

    struct Section: Equatable {
        var level: Int
        var heading: String
        var body: String
    }

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
