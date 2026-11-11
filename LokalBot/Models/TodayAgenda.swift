import Foundation

/// Today's one list of meetings: what was recorded and what the calendar
/// holds, in time order. Display-only; nothing here is stored or sent.
enum TodayAgenda {
    /// A calendar meeting earns the card at the top of Today once it starts
    /// within the hour, and keeps it while under way and not being recorded.
    static let nextMeetingWindow: TimeInterval = 60 * 60

    struct Entry: Identifiable, Equatable {
        enum Source: Equatable {
            /// A recording made today, in progress or saved.
            case recording(Meeting)
            /// A calendar event nothing was recorded for.
            case event(CalendarMeetingCandidate)
        }

        enum Status: Equatable {
            case recording
            case recorded
            case ended
            case inProgress
            case startingNow
            case upcoming(minutes: Int)
        }

        let id: String
        let source: Source
        let title: String
        let start: Date
        let status: Status
        /// Starts within `nextMeetingWindow`, so its status reads in the accent.
        let isSoon: Bool

        var meeting: Meeting? {
            if case .recording(let meeting) = source { return meeting }
            return nil
        }
    }

    enum Row: Identifiable, Equatable {
        case entry(Entry)
        /// The thin line between what has started and what is still ahead.
        case now(Date)

        var id: String {
            switch self {
            case .entry(let entry): entry.id
            case .now: "now"
            }
        }
    }

    /// Where a calendar event stands at `now`.
    static func status(of event: CalendarMeetingCandidate, now: Date) -> Entry.Status {
        if event.endDate < now { return .ended }
        if event.startDate <= now { return .inProgress }
        let minutes = Int(event.startDate.timeIntervalSince(now) / 60)
        return minutes < 1 ? .startingNow : .upcoming(minutes: minutes)
    }

    /// Calendar events some recording is already linked to. They are listed
    /// once, as that recording, and never offered again as the next meeting.
    static func recordedEventIDs(in recordings: [Meeting]) -> Set<String> {
        Set(recordings.compactMap(\.calendarEventID))
    }

    /// Today's recordings and calendar events as one list, earliest first. A
    /// recording that stores its calendar event stands in for that event.
    static func entries(
        recordings: [Meeting],
        events: [CalendarMeetingCandidate],
        liveMeetingID: Meeting.ID?,
        now: Date,
        calendar: Calendar = .current
    ) -> [Entry] {
        var seen = Set<Meeting.ID>()
        let today = recordings.filter { meeting in
            meeting.isOwnWork
                && calendar.isDate(meeting.startedAt, inSameDayAs: now)
                && seen.insert(meeting.id).inserted
        }
        // Any recording claims its event, a merged source included.
        let recorded = recordedEventIDs(in: recordings)
        let recordingEntries = today.map { meeting in
            Entry(id: "recording-\(meeting.id.uuidString)",
                  source: .recording(meeting),
                  title: meeting.displayTitle,
                  start: meeting.startedAt,
                  status: meeting.id == liveMeetingID ? .recording : .recorded,
                  isSoon: false)
        }
        var seenEvents = Set<String>()
        let eventEntries = events
            .filter { !recorded.contains($0.externalID) && seenEvents.insert($0.externalID).inserted }
            .map { event in
                let start = event.startDate.timeIntervalSince(now)
                return Entry(id: "event-\(event.externalID)",
                             source: .event(event),
                             title: event.title,
                             start: event.startDate,
                             status: status(of: event, now: now),
                             isSoon: start > 0 && start <= nextMeetingWindow)
            }
        return (recordingEntries + eventEntries).sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            // At the same minute the recording is the thing that happened.
            if (lhs.meeting != nil) != (rhs.meeting != nil) { return lhs.meeting != nil }
            return lhs.id < rhs.id
        }
    }

    /// The list with the now line before the first entry still ahead. A day
    /// with nothing ahead has no line.
    static func rows(_ entries: [Entry], now: Date) -> [Row] {
        var rows = entries.map(Row.entry)
        if let next = entries.firstIndex(where: { $0.start > now }) {
            rows.insert(.now(now), at: next)
        }
        return rows
    }

    /// The meeting for the card at the top of Today: the one under way, or
    /// the next one once it is within `nextMeetingWindow`. Events already
    /// recorded, and the one being recorded now, are passed over.
    static func nextMeeting(
        in schedule: [CalendarMeetingCandidate],
        now: Date,
        recordedEventIDs: Set<String> = []
    ) -> CalendarMeetingCandidate? {
        guard let next = UpcomingMeetingSelector.primary(
            from: schedule.filter { !recordedEventIDs.contains($0.externalID) }, now: now),
            next.endDate > now,
            next.startDate.timeIntervalSince(now) <= nextMeetingWindow else { return nil }
        return next
    }
}

