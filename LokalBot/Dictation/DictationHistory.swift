import CryptoKit
import Foundation

/// A finished dictation, kept so it can be copied again after the clipboard
/// changes.
struct DictationHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Equatable, Sendable {
        /// Pasted into the field where dictation started.
        case inserted
        /// Left on the clipboard instead of pasted.
        case copied
        /// Shown in LokalBot: Try here, or the Show in LokalBot output.
        case shown
        /// Transcribed, but Compose failed, so nothing was delivered.
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
    /// The app dictation started in, when known.
    let appName: String?

    /// The text on one line, for menus.
    var preview: String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Time and the start of the text, such as "14:20 — Can you check…".
    var menuTitle: String {
        let line = preview
        let start = line.count > 60 ? String(line.prefix(59)) + "…" : line
        return "\(date.formatted(date: .omitted, time: .shortened)) — \(start)"
    }

    /// Time, app and outcome, such as "14:20 · Ghostty · Pasted".
    func caption(localized: (String) -> String = { $0 }) -> String {
        [date.formatted(date: .omitted, time: .shortened), appName, localized(outcome.label)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// The latest dictations, newest first. A long dictation that finishes after
/// focus moved goes to the clipboard, where the next copy replaces it; this
/// keeps it, across a crash or power cut too (see `DictationHistoryStore`).
struct DictationHistory: Equatable, Sendable {
    static let limit = 10
    static let maximumAge: TimeInterval = 7 * 86_400

    private(set) var entries: [DictationHistoryEntry]

    /// Saved entries, newest first, without expired ones or any beyond the limit.
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
        // The same words again (a retry) move to the top instead of repeating.
        entries.removeAll { $0.text == text || date.timeIntervalSince($0.date) >= Self.maximumAge }
        entries.insert(.init(id: UUID(), text: text, date: date, outcome: outcome, appName: appName), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// What a finished delivery keeps. A cancelled dictation delivered
    /// nothing, and text meant for a password field is never kept.
    static func outcome(for delivery: DictationCoordinator.DeliveryResult) -> DictationHistoryEntry.Outcome? {
        switch delivery {
        case .inserted: .inserted
        case .displayed: .shown
        case .notDelivered(.secureField), .cancelled: nil
        case .copied, .notDelivered, .unconfirmed, .failed: .copied
        }
    }
}

/// Recent dictations on disk, so a crash or power cut doesn't lose them.
/// Sealed with the `chat-key` like the dictation learning log, 0600, and
/// rewritten after every dictation; Clear deletes the file. Writes reach the
/// drive (F_FULLFSYNC) off the main thread, in order.
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

    /// What was saved, without expired results, which leave the file too.
    func load(now: Date = Date()) -> DictationHistory {
        let saved = savedEntries()
        let history = DictationHistory(entries: saved, now: now)
        if history.entries.count != saved.count { try? save(history.entries) }
        return history
    }

    /// No file reads as empty without touching the Keychain; an unreadable
    /// one reads as empty, and the next save replaces it.
    private func savedEntries() -> [DictationHistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path),
              let sealed = try? Data(contentsOf: url),
              let key = try? encryptionKey(),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let opened = try? AES.GCM.open(box, using: key),
              let contents = try? JSONDecoder().decode(Contents.self, from: opened) else { return [] }
        return contents.entries
    }

    /// Seals `entries` now and writes them in the background.
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

    /// Waits for queued writes and deletes.
    static func flush() {
        writes.sync {}
    }

    /// Writes a 0600 temporary file, flushes it to the drive, then renames it
    /// over the old one, so a power cut leaves either version whole.
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
                // Plain fsync only reaches the drive's cache.
                if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 { _ = fsync(handle.fileDescriptor) }
            }
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            lokalbotLog("recent dictations save FAILED: \(error.localizedDescription)")
        }
    }
}
