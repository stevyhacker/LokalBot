import Foundation

public actor UnpairedRecordingsVault {
    private struct Entry: Codable, Sendable, Equatable {
        var id: String
        var title: String
        var state: RecordingItem.State
        var startedAt: Date
        var durationSeconds: Double?
        var byteCount: Int64
    }

    public let directory: URL
    private let indexURL: URL
    private let now: @Sendable () -> Date
    private var entries: [Entry]

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        self.now = now
        self.entries = Self.loadEntries(from: directory.appendingPathComponent("index.json"))
    }

    public static func defaultDirectory() throws -> URL {
        try CompanionStorage.directory().appendingPathComponent("unpaired-recordings", isDirectory: true)
    }

    public func begin(title: String?) throws -> RecordingItem {
        try ensureDirectory()
        let id = UUID().uuidString.lowercased()
        let entry = Entry(
            id: id,
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            state: .recording,
            startedAt: now(),
            durationSeconds: nil,
            byteCount: 0)
        entries.insert(entry, at: 0)
        try save()
        return item(for: entry)
    }

    public func finish(id: String, durationSeconds: Double) throws -> RecordingItem {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw CompanionStoreError.failed("There is no such recording.")
        }
        let path = fileURL(for: id).path
        let size = Self.fileSize(atPath: path)
        guard size > 0 else {
            entries.remove(at: index)
            try? FileManager.default.removeItem(atPath: path)
            try save()
            throw CompanionStoreError.failed("Nothing was recorded.")
        }
        if entries[index].state == .recording {
            entries[index].state = .waiting
            entries[index].durationSeconds = (durationSeconds.isFinite && durationSeconds > 0) ? durationSeconds : nil
            entries[index].byteCount = size
            try save()
        }
        return item(for: entries[index])
    }

    public func recover() throws -> Int {
        var kept = 0
        var changed = false
        var remaining: [Entry] = []
        for var entry in entries {
            guard entry.state == .recording else {
                remaining.append(entry)
                continue
            }
            changed = true
            let path = fileURL(for: entry.id).path
            let size = Self.fileSize(atPath: path)
            if size > 0 {
                entry.state = .waiting
                entry.byteCount = size
                remaining.append(entry)
                kept += 1
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        if changed {
            entries = remaining
            try save()
        }
        return kept
    }

    public func discard(id: String) throws {
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: fileURL(for: id))
        if FileManager.default.fileExists(atPath: indexURL.path) || !entries.isEmpty {
            try save()
        }
    }

    public func setTitle(id: String, title: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try save()
    }

    public func contains(_ id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    public func recordings() -> [RecordingItem] {
        entries
            .sorted { $0.startedAt > $1.startedAt }
            .map(item(for:))
    }

    public func waitingForMigration() -> [RecordingItem] {
        entries
            .filter { $0.state == .waiting }
            .sorted { $0.startedAt < $1.startedAt }
            .map(item(for:))
    }

    public func removeAll() throws {
        entries = []
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).aac")
    }

    private func item(for entry: Entry) -> RecordingItem {
        RecordingItem(
            id: entry.id,
            title: entry.title,
            state: entry.state,
            startedAt: entry.startedAt,
            durationSeconds: entry.durationSeconds,
            byteCount: entry.byteCount,
            sentBytes: 0,
            message: nil,
            filePath: fileURL(for: entry.id).path)
    }

    private func ensureDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            var attributes: [FileAttributeKey: Any] = [:]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        }
        var target = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    private func save() throws {
        try ensureDirectory()
        let data = try CompanionJSON.encoder().encode(entries)
        try data.write(to: indexURL, options: .atomic)
    }

    private static func loadEntries(from url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? CompanionJSON.decoder().decode([Entry].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func fileSize(atPath path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    }
}