/// One line saying what a recorded meeting was about, taken from the summary
/// already saved beside it. No model runs for this.
enum TodayMeetingRecap {
    static let maximumCharacters = 220

    private static let overviewSections: Set<String> = ["tldr", "summary", "overview", "recap"]
    private static let stamp = #"\s*\(?\[\d{1,2}(?::\d{2}){1,2}\](?:\s*[–—-]\s*\[\d{1,2}(?::\d{2}){1,2}\])?\)?"#

    /// The first sentence-like line under the summary's TL;DR (or Summary,
    /// Overview, Recap) heading; nil when the summary has no such section.
    static func line(fromSummary markdown: String) -> String? {
        var inOverview = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let title = line[heading.upperBound...].lowercased().filter(\.isLetter)
                inOverview = overviewSections.contains(title)
                continue
            }
            guard inOverview, !line.isEmpty else { continue }
            if let marker = line.range(of: #"^(?:[-*•]|\d+[.)])\s+"#, options: .regularExpression) {
                line.removeSubrange(marker)
            }
            // Checkbox bullets are actions, not a recap.
            guard !line.hasPrefix("[") else { continue }
            if let speaker = line.range(of: #"^\*\*[^*]{1,48}?:\*\*\s*"#, options: .regularExpression) {
                line.removeSubrange(speaker)
            }
            line = line.replacingOccurrences(of: stamp, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*[—–-]\s*$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let letters = line.lowercased().filter(\.isLetter)
            guard line.count >= 8, letters != "none" else { continue }
            return shortened(line)
        }
        return nil
    }

    private static func shortened(_ text: String) -> String {
        guard text.count > maximumCharacters else { return text }
        let cut = text.prefix(maximumCharacters)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    /// Reads each meeting's saved `summary.md`. Small files, read off the
    /// main thread by the caller.
    static func lines(for meetings: [Meeting], root: URL) -> [Meeting.ID: String] {
        var result: [Meeting.ID: String] = [:]
        for meeting in meetings {
            let url = root.appendingPathComponent(meeting.relativePath).appendingPathComponent("summary.md")
            guard let summary = try? String(contentsOf: url, encoding: .utf8),
                  let line = line(fromSummary: summary) else { continue }
            result[meeting.id] = line
        }
        return result
    }
}

/// The few lines of the day digest that Today shows. The rest of the digest
/// (tasks, decisions, follow-ups, the activity log) is on Timeline.
enum TodayDigestHighlights {
    static let taskFallbackLimit = 3

    /// The digest's "At a glance" lines; a digest without them falls back to
    /// the titles of its first tasks.
    static func markdown(for digest: String?) -> String {
        guard let digest, !digest.isEmpty else { return "" }
        let presentation = DayDigestPresentation(markdown: digest)
        let glance = presentation.atAGlanceMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !glance.isEmpty { return glance }
        return presentation.focusBlocks.compactMap(\.title).prefix(taskFallbackLimit)
            .map { "- \($0)" }.joined(separator: "\n")
    }
}

/// The one line under So far today that says where the digest stands.
enum TodayDigestLine: Equatable {
    /// A digest is being written, by hand or on schedule.
    case writing
    /// No digest for today yet.
    case missing
    case current(writtenAt: Date?)
    /// Activity arrived after the digest was written; Update rewrites it.
    case stale(writtenAt: Date?)

    static func state(hasDigest: Bool, writtenAt: Date?, isStale: Bool, isWriting: Bool) -> TodayDigestLine {
        if isWriting { return .writing }
        guard hasDigest else { return .missing }
        return isStale ? .stale(writtenAt: writtenAt) : .current(writtenAt: writtenAt)
    }
}

