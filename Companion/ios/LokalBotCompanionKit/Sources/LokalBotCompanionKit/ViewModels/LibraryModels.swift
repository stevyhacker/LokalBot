import Foundation
import Observation

// View models for the reading screens. Each loads from the session's store
// and reloads when `CompanionSession.revision` changes.

// MARK: - Today

@MainActor @Observable
public final class TodayModel {
    public static let attentionLimit = 4

    /// The person's open actions, overdue first.
    public private(set) var attention: [ActionRow] = []
    public private(set) var openActionCount = 0
    public private(set) var todayRecord: DayRecord?
    /// Today's digest, or the latest earlier one until today's is written.
    public private(set) var digestRecord: DayRecord?
    public private(set) var meetings: [Meeting] = []
    public private(set) var loaded = false

    public init() {}

    public var digestIsToday: Bool { digestRecord != nil && digestRecord?.date == todayRecord?.date }

    public func load(_ session: CompanionSession) async {
        let store = session.store
        let today = session.today
        let mine = (try? await store.actions(.myOpen)) ?? []
        let sorted = ActionOrdering.sorted(mine, today: today)
        attention = Array(sorted.prefix(Self.attentionLimit))
        openActionCount = sorted.count
        todayRecord = try? await store.day(today.description)
        if todayRecord?.digest != nil {
            digestRecord = todayRecord
        } else {
            digestRecord = nil
            for key in (try? await store.days(limit: 14)) ?? [] where key < today.description {
                if let record = try? await store.day(key), record.digest != nil {
                    digestRecord = record
                    break
                }
            }
        }
        meetings = ((try? await store.meetings(fromDay: today.description, toDay: today.description, limit: 50)) ?? [])
            .sorted { $0.startedAt < $1.startedAt }
        loaded = true
    }
}

// MARK: - Meetings

public struct MeetingDayGroup: Identifiable, Hashable, Sendable {
    public let day: String
    public let meetings: [Meeting]
    public var id: String { day }
}

@MainActor @Observable
public final class MeetingsModel {
    public private(set) var groups: [MeetingDayGroup] = []
    public private(set) var hits: [SearchHit] = []
    public private(set) var searchedQuery = ""
    public private(set) var loaded = false
    public var query = ""

    public init() {}

    public func load(_ session: CompanionSession) async {
        let meetings = (try? await session.store.meetings(fromDay: nil, toDay: nil, limit: 5_000)) ?? []
        groups = Self.grouped(meetings)
        loaded = true
        if !query.isEmpty { await search(session) }
    }

    /// Searches the device's copy: titles, summaries, notes, actions,
    /// decisions, transcripts and digests.
    public func search(_ session: CompanionSession) async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            hits = []
            searchedQuery = ""
            return
        }
        hits = (try? await session.store.search(needle, limit: 100)) ?? []
        searchedQuery = needle
    }

    static func grouped(_ meetings: [Meeting]) -> [MeetingDayGroup] {
        var order: [String] = []
        var byDay: [String: [Meeting]] = [:]
        for meeting in meetings.sorted(by: { $0.startedAt > $1.startedAt }) {
            if byDay[meeting.day] == nil { order.append(meeting.day) }
            byDay[meeting.day, default: []].append(meeting)
        }
        return order.map { MeetingDayGroup(day: $0, meetings: byDay[$0] ?? []) }
    }
}

