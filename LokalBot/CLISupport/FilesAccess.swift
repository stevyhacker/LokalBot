import DigUpKit
import Foundation

/// What Files lets agents search, as the app last wrote it: the folders the
/// person chose. The app keeps it only while the Files grant is on and Files
/// is on with a folder, so the CLI never has to read the app's settings.
struct FilesAccessProjection: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = FilesAccessProjection.currentVersion
    var generatedAt: Date
    var folders: [String]
}

/// Cross-process truth for the Files grant: a marker the app sets from
/// Settings → Privacy → External agents, plus the projection it keeps in sync
/// with Settings → Personal Context → Files. Separate from every other grant,
/// and no Agent Mode capability satisfies it.
struct FilesAccessGate {
    static let markerName = "files-access-enabled"
    static let projectionName = "files-access.json"
    /// Files' index in the library (`FileSearchService.indexFolderName`).
    static let indexFolderName = "files-index.noindex"

    var root: URL

    init(root: URL = SessionLookup.storageRootURL) {
        self.root = root
    }

    var controlDirectory: URL { root.appendingPathComponent("control", isDirectory: true) }
    var accessMarkerURL: URL { controlDirectory.appendingPathComponent(Self.markerName) }
    var projectionURL: URL { controlDirectory.appendingPathComponent(Self.projectionName) }
    var indexDirectory: URL { root.appendingPathComponent(Self.indexFolderName, isDirectory: true) }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: accessMarkerURL.path)
    }

    func isAuthorized() -> Bool {
        isEnabled
    }

    func enable() throws {
        try prepareControlDirectory()
        try Data(UUID().uuidString.utf8).write(to: accessMarkerURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accessMarkerURL.path)
    }

    /// Revoking removes the folder list too.
    func disable() {
        removeProjection()
        try? FileManager.default.removeItem(at: accessMarkerURL)
    }

    func writeProjection(_ projection: FilesAccessProjection) throws {
        try prepareControlDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(projection).write(to: projectionURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: projectionURL.path)
    }

    func removeProjection() {
        try? FileManager.default.removeItem(at: projectionURL)
    }

    /// The chosen folders, or nil when the grant is off, Files is off, or the
    /// app hasn't written them.
    func readProjection() -> FilesAccessProjection? {
        guard isEnabled, let data = try? Data(contentsOf: projectionURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let projection = try? decoder.decode(FilesAccessProjection.self, from: data),
              projection.version <= FilesAccessProjection.currentVersion,
              !projection.folders.isEmpty else { return nil }
        return projection
    }

    private func prepareControlDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: controlDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDirectory.path)
    }
}

/// `search_files` for MCP and `lokalbot-cli search-files`: word search over
/// the Files index (DigUp's keyword search), which works while the app is
/// closed. Search by meaning needs LokalBot's embedding model, so it stays in
/// Ask.
enum FilesSearchTool {
    static let name = "search_files"
    static let defaultLimit = 10
    static let maximumLimit = 50
    /// A passage longer than this is cut, with an ellipsis.
    static let passageCharacters = 1_500

    static let disabledMessage =
        "File access is off. The user can turn it on in LokalBot → Settings → Privacy → External agents: "
        + "\"Allow external agents to read your LokalBot data\", then tick Files."
    static let unavailableMessage =
        "File access is on, but Files is off in LokalBot or has no folder yet. The user can choose folders in "
        + "LokalBot → Settings → Personal Context → Files."
    static let note =
        "Found by their words: text LokalBot read from documents, PDF pages, screenshots and pictures, and file "
        + "names. Recordings and video match only by name here. Paths point at the user's own files; LokalBot "
        + "never changes them."

    static let kinds = ["screenshot", "image", "pdf", "doc", "audio", "video"]