/// What the page is made of right now.
enum TodayPageLayout: Equatable {
    /// The day's sections. Getting started stays under them until hidden.
    case sections(gettingStartedBelow: Bool)
    /// Nothing to show yet: the Getting started steps are the page.
    case gettingStarted
    /// Nothing to show and Getting started is hidden.
    case placeholder

    static func layout(hasContent: Bool, gettingStartedDismissed: Bool) -> TodayPageLayout {
        if hasContent { return .sections(gettingStartedBelow: !gettingStartedDismissed) }
        return gettingStartedDismissed ? .placeholder : .gettingStarted
    }
}

/// The "Before you join" rows of the next-meeting card, built from the
/// evidence the preparation model already selected.
enum TodayPreparation {
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable { case decision, commitment, project, email, recentMeeting }
        enum Target: Equatable {
            case meeting(Meeting.ID)
            case link(URL)
        }

        let id: String
        let kind: Kind
        let text: String
        /// Where it comes from: a meeting title, an owner or a sender.
        let source: String
        let date: Date?
        /// An email whose latest message asks something still unanswered.
        var awaitingReply = false
        var target: Target?
    }

    /// One row of each kind the evidence holds. A meeting with no decisions,
    /// commitments or projects falls back to the closest earlier meeting.
    static func primaryRows(_ evidence: UpcomingMeetingEvidence) -> [Row] {
        var rows: [Row] = []
        if let decision = evidence.decisions.first { rows.append(row(decision)) }
        if let commitment = evidence.commitments.first { rows.append(row(commitment)) }
        if let project = evidence.projects.first { rows.append(row(project)) }
        if let thread = evidence.emailThreads.first { rows.append(row(thread)) }
        if evidence.decisions.isEmpty, evidence.commitments.isEmpty, evidence.projects.isEmpty,
           let related = evidence.relatedMeetings.first {
            rows.append(Row(id: "related-\(related.meeting.id.uuidString)", kind: .recentMeeting,
                            text: related.meeting.displayTitle, source: "",
                            date: related.meeting.startedAt, target: .meeting(related.meeting.id)))
        }
        return rows
    }

    /// Everything past the first of each kind.
    static func moreRows(_ evidence: UpcomingMeetingEvidence) -> [Row] {
        evidence.decisions.dropFirst().map(row)
            + evidence.commitments.dropFirst().map(row)
            + evidence.projects.dropFirst().map(row)
            + evidence.emailThreads.dropFirst().map(row)
    }

    /// The count the collapsed card shows.
    static func count(_ evidence: UpcomingMeetingEvidence) -> Int {
        primaryRows(evidence).count + moreRows(evidence).count
    }

    /// A brief the model wrote is always shown. The template brief only
    /// restates the rows, so it is shown when there are no rows to read.
    static func showsBrief(generatedByModel: Bool, rowCount: Int) -> Bool {
        generatedByModel || rowCount == 0
    }

    private static func row(_ reference: UpcomingMeetingReference) -> Row {
        let owner = reference.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isCommitment = reference.kind == .commitment
        let source = isCommitment && !owner.isEmpty
            ? SpeakerDisplayName.label(owner, identity: reference.isForUser ? .user : .unresolved)
            : reference.meetingTitle
        return Row(id: "\(reference.kind.rawValue)-\(reference.id)",
                   kind: isCommitment ? .commitment : .decision,
                   text: reference.text, source: source, date: reference.meetingDate,
                   target: .meeting(reference.meetingID))
    }

    private static func row(_ project: UpcomingMeetingProjectContext) -> Row {
        Row(id: "project-\(project.id)", kind: .project,
            text: "\(project.name) — \(project.status)", source: "",
            date: DreamDay.date(fromKey: project.lastActiveDay))
    }

    private static func row(_ thread: UpcomingMeetingEmailThread) -> Row {
        Row(id: "email-\(thread.id)", kind: .email, text: thread.subject, source: thread.lastSender,
            date: thread.lastMessageAt, awaitingReply: thread.awaitingReply, target: .link(thread.gmailURL))
    }
}
