import Foundation

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
    var owner: String?
    var due: String?
    var quote: String
    var time: TimeInterval
    var speaker: String
    var earlier: RadarEvidence?
    var foundAt: Date
    var model: String
    var answered = false
    var screenAnswer: RadarScreenAnswer?
    var answer: RadarAnswer?

    var isUserCommitment: Bool {
        kind == .commitment && owner?.caseInsensitiveCompare("Me") == .orderedSame
    }
}

struct RadarEvidence: Codable, Equatable, Sendable {
    var meetingID: UUID
    var meetingTitle: String
    var meetingDate: Date
    var time: TimeInterval?
    var speaker: String?
    var text: String
    var isCurrentMeeting = false
}

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
    var rejected: Int
}

struct MeetingRadarRecord: Codable, Equatable, Sendable {
    static let fileName = "radar.json"
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var model: String
    var items: [RadarItem] = []
    var passes: [RadarPass] = []
    var screenAnswerRequests: [RadarPass]?
    var answerRequests: [RadarPass]?

    var cost: Double {
        (passes + (screenAnswerRequests ?? []) + (answerRequests ?? [])).reduce(0) { $0 + $1.cost }
    }

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
