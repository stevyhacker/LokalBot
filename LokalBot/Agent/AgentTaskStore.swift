import Foundation

/// UI metadata is independent of Pi's append-only conversation. Archiving never
/// deletes history, and browsing a task never requires a running subprocess.
struct AgentTaskRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String?
    var workspace: URL
    var sessionFile: URL?
    var draft = ""
    var attachments: [AgentAttachment] = []
    var queuedPrompts: [AgentQueuedPrompt] = []
    var sources: [AgentAttachment] = []
    var isPinned = false
    var isArchived = false
    var modifiedAt = Date()

    enum CodingKeys: String, CodingKey {
        case id, title, workspace, sessionFile, draft, attachments, queuedPrompts, sources, isPinned, isArchived, modifiedAt
    }
}

extension AgentTaskRecord {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        workspace = try values.decode(URL.self, forKey: .workspace)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        sessionFile = try values.decodeIfPresent(URL.self, forKey: .sessionFile)
        draft = try values.decodeIfPresent(String.self, forKey: .draft) ?? ""
        attachments = try values.decodeIfPresent([AgentAttachment].self, forKey: .attachments) ?? []
        queuedPrompts = try values.decodeIfPresent([AgentQueuedPrompt].self, forKey: .queuedPrompts) ?? []
        sources = try values.decodeIfPresent([AgentAttachment].self, forKey: .sources) ?? []
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
    }
}

struct AgentTaskStore {
    static let maximumMetadataBytes = 8 * 1_024 * 1_024
    let directory: URL
    var maximumBytes = Self.maximumMetadataBytes
    var file: URL { directory.appendingPathComponent("tasks.json") }

    enum SaveError: LocalizedError {
        case metadataTooLarge

        var errorDescription: String? {
            "Task metadata is too large to save. Shorten drafts or queued messages and try again. Previously saved tasks are preserved; current edits remain open."
        }
    }

    func load() throws -> [AgentTaskRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let records = try JSONDecoder().decode([AgentTaskRecord].self, from: Data(contentsOf: file))
        var seen = Set<UUID>()
        return records.filter { seen.insert($0.id).inserted }
    }

    func save(_ records: [AgentTaskRecord]) throws {
        let data = try JSONEncoder().encode(records)
        guard data.count <= maximumBytes else { throw SaveError.metadataTooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

struct AgentAttachment: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case file, meeting, moment }
    let id: String
    let kind: Kind
    let title: String
    /// References only. Source text is re-read with current permissions at send.
    let reference: String

    static func file(_ url: URL) -> Self {
        .init(id: "file:\(url.standardizedFileURL.path)", kind: .file,
              title: url.lastPathComponent, reference: url.standardizedFileURL.path)
    }

    var icon: String {
        switch kind {
        case .file: "doc"
        case .meeting: "waveform"
        case .moment: "bookmark"
        }
    }
}

struct AgentQueuedPrompt: Identifiable, Equatable, Codable {
    let id: UUID
    var text: String
    var attachments: [AgentAttachment]
    init(text: String, attachments: [AgentAttachment] = []) {
        id = UUID(); self.text = text; self.attachments = attachments
    }
}

/// Presentation grouping never changes the underlying ordered event stream.
struct AgentTranscriptGroup: Identifiable {
    let id: String
    let items: [AgentTranscriptItem]
    var isActivity: Bool { items.allSatisfy { if case .tool = $0 { true } else { false } } }

    static func make(_ items: [AgentTranscriptItem]) -> [Self] {
        var groups: [Self] = []
        var tools: [AgentTranscriptItem] = []
        func flush() {
            if let first = tools.first { groups.append(.init(id: first.id, items: tools)); tools = [] }
        }
        for item in items {
            if case .approval = item { continue } // The approval dock owns these.
            if case .tool = item { tools.append(item) } else { flush(); groups.append(.init(id: item.id, items: [item])) }
        }
        flush()
        return groups
    }

    var summary: String {
        let names = items.compactMap { item -> String? in
            if case .tool(_, let name, _, _, _) = item { return name.lowercased() }
            return nil
        }
        if names.allSatisfy({ $0 == "read" }) { return "Read \(names.count) \(names.count == 1 ? "file" : "files")" }
        if names.allSatisfy({ ["write", "edit"].contains($0) }) { return "\(names.count) file \(names.count == 1 ? "change" : "changes")" }
        return "\(names.count) \(names.count == 1 ? "activity" : "activities")"
    }
}

struct AgentResultPreview: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let text: String
    var original: String?
    var proposed: String?
    var filePath: String?

    static func tool(_ item: AgentTranscriptItem) -> Self? {
        guard case .tool(let id, let name, let args, let output, let status) = item else { return nil }
        let object = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
        let path = object["path"] as? String ?? object["file_path"] as? String
        let content = object["content"] as? String
        let oldText = object["oldText"] as? String
        let newText = object["newText"] as? String
        let state = status == .succeeded ? "Completed" : status == .failed ? "Failed" : "In progress"
        return .init(id: id, title: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? name,
                     detail: "\(state) · \(path ?? name)",
                     text: name == "write" ? (content ?? output) : output,
                     original: oldText, proposed: newText, filePath: path)
    }
}

extension AgentTranscriptItem {
    var searchableText: String {
        switch self {
        case .user(_, let text), .assistant(_, let text, _), .notice(_, let text, _): text
        case .tool(_, let name, let args, let output, _): "\(name) \(args) \(output)"
        case .approval(let request): "\(request.tool) \(request.path ?? "")"
        }
    }
}
