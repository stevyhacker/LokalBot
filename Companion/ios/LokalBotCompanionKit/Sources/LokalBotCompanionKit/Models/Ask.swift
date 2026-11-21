import Foundation

public struct AskRequest: Codable, Sendable, Hashable, Identifiable {
    public var requestId: String
    public var conversationId: String
    public var question: String
    public var history: [HistoryTurn]
    public var scope: Scope?

    public var id: String { requestId }

    public struct HistoryTurn: Codable, Sendable, Hashable {
        public enum Role: String, Codable, Sendable { case user, assistant }
        public var role: Role
        public var text: String

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    public struct Scope: Codable, Sendable, Hashable {
        public var day: String?
        public var meetingId: String?

        public init(day: String? = nil, meetingId: String? = nil) {
            self.day = day
            self.meetingId = meetingId
        }
    }

    public init(requestId: String = UUID().uuidString.lowercased(), conversationId: String,
                question: String, history: [HistoryTurn] = [], scope: Scope? = nil) {
        self.requestId = requestId
        self.conversationId = conversationId
        self.question = question
        self.history = history
        self.scope = scope
    }
}

public enum AnswerLocation: String, Codable, Sendable {
    case mac, remote

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AnswerLocation(rawValue: raw) ?? .remote
    }
}

public struct AskResult: Codable, Sendable, Hashable {
    public var requestId: String
    public var answer: String
    public var citations: [AskCitation]
    public var engineLabel: String
    public var location: AnswerLocation
    public var answeredAt: Date

    public init(requestId: String, answer: String, citations: [AskCitation] = [],
                engineLabel: String, location: AnswerLocation = .mac, answeredAt: Date) {
        self.requestId = requestId
        self.answer = answer
        self.citations = citations
        self.engineLabel = engineLabel
        self.location = location
        self.answeredAt = answeredAt
    }
}

public struct AskCitation: Codable, Sendable, Hashable, Identifiable {
    public var index: Int
    public var meetingId: String?
    public var at: Double?
    public var label: String

    public var id: Int { index }

    public init(index: Int, meetingId: String? = nil, at: Double? = nil, label: String) {
        self.index = index
        self.meetingId = meetingId
        self.at = at
        self.label = label
    }
}

public struct AskExchange: Codable, Sendable, Hashable, Identifiable {
    public var request: AskRequest
    public var result: AskResult

    public var id: String { request.requestId }

    public init(request: AskRequest, result: AskResult) {
        self.request = request
        self.result = result
    }
}
