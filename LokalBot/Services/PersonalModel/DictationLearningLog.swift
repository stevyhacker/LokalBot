import CryptoKit
import Foundation

/// What the person dictated into other apps, kept only for the overnight
/// learning pass (Personal Context → Learn from my dictation, off by default).
/// Raw spoken words only, never Compose's drafts, with card numbers and IBANs
/// redacted. Sealed with the `chat-key` like the personal model, 0600. Each
/// entry goes once the pass has read its day, and never lasts more than two
/// days; turning the setting off deletes the file.
@MainActor
struct DictationLearningLog {
    struct Entry: Codable, Equatable, Sendable {
        var id: UUID
        var text: String
        var appName: String
        var dictatedAt: Date
    }

    private struct Contents: Codable {
        var version = 1
        var entries: [Entry] = []
    }

    static let fileName = "dictation-for-learning.json.enc"
    static let maximumAge: TimeInterval = 2 * 86_400
    static let maximumEntries = 200
    static let maximumEntryCharacters = 1_000

    let root: URL
    let encryptionKey: @MainActor () throws -> SymmetricKey
    var now: () -> Date = Date.init

    init(root: URL, now: @escaping () -> Date = Date.init,
         encryptionKey: @escaping @MainActor () throws -> SymmetricKey = {
             try KeychainSecrets.symmetricKey(account: "chat-key")
         }) {
        self.root = root
        self.now = now
        self.encryptionKey = encryptionKey
    }

    var url: URL {
        root.appendingPathComponent("memory", isDirectory: true).appendingPathComponent(Self.fileName)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Adds one dictation, dropping expired entries and the oldest beyond the cap.
    func append(_ text: String, appName: String) throws {
        let redacted = ScreenContextPrivacy.redact(text).text
        let clean = PromptContextSanitizer.sanitize(redacted, maxCharacters: Self.maximumEntryCharacters)
        guard !clean.isEmpty else { return }
        var entries = current()
        entries.append(Entry(id: UUID(), text: clean, appName: appName, dictatedAt: now()))
        try save(Array(entries.suffix(Self.maximumEntries)))
    }

    /// Unexpired entries dictated on `day`, oldest first.
    func entries(on day: Date, calendar: Calendar = .current) -> [Entry] {
        current().filter { calendar.isDate($0.dictatedAt, inSameDayAs: day) }
    }

    /// After the learning pass for `day`: drops that day and everything
    /// before it, and anything expired.
    func removeEntries(through day: Date, calendar: Calendar = .current) throws {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        try save(current().filter { $0.dictatedAt >= end })
    }

    /// Drops expired entries; deletes the file when none remain.
    func prune() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try save(current())
    }

    func deleteAll() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Unexpired entries. An unreadable file reads as empty: it is a
    /// short-lived buffer, and the next save replaces it.
    private func current() -> [Entry] {
        guard let sealed = try? Data(contentsOf: url),
              let key = try? encryptionKey(),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let opened = try? AES.GCM.open(box, using: key),
              let contents = try? Self.decoder.decode(Contents.self, from: opened) else { return [] }
        let oldest = now().addingTimeInterval(-Self.maximumAge)
        return contents.entries.filter { $0.dictatedAt >= oldest }.sorted { $0.dictatedAt < $1.dictatedAt }
    }

    private func save(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { return try deleteAll() }
        let data = try Self.encoder.encode(Contents(entries: entries))
        guard let combined = try AES.GCM.seal(data, using: try encryptionKey()).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try combined.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The window and page a dictation was pasted into, read once right after the
/// paste and only while Learn from my dictation is on. Held in memory to
/// decide whether to keep the words, then dropped.
struct DictationLearningSurface: Equatable, Sendable {
    var windowTitle: String?
    var pageURL: String?
}

/// Which dictations may be kept for learning: the same app, website, and
/// private-window exclusions as nearby-text context, plus never LokalBot itself
/// (Ask questions are read from the conversation).
enum DictationLearningPolicy {
    static func permits(appName: String, bundleID: String?, surface: DictationLearningSurface,
                        excludedApps: [String], excludedDomains: [String],
                        ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        if let bundleID, bundleID == ownBundleID { return false }
        let observation = ScreenContextPrivacy.Observation(
            appName: appName, bundleIdentifier: bundleID, windowTitle: surface.windowTitle,
            sourceURL: surface.pageURL, focusedSecureField: false, hasWebContent: surface.pageURL != nil)
        // A browser whose page address can't be read can't be checked against
        // the website exclusions, so its dictation is not kept.
        if ScreenContextPrivacy.isBrowser(observation) {
            guard ScreenContextPrivacy.sanitizedURL(surface.pageURL) != nil else { return false }
        }
        guard !ScreenContextPrivacy.isPrivateWindow(title: surface.windowTitle ?? "") else { return false }
        return ScreenContextPrivacy.permitsContent(
            observation, excludedApps: excludedApps, excludedDomains: excludedDomains)
    }
}
