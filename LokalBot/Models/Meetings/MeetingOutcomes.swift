import Foundation

struct OutcomeSourceCitation: Codable, Equatable, Hashable, Identifiable, Sendable {
    var meetingID: UUID?
    var segmentID: String
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String
    var excerpt: String

    var id: String { segmentID }

    init(meetingID: UUID? = nil, segmentID: String, start: TimeInterval,
         end: TimeInterval, speaker: String, excerpt: String) {
        self.meetingID = meetingID
        self.segmentID = segmentID
        self.start = start
        self.end = end
        self.speaker = speaker
        self.excerpt = excerpt
    }
}

struct MeetingOutcomes: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 4

    struct ActionItem: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var schemaVersion: Int
        var text: String
        var owner: String?
        var due: String?
        var isForUser: Bool
        var attribution: OutcomeAttribution?
        var ownershipIsUnclear: Bool { attribution?.resolution == .unresolved || owner == nil }
        var isLikelyUserAction: Bool {
            guard !isForUser, ownershipIsUnclear,
                  let speaker = attribution?.speakerID ?? citations.first?.speaker else { return false }
            return MeetingOutcomes.isMicrophoneSpeaker(speaker)
        }
        var importance: Int
        var citations: [OutcomeSourceCitation]

        static let defaultImportance = 3
        static let minimumImportance = 1
        static let maximumImportance = 5

        init(id: String? = nil, text: String, owner: String? = nil,
             due: String? = nil, isForUser: Bool? = nil,
             importance: Int = defaultImportance,
             citations: [OutcomeSourceCitation] = [],
             schemaVersion: Int = MeetingOutcomes.currentSchemaVersion,
             attribution: OutcomeAttribution? = nil) {
            self.attribution = attribution?.consistent(with: isForUser) ?? .legacy(owner: owner, forUser: isForUser)
            let resolvedIsForUser = self.attribution.map { $0.resolution == .user }
                ?? isForUser ?? Self.ownerBelongsToUser(owner)
            let proseText = OutcomeProse.actionText(text, isForUser: resolvedIsForUser)
            self.id = id ?? MeetingOutcomes.stableID(
                kind: "action", text: proseText, owner: owner, due: due,
                citationIDs: citations.map(\.segmentID))
            self.schemaVersion = schemaVersion
            self.text = proseText
            self.owner = self.attribution?.resolution == .unresolved ? nil : resolvedIsForUser ? "Me" : owner
            self.due = due
            self.isForUser = resolvedIsForUser
            self.importance = Self.clampedImportance(importance)
            self.citations = citations
        }

        var displayText: String {
            let prose = OutcomeProse.actionText(text, isForUser: isForUser)
            return attribution?.basis == .request && !prose.hasPrefix("Requested: ") ? "Requested: " + prose : prose
        }

        private static func ownerBelongsToUser(_ owner: String?) -> Bool {
            guard let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return owner.caseInsensitiveCompare("Me") == .orderedSame
        }

        private static func clampedImportance(_ importance: Int) -> Int {
            min(maximumImportance, max(minimumImportance, importance))
        }

        private enum CodingKeys: String, CodingKey {
            case id, schemaVersion, text, owner, due, isForUser, importance, citations, attribution
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(
                Int.self, forKey: .schemaVersion) ?? 1
            let decodedText = try container.decode(String.self, forKey: .text)
            owner = try container.decodeIfPresent(String.self, forKey: .owner)
            due = try container.decodeIfPresent(String.self, forKey: .due)
            citations = try container.decodeIfPresent(
                [OutcomeSourceCitation].self, forKey: .citations) ?? []
            let storedIsForUser = try container.decodeIfPresent(
                Bool.self, forKey: .isForUser)
            attribution = try container.decodeIfPresent(OutcomeAttribution.self, forKey: .attribution)?.consistent(with: storedIsForUser)
                ?? .legacy(owner: owner, forUser: storedIsForUser)
            isForUser = attribution?.resolution == .user
            if attribution?.resolution == .unresolved { owner = nil }
            if isForUser { owner = "Me" }
            importance = Self.clampedImportance(
                try container.decodeIfPresent(Int.self, forKey: .importance)
                    ?? Self.defaultImportance)
            text = OutcomeProse.actionText(decodedText, isForUser: isForUser)
            id = try container.decodeIfPresent(String.self, forKey: .id)
                ?? MeetingOutcomes.stableID(
                    kind: "action", text: text, owner: owner, due: due,
                    citationIDs: citations.map(\.segmentID))
            schemaVersion = MeetingOutcomes.currentSchemaVersion
        }
    }

    struct Decision: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var schemaVersion: Int
        var text: String
        var citations: [OutcomeSourceCitation]
        var attribution: StatementAttribution?

        init(id: String? = nil, text: String,
             citations: [OutcomeSourceCitation] = [],
             schemaVersion: Int = MeetingOutcomes.currentSchemaVersion,
             attribution: StatementAttribution? = nil) {
            let proseText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.id = id ?? MeetingOutcomes.stableID(
                kind: "decision", text: proseText,
                citationIDs: citations.map(\.segmentID))
            self.schemaVersion = schemaVersion
            self.text = proseText
            self.citations = citations
            self.attribution = attribution
        }

        var displayText: String { attribution.map { "\($0.speakerLabel): \(text)" } ?? text }

        private enum CodingKeys: String, CodingKey {
            case id, schemaVersion, text, citations, attribution
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let text = try? single.decode(String.self) {
                self.init(text: text)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedText = try container.decode(String.self, forKey: .text)
            let decodedCitations = try container.decodeIfPresent(
                [OutcomeSourceCitation].self, forKey: .citations) ?? []
            self.init(
                id: try container.decodeIfPresent(String.self, forKey: .id),
                text: decodedText,
                citations: decodedCitations,
                schemaVersion: try container.decodeIfPresent(
                    Int.self, forKey: .schemaVersion) ?? 1,
                attribution: try container.decodeIfPresent(StatementAttribution.self, forKey: .attribution))
        }
    }

    var schemaVersion: Int = currentSchemaVersion
    var transcriptRevision: String?
    var actionItems: [ActionItem] = []
    var decisionRecords: [Decision] = []
    var openQuestions: [String] = []

    var decisions: [String] {
        get { decisionRecords.map(\.text) }
        set { decisionRecords = newValue.map { Decision(text: $0) } }
    }

    init(actionItems: [ActionItem] = [], decisions: [String] = [],
         openQuestions: [String] = []) {
        self.actionItems = actionItems
        decisionRecords = decisions.map { Decision(text: $0) }
        self.openQuestions = openQuestions
    }

    var isEmpty: Bool {
        actionItems.isEmpty && decisionRecords.isEmpty && openQuestions.isEmpty
    }
    var userActionItems: [ActionItem] { actionItems.filter(\.isForUser) }
    var otherActionItems: [ActionItem] { actionItems.filter { !$0.isForUser && !$0.ownershipIsUnclear } }
    var unresolvedActionItems: [ActionItem] { actionItems.filter(\.ownershipIsUnclear) }

    func prioritizingActionItems() -> Self {
        var prioritized = self
        let likelyUserItems = actionItems.filter(\.isLikelyUserAction)
            .sorted(by: Self.higherPriorityAction)
        let otherItems = actionItems.filter { !$0.isForUser && !$0.isLikelyUserAction }
            .sorted(by: Self.higherPriorityAction)
        prioritized.actionItems = userActionItems + likelyUserItems + otherItems
        return prioritized
    }

    static func isMicrophoneSpeaker(_ speaker: String) -> Bool {
        let key = Transcript.canonicalSpeakerKey(speaker)
        let local = key.split(separator: ":").last.map(String.init) ?? key
        return local == "me" || local == "local" || local.hasPrefix("local ")
    }

    static let fileName = "outcomes.json"

    static func load(from folder: URL) -> MeetingOutcomes? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else {
            return nil
        }
        guard let outcomes = try? JSONDecoder().decode(MeetingOutcomes.self, from: data) else { return nil }
        if let revision = outcomes.transcriptRevision {
            guard let source = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
                  let transcript = try? JSONDecoder().decode(Transcript.self, from: source),
                  transcript.evidenceRevision == revision else { return nil }
        }
        return outcomes.prioritizingActionItems()
    }

    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, actionItems, decisionRecords, openQuestions, transcriptRevision
        case legacyActionItems = "action_items"
        case legacyDecisions = "decisions"
        case legacyOpenQuestions = "open_questions"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        transcriptRevision = try container.decodeIfPresent(String.self, forKey: .transcriptRevision)
        actionItems = try container.decodeIfPresent(
            [ActionItem].self, forKey: .actionItems)
            ?? container.decodeIfPresent([ActionItem].self, forKey: .legacyActionItems)
            ?? []
        decisionRecords = try container.decodeIfPresent(
            [Decision].self, forKey: .decisionRecords)
            ?? container.decodeIfPresent([Decision].self, forKey: .legacyDecisions)
            ?? []
        openQuestions = try container.decodeIfPresent(
            [String].self, forKey: .openQuestions)
            ?? container.decodeIfPresent([String].self, forKey: .legacyOpenQuestions)
            ?? []
        schemaVersion = Self.currentSchemaVersion
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(transcriptRevision, forKey: .transcriptRevision)
        try container.encode(actionItems, forKey: .actionItems)
        try container.encode(decisionRecords, forKey: .decisionRecords)
        try container.encode(openQuestions, forKey: .openQuestions)
    }

    private static func higherPriorityAction(_ lhs: ActionItem, _ rhs: ActionItem) -> Bool {
        if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
        let left = lhs.citations.first?.start ?? .infinity
        let right = rhs.citations.first?.start ?? .infinity
        if left != right { return left < right }
        return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending
    }

    static func stableID(kind: String, text: String, owner: String? = nil,
                         due: String? = nil, citationIDs: [String] = []) -> String {
        let normalized = ([kind, text, owner ?? "", due ?? ""] + citationIDs)
            .map {
                $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
            .joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