@MainActor @Observable
public final class MeetingDetailModel {
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case summary = "Summary"
        case transcript = "Transcript"
        case notes = "Notes"
        public var id: String { rawValue }
    }

    public let meetingID: String
    public private(set) var meeting: Meeting?
    public private(set) var transcript: Transcript?
    public private(set) var pendingActionIDs: Set<String> = []
    public private(set) var loaded = false
    public var tab: Tab = .summary
    /// The transcript line an evidence pill or citation pointed at.
    public var focusedSegment: Int?
    /// The excerpt to show when the transcript isn't on this device.
    public var focusedExcerpt: Citation?
    public var actionError: String?

    public init(meetingID: String) {
        self.meetingID = meetingID
    }

    public func load(_ session: CompanionSession) async {
        meeting = try? await session.store.meeting(id: meetingID)
        transcript = meeting?.hasTranscript == true ? try? await session.store.transcript(meetingID: meetingID) : nil
        let rows = (try? await session.store.actions(.all)) ?? []
        pendingActionIDs = Set(rows.filter { $0.meetingId == meetingID && $0.pending }.map(\.action.id))
        loaded = true
    }

    /// Opens the transcript at `offset`, or shows the quoted words when the
    /// transcript isn't shared.
    public func focus(at offset: Double, citation: Citation? = nil) {
        if let transcript, let index = transcript.segmentIndex(at: offset) {
            focusedSegment = index
            tab = .transcript
        } else if let citation {
            focusedExcerpt = citation
        }
    }

    public func setStatus(_ status: ActionStatus, for action: ActionItem, session: CompanionSession) async {
        do {
            try await session.setActionStatus(status, meetingID: meetingID, actionID: action.id)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// MARK: - Actions

@MainActor @Observable
public final class ActionsModel {
    public var owner: ActionOrdering.Owner = .mine
    public var status: ActionStatus = .open
    public private(set) var rows: [ActionRow] = []
    public private(set) var counts: [ActionOrdering.Owner: Int] = [:]
    public private(set) var today = DayKey(Date())
    public private(set) var loaded = false
    public var error: String?

    public init() {}

    public var visible: [ActionRow] { rows.filter { owner.matches($0.action) } }

    public var groups: [(group: ActionOrdering.Group, rows: [ActionRow])] {
        ActionOrdering.grouped(visible, today: today)
    }

    public func load(_ session: CompanionSession) async {
        today = session.today
        let all = (try? await session.store.actions(ActionFilter(status: status))) ?? []
        rows = ActionOrdering.sorted(all, today: today)
        counts = Dictionary(uniqueKeysWithValues: ActionOrdering.Owner.allCases.map { owner in
            (owner, rows.filter { owner.matches($0.action) }.count)
        })
        loaded = true
    }

    public func row(id: String) -> ActionRow? { rows.first { $0.id == id } }

    public func setStatus(_ status: ActionStatus, for row: ActionRow, session: CompanionSession) async {
        do {
            try await session.setActionStatus(status, meetingID: row.meetingId, actionID: row.action.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Timeline

@MainActor @Observable
public final class TimelineModel {
    /// Days that have a record, newest first.
    public private(set) var recordedDays: [String] = []
    public private(set) var day: DayKey
    public private(set) var record: DayRecord?
    public private(set) var meetings: [Meeting] = []
    public private(set) var today: DayKey
    public private(set) var loaded = false

    public init(day: DayKey? = nil) {
        let today = DayKey(Date())
        self.today = today
        self.day = day ?? today
    }

    /// Session times show in the Mac's zone that day when a meeting tells us
    /// what it was; otherwise in this device's zone.
    public var timeZone: TimeZone { meetings.first?.timeZone ?? .current }

    public var canGoForward: Bool { day < today }

    public func load(_ session: CompanionSession, resetToToday: Bool = false) async {
        let newToday = session.today
        if resetToToday || !loaded { day = newToday } else if day > newToday { day = newToday }
        today = newToday
        recordedDays = (try? await session.store.days(limit: 3_650)) ?? []
        await loadDay(session)
        loaded = true
    }

    public func select(_ day: DayKey, session: CompanionSession) async {
        self.day = min(day, today)
        await loadDay(session)
    }

    public func move(by days: Int, session: CompanionSession) async {
        await select(day.adding(days: days), session: session)
    }

    public func hasRecord(_ day: DayKey) -> Bool { recordedDays.contains(day.description) }

    private func loadDay(_ session: CompanionSession) async {
        let key = day.description
        record = try? await session.store.day(key)
        meetings = ((try? await session.store.meetings(fromDay: key, toDay: key, limit: 100)) ?? [])
            .sorted { $0.startedAt < $1.startedAt }
    }
}

// MARK: - People and projects

@MainActor @Observable
public final class PeopleModel {
    public private(set) var people: [Person] = []
    public private(set) var loaded = false

    public init() {}

    public func load(_ session: CompanionSession) async {
        people = (try? await session.store.people()) ?? []
        loaded = true
    }
}

@MainActor @Observable
public final class PersonDetailModel {
    public let personID: String
    public private(set) var person: Person?
    public private(set) var meetings: [String: Meeting] = [:]
    public private(set) var loaded = false

    public init(personID: String) { self.personID = personID }

    public var meetingsTogether: [Meeting] {
        (person?.meetingIds ?? []).compactMap { meetings[$0] }.sorted { $0.startedAt > $1.startedAt }
    }

    public func load(_ session: CompanionSession) async {
        person = try? await session.store.person(id: personID)
        meetings = await MeetingLookup.meetings(Set((person?.meetingIds ?? [])
            + (person?.openWork.map(\.meetingId) ?? []) + (person?.decisionsTogether.map(\.meetingId) ?? [])), in: session)
        loaded = true
    }
}

@MainActor @Observable
public final class ProjectsModel {
    public private(set) var projects: [Project] = []
    public private(set) var loaded = false

    public init() {}

    public func load(_ session: CompanionSession) async {
        projects = (try? await session.store.projects()) ?? []
        loaded = true
    }
}

@MainActor @Observable
public final class ProjectDetailModel {
    public let projectID: String
    public private(set) var project: Project?
    public private(set) var meetings: [String: Meeting] = [:]
    public private(set) var loaded = false

    public init(projectID: String) { self.projectID = projectID }

    public var projectMeetings: [Meeting] {
        (project?.meetingIds ?? []).compactMap { meetings[$0] }.sorted { $0.startedAt > $1.startedAt }
    }

    public func load(_ session: CompanionSession) async {
        project = try? await session.store.project(id: projectID)
        let ids = (project?.meetingIds ?? []) + (project?.decisions.map(\.meetingId) ?? [])
            + (project?.yourActions.map(\.meetingId) ?? []) + (project?.waitingOnOthers.map(\.meetingId) ?? [])
        meetings = await MeetingLookup.meetings(Set(ids), in: session)
        loaded = true
    }
}

enum MeetingLookup {
    @MainActor
    static func meetings(_ ids: Set<String>, in session: CompanionSession) async -> [String: Meeting] {
        var result: [String: Meeting] = [:]
        for id in ids {
            if let meeting = try? await session.store.meeting(id: id) { result[id] = meeting }
        }
        return result
    }
}
