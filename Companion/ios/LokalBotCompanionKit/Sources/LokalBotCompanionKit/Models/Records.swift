import Foundation

// Record bodies from Companion/protocol/records.md, schema version 1.
// Optional fields are omitted on the wire, never null.

// MARK: - Envelope

public enum RecordKind: String, Codable, Sendable, CaseIterable {
    case manifest, meeting, transcript, day, person, project
}

/// One record as it travels and is stored. A tombstone (`deleted`) has an
/// empty body.
public struct RecordEnvelope: Decodable, Sendable {
    public let kind: String
    public let key: String
    public let version: Int
    public let seq: UInt64
    public let deleted: Bool
    public let sortKey: String
    public let body: RecordBody

    private enum CodingKeys: String, CodingKey { case kind, key, version, seq, deleted, sortKey, body }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        key = try container.decode(String.self, forKey: .key)
        version = try container.decode(Int.self, forKey: .version)
        seq = try container.decode(UInt64.self, forKey: .seq)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        sortKey = try container.decodeIfPresent(String.self, forKey: .sortKey) ?? ""
        if deleted {
            body = .tombstone
            return
        }
        switch RecordKind(rawValue: kind) {
        case .manifest: body = .manifest(try container.decode(Manifest.self, forKey: .body))
        case .meeting: body = .meeting(try container.decode(Meeting.self, forKey: .body))
        case .transcript: body = .transcript(try container.decode(Transcript.self, forKey: .body))
        case .day: body = .day(try container.decode(DayRecord.self, forKey: .body))
        case .person: body = .person(try container.decode(Person.self, forKey: .body))
        case .project: body = .project(try container.decode(Project.self, forKey: .body))
        case nil: body = .unknown
        }
    }
}

public enum RecordBody: Sendable {
    case manifest(Manifest)
    case meeting(Meeting)
    case transcript(Transcript)
    case day(DayRecord)
    case person(Person)
    case project(Project)
    case tombstone
    /// A kind from a newer schema; clients ignore it.
    case unknown
}

// MARK: - Manifest

public struct Manifest: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var libraryName: String
    public var macName: String
    public var dataClasses: DataClasses
    /// 0 is all history; otherwise 30, 90 or 365.
    public var historyDays: Int
    public var askEnabled: Bool
    public var generatedAt: Date

    public struct DataClasses: Codable, Sendable, Hashable {
        public var meetings = true
        public var transcripts = true
        public var digests = true
        public var timeline = true
        public var windowTitles = true
        public var people = true
        public var projects = true

        public init() {}
    }

    public init(schemaVersion: Int = 1, libraryName: String, macName: String,
                dataClasses: DataClasses = .init(), historyDays: Int = 0,
                askEnabled: Bool = true, generatedAt: Date) {
        self.schemaVersion = schemaVersion
        self.libraryName = libraryName
        self.macName = macName
        self.dataClasses = dataClasses
        self.historyDays = historyDays
        self.askEnabled = askEnabled
        self.generatedAt = generatedAt
    }
}

// MARK: - Meeting

public struct PersonRef: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct ProjectRef: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Meeting: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date
    /// Local day of `startedAt` on the Mac, `YYYY-MM-DD`.
    public var day: String
    /// The Mac's offset at `startedAt`, for showing times as they were.
    public var timeZoneOffsetMinutes: Int
    public var durationSeconds: Double
    public var appName: String?
    public var people: [PersonRef]
    public var projects: [ProjectRef]
    public var summaryMarkdown: String?
    public var notesMarkdown: String?
    public var actions: [ActionItem]
    public var decisions: [MeetingOutcome]
    public var openQuestions: [MeetingOutcome]
    public var hasTranscript: Bool
    public var mergedInto: String?

    public init(id: String, title: String, startedAt: Date, endedAt: Date, day: String,
                timeZoneOffsetMinutes: Int, durationSeconds: Double, appName: String? = nil,
                people: [PersonRef] = [], projects: [ProjectRef] = [], summaryMarkdown: String? = nil,
                notesMarkdown: String? = nil, actions: [ActionItem] = [], decisions: [MeetingOutcome] = [],
                openQuestions: [MeetingOutcome] = [], hasTranscript: Bool = false, mergedInto: String? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.day = day
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
        self.durationSeconds = durationSeconds
        self.appName = appName
        self.people = people
        self.projects = projects
        self.summaryMarkdown = summaryMarkdown
        self.notesMarkdown = notesMarkdown
        self.actions = actions
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.hasTranscript = hasTranscript
        self.mergedInto = mergedInto
    }

    /// The Mac's time zone when the meeting started.
    public var timeZone: TimeZone {
        TimeZone(secondsFromGMT: timeZoneOffsetMinutes * 60) ?? .current
    }
}

