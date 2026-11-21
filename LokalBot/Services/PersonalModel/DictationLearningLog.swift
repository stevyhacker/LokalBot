import CryptoKit
import Foundation

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

    func append(_ text: String, appName: String) throws {
        let redacted = ScreenContextPrivacy.redact(text).text
        let clean = PromptContextSanitizer.sanitize(redacted, maxCharacters: Self.maximumEntryCharacters)
        guard !clean.isEmpty else { return }
        var entries = current()
        entries.append(Entry(id: UUID(), text: clean, appName: appName, dictatedAt: now()))
        try save(Array(entries.suffix(Self.maximumEntries)))
    }

    func entries(on day: Date, calendar: Calendar = .current) -> [Entry] {
        current().filter { calendar.isDate($0.dictatedAt, inSameDayAs: day) }
    }

    func removeEntries(through day: Date, calendar: Calendar = .current) throws {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        try save(current().filter { $0.dictatedAt >= end })
    }

    func prune() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try save(current())
    }

    func deleteAll() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

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

struct DictationLearningSurface: Equatable, Sendable {
    var windowTitle: String?
    var pageURL: String?
}

enum DictationLearningPolicy {
    static func permits(appName: String, bundleID: String?, surface: DictationLearningSurface,
                        excludedApps: [String], excludedDomains: [String],
                        ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        if let bundleID, bundleID == ownBundleID { return false }
        let observation = ScreenContextPrivacy.Observation(
            appName: appName, bundleIdentifier: bundleID, windowTitle: surface.windowTitle,
            sourceURL: surface.pageURL, focusedSecureField: false, hasWebContent: surface.pageURL != nil)
        if ScreenContextPrivacy.isBrowser(observation) {
            guard ScreenContextPrivacy.sanitizedURL(surface.pageURL) != nil else { return false }
        }
        guard !ScreenContextPrivacy.isPrivateWindow(title: surface.windowTitle ?? "") else { return false }
        return ScreenContextPrivacy.permitsContent(
            observation, excludedApps: excludedApps, excludedDomains: excludedDomains)
    }
}
