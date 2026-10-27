import Foundation

/// Settings changed from the terminal: an append-only log in
/// `diagnostics/settings-changes.jsonl` and the recent list Settings shows
/// with Undo. Values are kept as stored, so Undo restores them exactly.
@MainActor
final class AgentSettingsChanges: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var time: Date
        var caller: String
        var key: String
        var previous: JSONValue?
        var value: JSONValue?
    }

    static let recentLimit = 20
    /// The log keeps the newest entries once it grows past this size.
    static let maximumLogBytes = 1_048_576
    static let keptEntries = 1_000

    @Published private(set) var recent: [Entry] = []
    let logURL: URL

    init(root: URL) {
        logURL = root.appendingPathComponent("diagnostics/settings-changes.jsonl")
        var entries = Self.load(logURL)
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size]) as? NSNumber,
           size.intValue > Self.maximumLogBytes {
            entries = Array(entries.suffix(Self.keptEntries))
            try? FileManager.default.removeItem(at: logURL)
            append(entries)
        }
        recent = Array(entries.suffix(Self.recentLimit).reversed())
    }

    func record(_ items: [SettingsChangePlan.Item], caller: String, time: Date = Date()) {
        let entries = items.map {
            Entry(time: time, caller: caller, key: $0.spec.key, previous: $0.previous, value: $0.stored)
        }
        guard !entries.isEmpty else { return }
        append(entries)
        recent = Array((entries.reversed() + recent).prefix(Self.recentLimit))
    }

    /// An API key, which the log names but never stores.
    func recordSecret(_ secret: AppSecret, isSet: Bool, caller: String, time: Date = Date()) {
        recordEvent("secret.\(secret.rawValue)", .string(isSet ? "set" : "cleared"), caller: caller, time: time)
    }

    /// Access the person allowed from an agent's setup request.
    func recordSetup(_ grants: [AgentSetup.Grant], caller: String, time: Date = Date()) {
        recordEvent("setup.access", .string(grants.map(\.rawValue).joined(separator: ", ")), caller: caller, time: time)
    }

    /// Something an agent did that is not a stored setting, such as choosing
    /// a model preset or launch at login. Listed, never undone.
    func recordEvent(_ key: String, _ value: JSONValue, caller: String, time: Date = Date()) {
        let entry = Entry(time: time, caller: caller, key: key, previous: nil, value: value)
        append([entry])
        recent = Array(([entry] + recent).prefix(Self.recentLimit))
    }

    /// Undoing a retention change could delete without the review a shorter
    /// policy needs, so those are changed back in Settings instead.
    static let keysWithoutUndo: Set<String> = ["retentionDays", "keepOCRTextForever"]

    /// Undo is offered only while the setting still holds the agent's value.
    func canUndo(_ entry: Entry, in settings: AppSettings) -> Bool {
        SettingRegistry.spec(for: entry.key) != nil && !Self.keysWithoutUndo.contains(entry.key)
            && AppControlHandler.encoded(settings)[entry.key] == entry.value
    }

    /// The person clicked Undo, so turning a feature back on asks for its
    /// permissions the way its Settings control would.
    func undo(_ entry: Entry, in app: AppState) throws {
        guard canUndo(entry, in: app.settings), let spec = SettingRegistry.spec(for: entry.key) else { return }
        let item = SettingsChangePlan.Item(spec: spec, previous: entry.value, stored: entry.previous, change: .preference)
        app.applySettings(try SettingsChangeApplier.apply([item], to: app.settings), requestingPermissions: true)
        record([item], caller: "You (Undo)")
    }

    private func append(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func load(_ url: URL) -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }
}