    static var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: "Search the folders the user chose under Files (documents, PDFs, pictures, screenshots, "
                + "recordings and video on their Mac) by words. Returns matching files, best first, with the "
                + "passage that matched. Requires the separate file-access permission.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words to find."],
                    "kinds": [
                        "type": "array",
                        "items": ["type": "string", "enum": .array(kinds.map { .string($0) })],
                        "description": "Optional: only these kinds of file.",
                    ],
                    "after": [
                        "type": "string",
                        "description": "Optional local day (YYYY-MM-DD): only files dated on or after it.",
                    ],
                    "before": [
                        "type": "string",
                        "description": "Optional local day (YYYY-MM-DD): only files dated before it.",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": .string("Maximum files (default \(defaultLimit), maximum \(maximumLimit))."),
                    ],
                ],
                "required": ["query"],
            ])
    }

    enum Failure: LocalizedError, Equatable {
        case disabled
        case unavailable
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .disabled: FilesSearchTool.disabledMessage
            case .unavailable: FilesSearchTool.unavailableMessage
            case .invalid(let message): message
            }
        }
    }

    struct Report: Encodable {
        struct Item: Encodable {
            /// The matched passage's id in the index.
            var id: Int64
            var path: String
            var name: String
            var kind: String
            var page: Int?
            var seconds: Double?
            var modified: String
            /// When a photo was taken, if it says.
            var taken: String?
            var size: Int64
            var excerpt: String?
            var passage: String?
        }

        var query: String
        var matchedBy = "words"
        var results: [Item]
        var note: String

        enum CodingKeys: String, CodingKey {
            case query, results, note
            case matchedBy = "matched_by"
        }
    }

    static func report(query rawQuery: String, kinds rawKinds: [String]? = nil, after: String? = nil,
                       before: String? = nil, limit: Int? = nil, gate: FilesAccessGate,
                       timeZone: TimeZone = .current) -> Result<Report, Failure> {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= LibraryInputPolicy.maximumQueryCharacters else {
            return .failure(.invalid(
                "\"query\" must be a non-empty string of at most \(LibraryInputPolicy.maximumQueryCharacters) characters."))
        }
        let count = limit ?? defaultLimit
        guard (1...maximumLimit).contains(count) else {
            return .failure(.invalid("\"limit\" must be an integer between 1 and \(maximumLimit)."))
        }
        var wanted: Set<FileKind>?
        if let rawKinds, !rawKinds.isEmpty {
            var parsed: Set<FileKind> = []
            for raw in rawKinds {
                guard kinds.contains(raw.lowercased()), let kind = FileKind(rawValue: raw.lowercased()) else {
                    return .failure(.invalid("\"kinds\" may contain only \(kinds.joined(separator: ", "))."))
                }
                parsed.insert(kind)
            }
            wanted = parsed
        }
        let calendar = { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone; return calendar }()
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.timeZone = timeZone
        dayFormat.dateFormat = "yyyy-MM-dd"
        func day(_ raw: String?, _ field: String) -> Result<Date?, Failure> {
            guard let raw else { return .success(nil) }
            guard let date = dayFormat.date(from: raw) else {
                return .failure(.invalid("\"\(field)\" must be a day as YYYY-MM-DD."))
            }
            return .success(calendar.startOfDay(for: date))
        }
        let from: Date?, until: Date?
        switch (day(after, "after"), day(before, "before")) {
        case (.failure(let failure), _), (_, .failure(let failure)): return .failure(failure)
        case (.success(let start), .success(let end)): (from, until) = (start, end)
        }

        guard gate.isEnabled else { return .failure(.disabled) }
        guard let projection = gate.readProjection(),
              FileManager.default.fileExists(atPath: gate.indexDirectory.appendingPathComponent(IndexStore.mainFile).path)
        else { return .failure(.unavailable) }

        let found: [SearchHit]
        let searcher: Searcher
        do {
            searcher = try Searcher(store: try IndexStore(directory: gate.indexDirectory), loadVectors: false)
            // Ask for more than the limit: hits outside the folders or dates drop out.
            found = try searcher.search(query, queryVector: nil, kinds: wanted, limit: count * 4)
        } catch {
            return .failure(.unavailable)
        }
        // A walk reports a folder by its real path (/private/var for /var).
        let roots = projection.folders.flatMap { [$0, FolderSelection.realPath($0)] }
        let stamp = ISO8601DateFormatter()
        var items: [Report.Item] = []
        for hit in found where items.count < count {
            guard roots.contains(where: { FolderSelection.isInside(hit.path, $0) }),
                  FileManager.default.fileExists(atPath: hit.path) else { continue }
            let modified = Date(timeIntervalSince1970: hit.modified)
            let taken = hit.info["taken"].flatMap(exifDate)
            let date = taken ?? modified
            if let from, date < from { continue }
            if let until, date >= until { continue }
            let isMedia = hit.kind == .audio || hit.kind == .video
            let text = isMedia ? nil : try? searcher.text(ofSegment: hit.segmentID)
            items.append(Report.Item(
                id: hit.segmentID, path: hit.path, name: URL(fileURLWithPath: hit.path).lastPathComponent,
                kind: hit.kind.rawValue,
                page: hit.kind == .pdf ? hit.loc.map { Int($0) } : nil,
                seconds: isMedia ? hit.loc : nil,
                modified: stamp.string(from: modified), taken: taken.map(stamp.string(from:)), size: hit.size,
                excerpt: hit.excerpt, passage: text.map(clipped)))
        }
        return .success(Report(query: query, results: items, note: note))
    }

    static func json(_ report: Report) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A plain-text table for `lokalbot-cli search-files --table`.
    static func table(_ report: Report) -> String {
        guard !report.results.isEmpty else { return "No files matched \"\(report.query)\"." }
        return report.results.map { item in
            let place = item.page.map { " · page \($0)" } ?? ""
            let excerpt = (item.excerpt ?? "").replacingOccurrences(of: "\n", with: " ")
            return "\(item.kind)\t\(String(item.modified.prefix(10)))\t\(item.path)\(place)\n\t\(excerpt)"
        }.joined(separator: "\n")
    }

    private static func clipped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > passageCharacters else { return trimmed }
        return String(trimmed.prefix(passageCharacters)) + "…"
    }

    /// EXIF `DateTimeOriginal`: "2026:05:14 18:02:11", in the camera's local time.
    private static func exifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}
