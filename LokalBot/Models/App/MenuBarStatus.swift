import Foundation

enum MenuBarAttention: Equatable, Identifiable {
    case microphoneRefused
    case microphoneNotGranted
    case error(String)
    case settingsApproval(count: Int)

    var id: String {
        switch self {
        case .microphoneRefused: "microphone-refused"
        case .microphoneNotGranted: "microphone-not-granted"
        case .error: "error"
        case .settingsApproval: "settings-approval"
        }
    }

    static func items(
        micRecoveryNeeded: Bool,
        corePermissionsGranted: Bool,
        lastError: String?,
        pendingApprovals: Int
    ) -> [MenuBarAttention] {
        var items: [MenuBarAttention] = []
        if micRecoveryNeeded {
            items.append(.microphoneRefused)
        } else if !corePermissionsGranted {
            items.append(.microphoneNotGranted)
        }
        if let lastError, !lastError.isEmpty { items.append(.error(lastError)) }
        if pendingApprovals > 0 { items.append(.settingsApproval(count: pendingApprovals)) }
        return items
    }
}

struct MenuBarStatus: Equatable {
    static let soonWindow: TimeInterval = 15 * 60
    static let justStoppedWindow: TimeInterval = 2 * 60
    static let recentMeetingLimit = 2

    enum Dictation: Equatable {
        case starting
        case recording
        case transcribing
        case composing
    }

    enum Block: Equatable {
        case recording(Meeting)
        case dictating(Dictation)
        case attention(MenuBarAttention)
        case meetingSoon(CalendarMeetingCandidate)
        case paused
        case justStopped(Meeting)
        case idle
    }

    enum Tone: Equatable {
        case neutral
        case recording
        case upcoming
        case attention
    }

    struct RecentMeeting: Identifiable, Equatable {
        enum When: Equatable {
            case justNow
            case today(Date)
            case yesterday
            case earlier(Date)
        }

        let meeting: Meeting
        let when: When
        var id: Meeting.ID { meeting.id }
    }

    let block: Block
    let moreAttention: [MenuBarAttention]
    let recentMeetings: [RecentMeeting]

    init(
        liveMeeting: Meeting?,
        dictation: Dictation? = nil,
        attention: [MenuBarAttention],
        nextMeeting: CalendarMeetingCandidate?,
        dayMemoryPaused: Bool,
        meetings: [Meeting],
        now: Date,
        calendar: Calendar = .current
    ) {
        let stopped = Self.justStopped(in: meetings, now: now)
        if let liveMeeting {
            block = .recording(liveMeeting)
            moreAttention = attention
        } else if let dictation {
            block = .dictating(dictation)
            moreAttention = attention
        } else if let first = attention.first {
            block = .attention(first)
            moreAttention = Array(attention.dropFirst())
        } else if let nextMeeting {
            block = .meetingSoon(nextMeeting)
            moreAttention = []
        } else if dayMemoryPaused {
            block = .paused
            moreAttention = []
        } else if let stopped {
            block = .justStopped(stopped)
            moreAttention = []
        } else {
            block = .idle
            moreAttention = []
        }
        recentMeetings = Self.recentMeetings(
            in: meetings, justStopped: stopped, liveMeetingID: liveMeeting?.id, now: now, calendar: calendar)
    }

    func tone(hasCaptureWarnings: Bool) -> Tone {
        switch block {
        case .recording: hasCaptureWarnings ? .attention : .recording
        case .dictating(let phase): phase == .recording ? .recording : .neutral
        case .attention: .attention
        case .meetingSoon: .upcoming
        case .paused, .justStopped, .idle: .neutral
        }
    }

    static func justStopped(in meetings: [Meeting], now: Date) -> Meeting? {
        let earliest = now.addingTimeInterval(-justStoppedWindow)
        let latest = now.addingTimeInterval(justStoppedWindow)
        return meetings
            .filter { meeting in
                guard meeting.isOwnWork, !meeting.isImported, let ended = meeting.endedAt else { return false }
                return ended > earliest && ended <= latest
            }
            .max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
    }

    static func recentMeetings(
        in meetings: [Meeting],
        justStopped: Meeting?,
        liveMeetingID: Meeting.ID? = nil,
        now: Date,
        calendar: Calendar = .current
    ) -> [RecentMeeting] {
        var seen = Set<Meeting.ID>()
        let listed = ((justStopped.map { [$0] } ?? []) + meetings).filter { meeting in
            !meeting.isMergedSource && meeting.id != liveMeetingID && seen.insert(meeting.id).inserted
        }
        return listed.prefix(recentMeetingLimit).map { meeting in
            RecentMeeting(
                meeting: meeting,
                when: when(meeting, justStoppedID: justStopped?.id, now: now, calendar: calendar))
        }
    }

    private static func when(
        _ meeting: Meeting, justStoppedID: Meeting.ID?, now: Date, calendar: Calendar
    ) -> RecentMeeting.When {
        if meeting.id == justStoppedID { return .justNow }
        if calendar.isDate(meeting.startedAt, inSameDayAs: now) { return .today(meeting.startedAt) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(meeting.startedAt, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .earlier(meeting.startedAt)
    }
}

enum MenuBarRecordingHabit: Equatable {
    case appDetected(String)
    case recordsAutomatically
    case asksFirst
    case manualOnly

    static func habit(detectedApp: String?, mode: AppSettings.AutoRecordMode) -> MenuBarRecordingHabit {
        if let detectedApp, !detectedApp.isEmpty { return .appDetected(detectedApp) }
        switch mode {
        case .automatic: return .recordsAutomatically
        case .ask: return .asksFirst
        case .manual: return .manualOnly
        }
    }
}

struct MenuBarAudioLine: Equatable {
    struct Source: Equatable {
        let status: String
        let tone: MemoryHealthTone
        var isReceiving: Bool { tone == .good }
    }

    let microphone: Source
    let callAudio: Source?
    let callAudioLevel: Double?

    init(_ health: RecordingMemoryHealthSnapshot) {
        microphone = Source(status: health.microphoneStatus, tone: MemoryHealthTone.audio(health.microphoneStatus))
        if health.recordsMicrophoneOnly {
            callAudio = nil
            callAudioLevel = nil
        } else {
            callAudio = Source(
                status: health.systemAudioStatus, tone: MemoryHealthTone.audio(health.systemAudioStatus))
            callAudioLevel = health.systemAudioLevel
        }
    }
}