public enum ActionStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case open, done, deferred

    /// A status from a newer schema reads as open, so the action stays visible.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ActionStatus(rawValue: raw) ?? .open
    }

    public var label: String {
        switch self {
        case .open: "Open"
        case .done: "Done"
        case .deferred: "Deferred"
        }
    }
}

public struct ActionItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var owner: String?
    public var ownerIsUser: Bool
    public var ownerUnclear: Bool
    /// Resolved on the Mac, `YYYY-MM-DD`.
    public var dueDate: String?
    /// The phrase as spoken ("by Thursday").
    public var dueText: String?
    public var status: ActionStatus
    /// 1–5.
    public var importance: Int
    public var citations: [Citation]

    public init(id: String, text: String, owner: String? = nil, ownerIsUser: Bool = false,
                ownerUnclear: Bool = false, dueDate: String? = nil, dueText: String? = nil,
                status: ActionStatus = .open, importance: Int = 3, citations: [Citation] = []) {
        self.id = id
        self.text = text
        self.owner = owner
        self.ownerIsUser = ownerIsUser
        self.ownerUnclear = ownerUnclear
        self.dueDate = dueDate
        self.dueText = dueText
        self.status = status
        self.importance = importance
        self.citations = citations
    }
}

/// An offset range in seconds from the start of the meeting's audio, and the
/// quoted words.
public struct Citation: Codable, Sendable, Hashable, Identifiable {
    public var start: Double
    public var end: Double
    public var speaker: String?
    public var excerpt: String

    public init(start: Double, end: Double, speaker: String? = nil, excerpt: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.excerpt = excerpt
    }

    public var id: Double { start }
}

/// A decision or an open question.
public struct MeetingOutcome: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var citations: [Citation]

    public init(id: String, text: String, citations: [Citation] = []) {
        self.id = id
        self.text = text
        self.citations = citations
    }
}

// MARK: - Transcript

public struct Transcript: Codable, Sendable, Hashable {
    public var meetingId: String
    public var segments: [TranscriptSegment]

    public init(meetingId: String, segments: [TranscriptSegment]) {
        self.meetingId = meetingId
        self.segments = segments
    }

    /// The segment holding `offset`, or the last one that starts before it.
    public func segmentIndex(at offset: Double) -> Int? {
        if let exact = segments.firstIndex(where: { offset >= $0.start && offset < max($0.end, $0.start + 0.5) }) {
            return exact
        }
        return segments.lastIndex(where: { $0.start <= offset }) ?? (segments.isEmpty ? nil : 0)
    }
}

public struct TranscriptSegment: Codable, Sendable, Hashable {
    public var start: Double
    public var end: Double
    public var speaker: String
    /// 0 is the person themselves; 1–7 the speaker palette; -1 grouped or unknown.
    public var colorIndex: Int
    public var text: String

    public init(start: Double, end: Double, speaker: String, colorIndex: Int, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.colorIndex = colorIndex
        self.text = text
    }
}

// MARK: - Day

public struct DayRecord: Codable, Sendable, Hashable, Identifiable {
    /// `YYYY-MM-DD` in the Mac's local time zone.
    public var date: String
    public var digest: DayDigest?
    public var timeline: DayTimeline?
    public var meetingIds: [String]

    public var id: String { date }

    public init(date: String, digest: DayDigest? = nil, timeline: DayTimeline? = nil, meetingIds: [String] = []) {
        self.date = date
        self.digest = digest
        self.timeline = timeline
        self.meetingIds = meetingIds
    }
}

public struct DayDigest: Codable, Sendable, Hashable {
    public var markdown: String
    public var generatedAt: Date
    public var userEdited: Bool
    public var sections: Sections

    public struct Sections: Codable, Sendable, Hashable {
        public var highlights: [String]
        public var decisions: [String]
        public var tasks: [String]
        public var blockers: [String]
        public var followUps: [String]

        public init(highlights: [String] = [], decisions: [String] = [], tasks: [String] = [],
                    blockers: [String] = [], followUps: [String] = []) {
            self.highlights = highlights
            self.decisions = decisions
            self.tasks = tasks
            self.blockers = blockers
            self.followUps = followUps
        }

        public var isEmpty: Bool {
            highlights.isEmpty && decisions.isEmpty && tasks.isEmpty && blockers.isEmpty && followUps.isEmpty
        }
    }

    public init(markdown: String, generatedAt: Date, userEdited: Bool = false, sections: Sections) {
        self.markdown = markdown
        self.generatedAt = generatedAt
        self.userEdited = userEdited
        self.sections = sections
    }
}

public struct DayTimeline: Codable, Sendable, Hashable {
    public var trackedSeconds: Double
    public var sessions: [WorkSession]
    /// Sorted by seconds, descending; no project counts under "Other".
    public var byProject: [TimeShare]
    public var byApp: [TimeShare]
    public var savedMoments: [SavedMoment]

