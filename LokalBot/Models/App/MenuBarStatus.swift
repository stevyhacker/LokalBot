import Foundation

/// One thing the menu bar asks the person to fix. The panel's status block
/// leads with the first and lists the rest under it, and the status item
/// carries a dot while there is any.
enum MenuBarAttention: Equatable, Identifiable {
    /// A recording or dictation start was refused: only System Settings can
    /// turn the microphone back on.
    case microphoneRefused
    /// Microphone access has not been granted yet: setup asks for it.
    case microphoneNotGranted
    /// The app's latest error message, until it is dismissed.
    case error(String)
    /// Requests from the terminal waiting for an answer.
    case settingsApproval(count: Int)

    var id: String {
        switch self {
        case .microphoneRefused: "microphone-refused"
        case .microphoneNotGranted: "microphone-not-granted"
        case .error: "error"
        case .settingsApproval: "settings-approval"
        }
    }

    /// Everything waiting, most blocking first: what stops recording, then
    /// the latest error, then approvals. A refused microphone stands in for
    /// the ungranted one: both are the same switch, and once it was refused
    /// only System Settings can turn it on.
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

/// What the menu bar panel says LokalBot is doing, and the meetings listed
/// under it. Display-only; nothing here is stored or sent.
struct MenuBarStatus: Equatable {
    /// A calendar meeting leads the menu once it starts within this long, and
    /// keeps the block while under way and not being recorded. Shorter than
    /// Today's hour (`TodayAgenda.nextMeetingWindow`): the menu is a glance.
    static let soonWindow: TimeInterval = 15 * 60
    /// How long a recording that has just been saved is named in the block.
    static let justStoppedWindow: TimeInterval = 2 * 60
    static let recentMeetingLimit = 2

    /// What a dictation is doing while it holds the microphone.
    enum Dictation: Equatable {
        case starting
        case recording
        case transcribing
        case composing
    }

    /// The status block's one state. `init` picks it in this order:
    /// recording, dictating, needs attention, a meeting about to start, day
    /// memory paused, just stopped, idle. A recording or a dictation leads
    /// even when something needs attention, so Stop is never hidden; the
    /// waiting items are listed under it.
    enum Block: Equatable {
        case recording(Meeting)
        case dictating(Dictation)
        case attention(MenuBarAttention)
        case meetingSoon(CalendarMeetingCandidate)
        case paused
        case justStopped(Meeting)
        case idle
    }

    /// The block's one colour.
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
    /// Attention items listed under the block: every one while a recording
    /// or a dictation leads, the rest when the first of them is the block.
    let moreAttention: [MenuBarAttention]
    /// The latest meetings, the one just saved first.
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

    /// A recording with a capture warning turns amber and keeps its buttons.
    func tone(hasCaptureWarnings: Bool) -> Tone {
        switch block {
        case .recording: hasCaptureWarnings ? .attention : .recording
        // The microphone is live only while the dictation is being spoken.
        case .dictating(let phase): phase == .recording ? .recording : .neutral
        case .attention: .attention
        case .meetingSoon: .upcoming
        case .paused, .justStopped, .idle: .neutral
        }
    }

    /// The recording made on this Mac that ended within `justStoppedWindow`.
    /// An imported file was not just recorded, whenever its audio ends.
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

    /// The first meetings of the library, which lists the newest first, with
    /// the one just saved in front. Sources folded into a merged meeting and
    /// the recording in progress are not listed.
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

/// The line under "Not recording": what will make a recording start.
enum MenuBarRecordingHabit: Equatable {
    /// A meeting app is open and the detector sees it.
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

/// Whether sound is arriving from each source of the recording in progress,
/// for the one line the menu shows.
struct MenuBarAudioLine: Equatable {
    struct Source: Equatable {
        /// The recorder's own status words, such as "Receiving audio".
        let status: String
        let tone: MemoryHealthTone
        /// Sound is arriving, so the line names the source and no more.
        var isReceiving: Bool { tone == .good }
    }

    let microphone: Source
    /// Nil while only the microphone is recorded: no call is attached.
    let callAudio: Source?
    /// 0…1, when the call's audio was measured within the last second.
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
