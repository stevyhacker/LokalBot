import Foundation

/// Something Live Radar caught while a meeting was recorded: a promise, a
/// decision, a question nobody has answered yet, or a conflict with an
/// earlier meeting. Every item quotes the live line it came from.
struct RadarItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case commitment, decision, question, contradiction

        var label: String {
            switch self {
            case .commitment: "Commitment"
            case .decision: "Decision"
            case .question: "Open question"
            case .contradiction: "Contradiction"
            }
        }

        var pluralLabel: String {
            switch self {
            case .commitment: "Commitments"
            case .decision: "Decisions"
            case .question: "Open questions"
            case .contradiction: "Contradictions"
            }
        }

        var systemImage: String {
            switch self {
            case .commitment: "checkmark.circle"
            case .decision: "flag"
            case .question: "questionmark.bubble"
            case .contradiction: "exclamationmark.triangle"
            }
        }
    }

    var id: String
    var kind: Kind
    var text: String
    /// "Me", a name said in the meeting, or "Others". Nil when unknown.
    var owner: String?
    /// The deadline as it was said.
    var due: String?
    var quote: String
    /// Seconds into the recording of the quoted line.
    var time: TimeInterval
    /// The live track label of the quoted line ("local" or "them").
    var speaker: String
    /// What a contradiction conflicts with.
    var earlier: RadarEvidence?
    var foundAt: Date
    var model: String
    /// A later line answered this question.
    var answered = false

    var isUserCommitment: Bool {
        kind == .commitment && owner?.caseInsensitiveCompare("Me") == .orderedSame
    }
}

/// A passage from an earlier meeting (or earlier in this one) that a radar
/// pass showed the model, so a contradiction can point at it.
struct RadarEvidence: Codable, Equatable, Sendable {
    var meetingID: UUID
    var meetingTitle: String
    var meetingDate: Date
    var time: TimeInterval?
    var speaker: String?
    var text: String
    /// True when the passage is from the meeting being recorded.
    var isCurrentMeeting = false
}

/// Timing, size, and cost of one radar request.
struct RadarPass: Codable, Equatable, Sendable {
    var at: Date
    var seconds: Double
    var newLines: Int
    var evidence: Int
    var inputTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var cost: Double
    var added: Int
    /// Items the model returned that failed the quote or evidence check.
    var rejected: Int
}

/// `radar.json` in the meeting folder. Deleted with the meeting.
struct MeetingRadarRecord: Codable, Equatable, Sendable {
    static let fileName = "radar.json"
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var model: String
    var items: [RadarItem] = []
    var passes: [RadarPass] = []

    var cost: Double { passes.reduce(0) { $0 + $1.cost } }

    static func load(from folder: URL) -> MeetingRadarRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }

    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