    public init(trackedSeconds: Double, sessions: [WorkSession] = [], byProject: [TimeShare] = [],
                byApp: [TimeShare] = [], savedMoments: [SavedMoment] = []) {
        self.trackedSeconds = trackedSeconds
        self.sessions = sessions
        self.byProject = byProject
        self.byApp = byApp
        self.savedMoments = savedMoments
    }
}

public struct WorkSession: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case work, meeting, agent

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .work
        }
    }

    public var start: Date
    public var end: Date
    public var title: String?
    public var kind: Kind
    public var meetingId: String?
    public var project: String?
    public var apps: [TimeShare]
    /// Present only while window titles are shared.
    public var windowTitles: [String]?

    public var id: String { "\(start.timeIntervalSince1970)-\(kind.rawValue)" }

    public init(start: Date, end: Date, title: String? = nil, kind: Kind = .work, meetingId: String? = nil,
                project: String? = nil, apps: [TimeShare] = [], windowTitles: [String]? = nil) {
        self.start = start
        self.end = end
        self.title = title
        self.kind = kind
        self.meetingId = meetingId
        self.project = project
        self.apps = apps
        self.windowTitles = windowTitles
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// The session's title, or its busiest apps when the Mac sent none.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return apps.prefix(2).map(\.name).joined(separator: " · ")
    }
}

public struct TimeShare: Codable, Sendable, Hashable {
    public var name: String
    public var seconds: Double

    public init(name: String, seconds: Double) {
        self.name = name
        self.seconds = seconds
    }

    public var isOther: Bool { name == "Other" }
}

public struct SavedMoment: Codable, Sendable, Hashable {
    public var at: Date
    public var label: String

    public init(at: Date, label: String) {
        self.at = at
        self.label = label
    }
}

// MARK: - Person

public struct Person: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var lastMetAt: Date?
    public var openWork: [OpenWork]
    public var decisionsTogether: [LinkedText]
    public var meetingIds: [String]

    public struct OpenWork: Codable, Sendable, Hashable {
        public var meetingId: String
        public var actionId: String
        public var text: String
        public var dueDate: String?
        /// True when the person owns it, false when the LokalBot user does.
        public var theirs: Bool

        public init(meetingId: String, actionId: String, text: String, dueDate: String? = nil, theirs: Bool) {
            self.meetingId = meetingId
            self.actionId = actionId
            self.text = text
            self.dueDate = dueDate
            self.theirs = theirs
        }
    }

    public init(id: String, displayName: String, lastMetAt: Date? = nil, openWork: [OpenWork] = [],
                decisionsTogether: [LinkedText] = [], meetingIds: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.lastMetAt = lastMetAt
        self.openWork = openWork
        self.decisionsTogether = decisionsTogether
        self.meetingIds = meetingIds
    }

    public var firstName: String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }
}

/// Text that came from a meeting: a decision, a project decision.
public struct LinkedText: Codable, Sendable, Hashable {
    public var meetingId: String
    public var text: String

    public init(meetingId: String, text: String) {
        self.meetingId = meetingId
        self.text = text
    }
}

// MARK: - Project

public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var whereItStands: String?
    public var yourActions: [YourAction]
    public var waitingOnOthers: [WaitingOn]
    public var decisions: [LinkedText]
    public var timeThisWeekSeconds: Double
    public var people: [PersonRef]
    public var meetingIds: [String]

    public struct YourAction: Codable, Sendable, Hashable {
        public var meetingId: String
        public var actionId: String
        public var text: String
        public var dueDate: String?
        public var status: ActionStatus

        public init(meetingId: String, actionId: String, text: String, dueDate: String? = nil, status: ActionStatus = .open) {
            self.meetingId = meetingId
            self.actionId = actionId
            self.text = text
            self.dueDate = dueDate
            self.status = status
        }
    }

    public struct WaitingOn: Codable, Sendable, Hashable {
        public var meetingId: String
        public var actionId: String
        public var text: String
        public var owner: String?
        public var dueDate: String?

        public init(meetingId: String, actionId: String, text: String, owner: String? = nil, dueDate: String? = nil) {
            self.meetingId = meetingId
            self.actionId = actionId
            self.text = text
            self.owner = owner
            self.dueDate = dueDate
        }
    }

    public init(id: String, name: String, whereItStands: String? = nil, yourActions: [YourAction] = [],
                waitingOnOthers: [WaitingOn] = [], decisions: [LinkedText] = [], timeThisWeekSeconds: Double = 0,
                people: [PersonRef] = [], meetingIds: [String] = []) {
        self.id = id
        self.name = name
        self.whereItStands = whereItStands
        self.yourActions = yourActions
        self.waitingOnOthers = waitingOnOthers
        self.decisions = decisions
        self.timeThisWeekSeconds = timeThisWeekSeconds
        self.people = people
        self.meetingIds = meetingIds
    }
}
