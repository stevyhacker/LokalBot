import Foundation

/// What a personal claim is about. Shared by the app's personal model and the
/// CLI, which only ever sees claims the person chose to share.
enum PersonalClaimKind: String, Codable, CaseIterable, Sendable {
    case fact
    case preference
    case goal
    case principle
}

/// The fields relevance ranking needs, so the app (all claims) and the CLI
/// (the shared projection) rank with the same rules.
protocol PersonalContextItem {
    var id: UUID { get }
    var kind: PersonalClaimKind { get }
    var text: String { get }
    var updatedAt: Date { get }
    var alwaysUse: Bool { get }
}

/// Deterministic priority order for a task or question, newest first within
/// each step:
/// 1. items marked Always use;
/// 2. principles and preferences, which apply to most tasks;
/// 3. facts and goals sharing a content word with the query, most shared
///    words first;
/// 4. the remaining facts and goals.
enum PersonalContextSelection {
    static func ordered<Item: PersonalContextItem>(_ items: [Item], query: String,
                                                   recentTurns: [String] = []) -> [Item] {
        var queryWords = contentWords(query)
        for turn in recentTurns.suffix(2) {
            queryWords.formUnion(contentWords(turn))
        }
        let newestFirst = items.sorted(by: isNewer)
        var ordered: [Item] = []
        var placed: Set<UUID> = []
        func place(_ item: Item) {
            guard !placed.contains(item.id) else { return }
            placed.insert(item.id)
            ordered.append(item)
        }
        for item in newestFirst where item.alwaysUse { place(item) }
        for item in newestFirst where item.kind == .principle || item.kind == .preference { place(item) }
        // Stable sort by shared-word count keeps newest-first among ties.
        var matches: [(item: Item, score: Int)] = []
        for item in newestFirst where !placed.contains(item.id) {
            let score = contentWords(item.text).intersection(queryWords).count
            if score > 0 { matches.append((item, score)) }
        }
        let bestFirst = matches.enumerated().sorted { lhs, rhs in
            if lhs.element.score != rhs.element.score { return lhs.element.score > rhs.element.score }
            return lhs.offset < rhs.offset
        }
        for match in bestFirst { place(match.element.item) }
        for item in newestFirst { place(item) }
        return ordered
    }

    private static func isNewer<Item: PersonalContextItem>(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "your", "with", "that", "this", "have",
        "has", "had", "was", "were", "will", "would", "should", "could", "what", "when", "where",
        "which", "who", "whom", "why", "how", "about", "from", "into", "than", "then", "them",
        "they", "their", "there", "these", "those", "our", "out", "can", "did", "does", "doing",
        "just", "like", "more", "most", "some", "such", "only", "also", "very", "too", "any",
        "all", "its", "it's", "i'm", "myself", "mine", "me", "my", "his", "her", "him", "she",
        "one", "get", "got", "let", "make", "made", "want", "need", "tell", "know", "think",
        "remember", "please", "always", "never",
    ]

    /// Case- and diacritic-folded words of three or more letters, minus
    /// stopwords. Works for any script, so Serbian Latin and Cyrillic match
    /// themselves.
    static func contentWords(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var words: Set<String> = []
        for raw in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }) {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard word.count >= 3, !stopwords.contains(word) else { continue }
            words.insert(word)
        }
        return words
    }
}

/// The claims a person shared with agents, as the app last wrote them. The
/// CLI never reads the encrypted personal model: this plaintext copy exists
/// only while the Personal context grant is on and holds only shared claims.
struct PersonalContextProjection: Codable, Equatable, Sendable {
    struct Claim: Codable, Equatable, Sendable, PersonalContextItem {
        enum Source: String, Codable, Sendable {
            case askedToRemember = "asked_to_remember"
            case addedInSettings = "added_in_settings"
            /// Saved automatically from something the user said in a meeting.
            case learnedFromMeeting = "learned_from_meeting"
            /// From something the user typed to a coding agent or in Ask.
            case learnedFromTyping = "learned_from_typing"
            /// From something the user dictated into another app.
            case learnedFromDictation = "learned_from_dictation"
            /// A goal or project LokalBot's overnight review kept for weeks.
            case learnedFromWorkMemory = "learned_from_work_memory"
        }

        var id: UUID
        var kind: PersonalClaimKind
        var text: String
        var alwaysUse: Bool
        var source: Source
        var createdAt: Date
        var updatedAt: Date
    }

    static let currentVersion = 1

    var version = PersonalContextProjection.currentVersion
    var generatedAt: Date
    var claims: [Claim]
}

/// Cross-process truth for the Personal context grant: a marker the app sets
/// from Settings → Privacy, plus the projection it keeps in sync. Separate
/// from meeting and screen access, and no Agent Mode capability satisfies it.
struct PersonalContextAccessGate {
    static let markerName = "personal-context-access-enabled"
    static let projectionName = "personal-context.json"

    var root: URL

    init(root: URL = SessionLookup.storageRootURL) {
        self.root = root
    }

    var controlDirectory: URL { root.appendingPathComponent("control", isDirectory: true) }
    var accessMarkerURL: URL { controlDirectory.appendingPathComponent(Self.markerName) }
    var projectionURL: URL { controlDirectory.appendingPathComponent(Self.projectionName) }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: accessMarkerURL.path)
    }

    func enable() throws {
        try prepareControlDirectory()
        try Data(UUID().uuidString.utf8).write(to: accessMarkerURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accessMarkerURL.path)
    }

    /// Revoking removes the shared copy too, so nothing lingers on disk.
    func disable() {
        removeProjection()
        try? FileManager.default.removeItem(at: accessMarkerURL)
    }

    func writeProjection(_ projection: PersonalContextProjection) throws {
        try prepareControlDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(projection)
        try data.write(to: projectionURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: projectionURL.path)
    }

    func removeProjection() {
        try? FileManager.default.removeItem(at: projectionURL)
    }

    /// The shared claims, or nil when the grant is off or the app hasn't
    /// written a readable projection.
    func readProjection() -> PersonalContextProjection? {
        guard isEnabled, let data = try? Data(contentsOf: projectionURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let projection = try? decoder.decode(PersonalContextProjection.self, from: data),
              projection.version <= PersonalContextProjection.currentVersion else { return nil }
        return projection
    }

    private func prepareControlDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: controlDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDirectory.path)
    }
}

