import Foundation

struct AgentSavedSession: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let fileURL: URL
    let workspace: URL
    let title: String
    let createdAt: Date
    let modifiedAt: Date
    let messageCount: Int
    var preview: String = ""

    var searchableText: String {
        "\(title) \(workspace.lastPathComponent) \(workspace.path) \(preview)"
    }
}

enum AgentSessionHistory {
    private static let readChunkBytes = 64 * 1_024
    private static let maximumJSONLineBytes = 4 * 1_024 * 1_024

    static func load(from directory: URL) throws -> [AgentSavedSession] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey,
        ]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])
        return files.compactMap { file in
            guard file.pathExtension.lowercased() == "jsonl",
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            return parse(file: file, resourceValues: values)
        }
        .sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.title < $1.title }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    static func validated(
        _ session: AgentSavedSession,
        in directory: URL
    ) -> AgentSavedSession? {
        let expectedParent = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let actualParent = session.fileURL.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard actualParent == expectedParent,
              session.fileURL.pathExtension.lowercased() == "jsonl" else { return nil }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey,
        ]
        guard let values = try? session.fileURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let refreshed = parse(file: session.fileURL, resourceValues: values),
              refreshed.sessionID == session.sessionID,
              refreshed.workspace.standardizedFileURL.path
                == session.workspace.standardizedFileURL.path else { return nil }
        return refreshed
    }

    private static func parse(
        file: URL,
        resourceValues: URLResourceValues
    ) -> AgentSavedSession? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var parser = MetadataParser(
            fallbackCreatedAt: resourceValues.creationDate ?? resourceValues.contentModificationDate ?? .distantPast,
            fallbackModifiedAt: resourceValues.contentModificationDate ?? resourceValues.creationDate ?? .distantPast)
        var buffer = Data()
        var droppingOversizedLine = false

        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: readChunkBytes), !next.isEmpty else { break }
                chunk = next
            } catch {
                return nil
            }
            var appendStart = chunk.startIndex
            if droppingOversizedLine {
                guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
                appendStart = chunk.index(after: newline)
                droppingOversizedLine = false
            }
            if appendStart < chunk.endIndex {
                buffer.append(contentsOf: chunk[appendStart...])
            }

            var consumedThrough = buffer.startIndex
            while let newline = buffer[consumedThrough...].firstIndex(of: 0x0A) {
                let line = buffer[consumedThrough..<newline]
                if line.count <= maximumJSONLineBytes {
                    parser.consume(Data(line))
                }
                consumedThrough = buffer.index(after: newline)
                if consumedThrough == buffer.endIndex { break }
            }
            if consumedThrough > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<consumedThrough)
            }
            if buffer.count > maximumJSONLineBytes {
                buffer.removeAll(keepingCapacity: true)
                droppingOversizedLine = true
            }
        }

        if !droppingOversizedLine, !buffer.isEmpty, buffer.count <= maximumJSONLineBytes {
            parser.consume(buffer)
        }
        return parser.session(file: file)
    }

    private struct MetadataParser {
        let fallbackCreatedAt: Date
        let fallbackModifiedAt: Date
        private let iso8601 = ISO8601DateFormatter()
        private let fractionalISO8601: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private var sessionID: String?
        private var workspace: URL?
        private var createdAt: Date?
        private var modifiedAt: Date?
        private var explicitName: String?
        private var firstUserMessage: String?
        private var messageCount = 0
        private var preview = ""

        init(fallbackCreatedAt: Date, fallbackModifiedAt: Date) {
            self.fallbackCreatedAt = fallbackCreatedAt
            self.fallbackModifiedAt = fallbackModifiedAt
        }

        mutating func consume(_ data: Data) {
            guard !data.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { return }
            if sessionID == nil {
                guard type == "session",
                      let id = object["id"] as? String,
                      !id.isEmpty,
                      let cwd = object["cwd"] as? String,
                      !cwd.isEmpty else { return }
                sessionID = id
                workspace = URL(fileURLWithPath: cwd).standardizedFileURL
                createdAt = date(from: object["timestamp"]) ?? fallbackCreatedAt
                return
            }

            if type == "session_info" {
                explicitName = (object["name"] as? String)?.trimmingCharacters(
                    in: .whitespacesAndNewlines).nilIfEmpty
                return
            }
            guard type == "message",
                  let message = object["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "user" || role == "assistant" else { return }
            messageCount += 1
            let text = Self.text(from: message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { preview = String(text.prefix(1_200)) }
            if let activity = date(from: message["timestamp"]) ?? date(from: object["timestamp"]),
               activity > (modifiedAt ?? .distantPast) {
                modifiedAt = activity
            }
            if role == "user", firstUserMessage == nil {
                firstUserMessage = Self.text(from: message["content"])
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
        }

        func session(file: URL) -> AgentSavedSession? {
            guard let sessionID, let workspace, messageCount > 0 else { return nil }
            let titleSource = explicitName ?? firstUserMessage ?? "Untitled session"
            return AgentSavedSession(
                id: file.standardizedFileURL.path,
                sessionID: sessionID,
                fileURL: file.standardizedFileURL,
                workspace: workspace,
                title: Self.displayTitle(titleSource),
                createdAt: createdAt ?? fallbackCreatedAt,
                modifiedAt: modifiedAt ?? createdAt ?? fallbackModifiedAt,
                messageCount: messageCount, preview: preview)
        }

        private func date(from value: Any?) -> Date? {
            if let milliseconds = value as? NSNumber {
                return Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
            }
            guard let value = value as? String else { return nil }
            return fractionalISO8601.date(from: value) ?? iso8601.date(from: value)
        }

        private static func text(from value: Any?) -> String {
            if let value = value as? String { return value }
            guard let blocks = value as? [[String: Any]] else { return "" }
            return blocks.compactMap { block in
                block["type"] as? String == "text" ? block["text"] as? String : nil
            }.joined(separator: "\n")
        }

        private static func displayTitle(_ text: String) -> String {
            let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
            let collapsed = firstLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard collapsed.count > 80 else { return collapsed }
            let prefix = String(collapsed.prefix(79))
            let wordBoundary = prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix
            return wordBoundary + "…"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
