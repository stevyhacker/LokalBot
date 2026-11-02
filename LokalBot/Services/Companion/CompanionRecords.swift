import Foundation

/// Companion records, schema version 1 (`Companion/protocol/records.md`).
///
/// These types are the allowlist: a field reaches a phone only if it is
/// declared here. Optional fields are omitted from the JSON, never `null`.
/// Instants are ISO 8601 UTC strings with milliseconds; calendar days are
/// `YYYY-MM-DD` in the Mac's time zone; offsets inside a meeting are seconds
/// from the start of its audio.
enum CompanionRecordKind: String, CaseIterable, Sendable {
    case manifest, meeting, transcript, day, person, project

    /// Kinds whose keys the publisher reconciles. The manifest is a single
    /// record set through `setManifest`.
    static let reconciled: [Self] = [.meeting, .transcript, .day, .person, .project]
}

/// One built record: what the Mac publishes. The host adds the envelope
/// (`version`, `seq`, `sortKey`, `deleted`).
struct CompanionRecord: Equatable, Sendable {
    let kind: CompanionRecordKind
    let key: String
    let bodyJSON: String
}

enum CompanionJSON {
    /// Sorted keys and unescaped slashes, so equal content always serializes
    /// to the same bytes and the host can skip unchanged bodies.
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func instant(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        DreamDay.key(for: date, calendar: calendar)
    }

    /// Meeting and project UUIDs travel in lower case, as in the fixtures.
    static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
}

// MARK: - Bodies

struct CompanionManifestBody: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var libraryName: String
    var macName: String
    var dataClasses: CompanionSharing.DataClasses
    var historyDays: Int
    var askEnabled: Bool
    var generatedAt: String
}

struct CompanionCitation: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var speaker: String?
    var excerpt: String
}

struct CompanionAction: Codable, Equatable, Sendable {
    var id: String
    var text: String
    var owner: String?
    var ownerIsUser: Bool
    var ownerUnclear: Bool
    var dueDate: String?
    var dueText: String?
    var status: String
    var importance: Int
    var citations: [CompanionCitation]
}

struct CompanionStatement: Codable, Equatable, Sendable {
    var id: String
    var text: String
    var citations: [CompanionCitation]
}

struct CompanionNamedRef: Codable, Equatable, Sendable {
    var id: String
    var displayName: String
}

struct CompanionProjectRef: Codable, Equatable, Sendable {
    var id: String
    var name: String
}

struct CompanionMeetingBody: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var startedAt: String
    var endedAt: String
    var day: String
    var timeZoneOffsetMinutes: Int
    var durationSeconds: Double
    var appName: String?
    var people: [CompanionNamedRef]
    var projects: [CompanionProjectRef]
    var summaryMarkdown: String?
    var notesMarkdown: String?
    var actions: [CompanionAction]
    var decisions: [CompanionStatement]
    var openQuestions: [CompanionStatement]
    var hasTranscript: Bool
    var mergedInto: String?
}

struct CompanionTranscriptBody: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        var start: Double
        var end: Double
        var speaker: String
        var colorIndex: Int
        var text: String
    }

    var meetingId: String
    var segments: [Segment]
}

struct CompanionDayBody: Codable, Equatable, Sendable {
    struct Digest: Codable, Equatable, Sendable {
        struct Sections: Codable, Equatable, Sendable {
            var highlights: [String]
            var decisions: [String]
            var tasks: [String]
            var blockers: [String]
            var followUps: [String]
        }

        var markdown: String
        var generatedAt: String?
        var userEdited: Bool
        var sections: Sections
    }

    struct Seconds: Codable, Equatable, Sendable {
        var name: String
        var seconds: Double
    }

    struct Session: Codable, Equatable, Sendable {
        var start: String
        var end: String
        var title: String
        var kind: String
        var meetingId: String?
        var project: String?
        var apps: [Seconds]
        var windowTitles: [String]?
    }

    struct SavedMoment: Codable, Equatable, Sendable {
        var at: String
        var label: String
    }

    struct Timeline: Codable, Equatable, Sendable {
        var trackedSeconds: Double
        var sessions: [Session]
        var byProject: [Seconds]
        var byApp: [Seconds]
        var savedMoments: [SavedMoment]
    }

    var date: String
    var digest: Digest?
    var timeline: Timeline?
    var meetingIds: [String]
}

struct CompanionPersonBody: Codable, Equatable, Sendable {
    struct OpenWork: Codable, Equatable, Sendable {
        var meetingId: String
        var actionId: String
        var text: String
        var dueDate: String?
        var theirs: Bool
    }

    struct Decision: Codable, Equatable, Sendable {
        var meetingId: String
        var text: String
    }

    var id: String
    var displayName: String
    var lastMetAt: String?
    var openWork: [OpenWork]
    var decisionsTogether: [Decision]
    var meetingIds: [String]
}

struct CompanionProjectBody: Codable, Equatable, Sendable {
    struct YourAction: Codable, Equatable, Sendable {
        var meetingId: String
        var actionId: String
        var text: String
        var dueDate: String?
        var status: String
    }

    struct WaitingOn: Codable, Equatable, Sendable {
        var meetingId: String
        var actionId: String
        var text: String
        var owner: String?
        var dueDate: String?
    }

    var id: String
    var name: String
    var whereItStands: String?
    var yourActions: [YourAction]
    var waitingOnOthers: [WaitingOn]
    var decisions: [CompanionPersonBody.Decision]
    var timeThisWeekSeconds: Double
    var people: [CompanionNamedRef]
    var meetingIds: [String]
}

// MARK: - Phone → Mac

/// `action.setStatus`, the only op in schema version 1.
struct CompanionSetStatusOp: Codable, Equatable, Sendable {
    var type: String
    var opId: String?
    var meetingId: String
    var actionId: String
    var actionText: String?
    var status: String
    var at: String?

    static let typeName = "action.setStatus"
}

/// What `apply_op` reports back to the device.
struct CompanionOpResult: Equatable, Sendable {
    enum Status: String, Sendable { case applied, unmatched, rejected }
    var status: Status
    var message: String?
}

struct CompanionAskRequest: Codable, Equatable, Sendable {
    struct Turn: Codable, Equatable, Sendable {
        var role: String
        var text: String
    }

    struct Scope: Codable, Equatable, Sendable {
        var day: String?
        var meetingId: String?
    }

    var requestId: String
    var conversationId: String?
    var question: String
    var history: [Turn]?
    var scope: Scope?
}

struct CompanionAskResult: Codable, Equatable, Sendable {
    struct Citation: Codable, Equatable, Sendable {
        var index: Int
        var meetingId: String?
        var at: Double?
        var label: String
    }

    var requestId: String
    var answer: String
    var citations: [Citation]
    var engineLabel: String
    var location: String
    var answeredAt: String
}
