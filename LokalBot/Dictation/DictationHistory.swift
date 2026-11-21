import CryptoKit
import Foundation

struct DictationHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Equatable, Sendable {
        case inserted
        case copied
        case shown
        case notInserted

        var label: String {
            switch self {
            case .inserted: "Pasted"
            case .copied: "Copied to the clipboard"
            case .shown: "Shown in LokalBot"
            case .notInserted: "Not inserted"
            }
        }
    }

    let id: UUID
    let text: String
    let date: Date
    let outcome: Outcome
    let appName: String?

    var preview: String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    var menuTitle: String {
        let line = preview
        let start = line.count > 60 ? String(line.prefix(59)) + "…" : line
        return "\(date.formatted(date: .omitted, time: .shortened)) — \(start)"
    }

    func caption(localized: (String) -> String = { $0 }) -> String {
        [date.formatted(date: .omitted, time: .shortened), appName, localized(outcome.label)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct DictationHistory: Equatable, Sendable {
    static let limit = 10
    static let maximumAge: TimeInterval = 7 * 86_400

    private(set) var entries: [DictationHistoryEntry]

    init(entries: [DictationHistoryEntry] = [], now: Date = Date()) {
        self.entries = Array(entries
            .filter { now.timeIntervalSince($0.date) < Self.maximumAge }
            .sorted { $0.date > $1.date }
            .prefix(Self.limit))
    }

    mutating func record(
        _ text: String, outcome: DictationHistoryEntry.Outcome, appName: String?, at date: Date = Date()
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.removeAll { $0.text == text || date.timeIntervalSince($0.date) >= Self.maximumAge }
        entries.insert(.init(id: UUID(), text: text, date: date, outcome: outcome, appName: appName), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    static func outcome(for delivery: DictationCoordinator.DeliveryResult) -> DictationHistoryEntry.Outcome? {
        switch delivery {
        case .inserted: .inserted
        case .displayed: .shown
        case .notDelivered(.secureField), .cancelled: nil
        case .copied, .notDelivered, .unconfirmed, .failed: .copied
        }
    }
}

@MainActor
struct DictationHistoryStore {
    private struct Contents: Codable {
        var version = 1
        var entries: [DictationHistoryEntry]
    }

    static let fileName = "recent-dictations.json.enc"
    private static let writes = DispatchQueue(label: "me.dotenv.LokalBot.recent-dictations", qos: .utility)

    let url: URL
    let encryptionKey: @MainActor () throws -> SymmetricKey

    init(root: URL, encryptionKey: @escaping @MainActor () throws -> SymmetricKey = {
        try KeychainSecrets.symmetricKey(account: "chat-key")
    }) {
        url = root.appendingPathComponent(Self.fileName)
        self.encryptionKey = encryptionKey
    }

    func load(now: Date = Date()) -> DictationHistory {
        let saved = savedEntries()
        let history = DictationHistory(entries: saved, now: now)
        if history.entries.count != saved.count { try? save(history.entries) }
        return history
    }

    private func savedEntries() -> [DictationHistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path),
              let sealed = try? Data(contentsOf: url),
              let key = try? encryptionKey(),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let opened = try? AES.GCM.open(box, using: key),
              let contents = try? JSONDecoder().decode(Contents.self, from: opened) else { return [] }
        return contents.entries
    }

    func save(_ entries: [DictationHistoryEntry]) throws {
        guard !entries.isEmpty else { return deleteAll() }
        let data = try JSONEncoder().encode(Contents(entries: entries))
        guard let sealed = try AES.GCM.seal(data, using: try encryptionKey()).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        Self.writes.async { [url] in Self.writeDurably(sealed, to: url) }
    }

    func deleteAll() {
        Self.writes.async { [url] in try? FileManager.default.removeItem(at: url) }
    }

    static func flush() {
        writes.sync {}
    }

    nonisolated private static func writeDurably(_ data: Data, to url: URL) {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(
                atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            do {
                let handle = try FileHandle(forWritingTo: temporary)
                defer { try? handle.close() }
                try handle.write(contentsOf: data)
                if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 { _ = fsync(handle.fileDescriptor) }
            }
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            lokalbotLog("recent dictations save FAILED: \(error.localizedDescription)")
        }
    }
}