/// `get_personal_context` for MCP and `lokalbot-cli personal-context`.
enum PersonalContextTool {
    static let name = "get_personal_context"
    static let defaultItems = 8
    static let maximumItems = 12
    static let maximumTaskCharacters = 500

    static let disabledMessage =
        "Personal context access is off. The user can turn it on in LokalBot → Settings → Privacy → " +
        "\"Allow external agents to read what I shared about myself\", then choose items to share in " +
        "Settings → Personal Context."
    static let unavailableMessage =
        "Personal context access is on, but LokalBot hasn't written the shared items yet. " +
        "Open LokalBot once so it can prepare them."
    static let note =
        "The user chose to share these with agents. \"stated\" items are the user's own words; " +
        "\"learned\" items were picked up from what the user said in meetings and may be out of date. " +
        "Use them only when they bear on the task. Items not listed are unknown, not false. Never " +
        "cite them as meeting or screen evidence."

    static var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: "Get what the user shared about themselves (facts, preferences, goals, principles) that is "
                + "relevant to a task, most relevant first. Only items the user marked as shared are returned. "
                + "Requires the separate personal-context permission.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "task": [
                        "type": "string",
                        "description": "What you are helping with, in a sentence (for example \"Evaluate a job offer\").",
                    ],
                    "kinds": [
                        "type": "array",
                        "items": ["type": "string", "enum": ["fact", "preference", "goal", "principle"]],
                        "description": "Optional: only these kinds.",
                    ],
                    "max_items": [
                        "type": "integer",
                        "description": .string("Maximum items (default \(defaultItems), maximum \(maximumItems))."),
                    ],
                ],
                "required": ["task"],
            ])
    }

    enum Failure: LocalizedError, Equatable {
        case disabled
        case unavailable
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .disabled: PersonalContextTool.disabledMessage
            case .unavailable: PersonalContextTool.unavailableMessage
            case .invalid(let message): message
            }
        }
    }

    struct Report: Encodable {
        struct Item: Encodable {
            var id: String
            var kind: String
            var text: String
            var authority: String
            var asOf: String
            var source: String
            var alwaysUse: Bool

            enum CodingKeys: String, CodingKey {
                case id, kind, text, authority, source
                case asOf = "as_of"
                case alwaysUse = "always_use"
            }
        }

        var task: String
        var items: [Item]
        var sharedCount: Int
        var note: String

        enum CodingKeys: String, CodingKey {
            case task, items, note
            case sharedCount = "shared_count"
        }
    }

    static func report(task rawTask: String, kinds rawKinds: [String]?, maxItems: Int?,
                       gate: PersonalContextAccessGate,
                       timeZone: TimeZone = .current) -> Result<Report, Failure> {
        let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, task.count <= maximumTaskCharacters else {
            return .failure(.invalid("\"task\" must be a non-empty string of at most \(maximumTaskCharacters) characters."))
        }
        let limit = maxItems ?? defaultItems
        guard (1...maximumItems).contains(limit) else {
            return .failure(.invalid("\"max_items\" must be an integer between 1 and \(maximumItems)."))
        }
        var kinds: Set<PersonalClaimKind>?
        if let rawKinds {
            var parsed: Set<PersonalClaimKind> = []
            for raw in rawKinds {
                guard let kind = PersonalClaimKind(rawValue: raw.lowercased()) else {
                    return .failure(.invalid("\"kinds\" may contain only fact, preference, goal, and principle."))
                }
                parsed.insert(kind)
            }
            kinds = parsed.isEmpty ? nil : parsed
        }
        guard gate.isEnabled else { return .failure(.disabled) }
        guard let projection = gate.readProjection() else { return .failure(.unavailable) }

        let eligible = projection.claims.filter { kinds?.contains($0.kind) ?? true }
        let chosen = PersonalContextSelection.ordered(eligible, query: task).prefix(limit)
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        var items: [Report.Item] = []
        for claim in chosen {
            let source: String
            var authority = "stated"
            switch claim.source {
            case .askedToRemember: source = "The user asked LokalBot to remember this"
            case .addedInSettings: source = "The user added this in LokalBot"
            case .learnedFromMeeting:
                source = "LokalBot learned this from something the user said in a meeting; it may be out of date"
                authority = "learned"
            case .learnedFromTyping:
                source = "LokalBot learned this from something the user typed; the user confirmed it"
                authority = "learned"
            case .learnedFromDictation:
                source = "LokalBot learned this from something the user dictated; the user confirmed it"
                authority = "learned"
            case .learnedFromWorkMemory:
                source = "LokalBot saw this in the user's work for weeks; the user confirmed it"
                authority = "learned"
            }
            items.append(Report.Item(
                id: claim.id.uuidString.lowercased(), kind: claim.kind.rawValue, text: claim.text,
                authority: authority, asOf: day.string(from: claim.updatedAt), source: source,
                alwaysUse: claim.alwaysUse))
        }
        return .success(Report(task: task, items: items, sharedCount: projection.claims.count, note: note))
    }

    static func json(_ report: Report) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
