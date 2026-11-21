import Foundation

enum TodayAgenda {
    static let nextMeetingWindow: TimeInterval = 60 * 60

    struct Entry: Identifiable, Equatable {
        enum Source: Equatable {
            case recording(Meeting)
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
        let isSoon: Bool

        var meeting: Meeting? {
            if case .recording(let meeting) = source { return meeting }
            return nil
        }
    }

    enum Row: Identifiable, Equatable {
        case entry(Entry)
        case now(Date)

        var id: String {
            switch self {
            case .entry(let entry): entry.id
            case .now: "now"
            }
        }
    }

    static func status(of event: CalendarMeetingCandidate, now: Date) -> Entry.Status {
        if event.endDate < now { return .ended }
        if event.startDate <= now { return .inProgress }
        let minutes = Int(event.startDate.timeIntervalSince(now) / 60)
        return minutes < 1 ? .startingNow : .upcoming(minutes: minutes)
    }

    static func recordedEventIDs(in recordings: [Meeting]) -> Set<String> {
        Set(recordings.compactMap(\.calendarEventID))
    }

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
            if (lhs.meeting != nil) != (rhs.meeting != nil) { return lhs.meeting != nil }
            return lhs.id < rhs.id
        }
    }

    static func rows(_ entries: [Entry], now: Date) -> [Row] {
        var rows = entries.map(Row.entry)
        if let next = entries.firstIndex(where: { $0.start > now }) {
            rows.insert(.now(now), at: next)
        }
        return rows
    }

    static func nextMeeting(
        in schedule: [CalendarMeetingCandidate],
        now: Date,
        recordedEventIDs: Set<String> = [],
        window: TimeInterval = nextMeetingWindow
    ) -> CalendarMeetingCandidate? {
        guard let next = UpcomingMeetingSelector.primary(
            from: schedule.filter { !recordedEventIDs.contains($0.externalID) }, now: now),
            next.endDate > now,
            next.startDate.timeIntervalSince(now) <= window else { return nil }
        return next
    }
}

enum TodayMeetingRecap {
    static let maximumCharacters = 220

    private static let overviewSections: Set<String> = ["tldr", "summary", "overview", "recap"]
    private static let stamp = #"\s*\(?\[\d{1,2}(?::\d{2}){1,2}\](?:\s*[–—-]\s*\[\d{1,2}(?::\d{2}){1,2}\])?\)?"#

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

enum TodayDigestHighlights {
    static let taskFallbackLimit = 3

    static func markdown(for digest: String?) -> String {
        guard let digest, !digest.isEmpty else { return "" }
        let presentation = DayDigestPresentation(markdown: digest)
        let glance = presentation.atAGlanceMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !glance.isEmpty { return glance }
        return presentation.focusBlocks.compactMap(\.title).prefix(taskFallbackLimit)
            .map { "- \($0)" }.joined(separator: "\n")
    }
}

enum TodayDigestLine: Equatable {
    case writing
    case missing
    case current(writtenAt: Date?)
    case stale(writtenAt: Date?)

    static func state(hasDigest: Bool, writtenAt: Date?, isStale: Bool, isWriting: Bool) -> TodayDigestLine {
        if isWriting { return .writing }
        guard hasDigest else { return .missing }
        return isStale ? .stale(writtenAt: writtenAt) : .current(writtenAt: writtenAt)
    }
}

enum TodayPageLayout: Equatable {
    case sections(gettingStartedBelow: Bool)
    case gettingStarted
    case placeholder

    var showsSections: Bool {
        if case .sections = self { return true }
        return false
    }

    static func layout(hasContent: Bool, gettingStartedDismissed: Bool) -> TodayPageLayout {
        if hasContent { return .sections(gettingStartedBelow: !gettingStartedDismissed) }
        return gettingStartedDismissed ? .placeholder : .gettingStarted
    }
}

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
        let source: String
        let date: Date?
        var awaitingReply = false
        var target: Target?
    }

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

    static func moreRows(_ evidence: UpcomingMeetingEvidence) -> [Row] {
        evidence.decisions.dropFirst().map(row)
            + evidence.commitments.dropFirst().map(row)
            + evidence.projects.dropFirst().map(row)
            + evidence.emailThreads.dropFirst().map(row)
    }

    static func count(_ evidence: UpcomingMeetingEvidence) -> Int {
        primaryRows(evidence).count + moreRows(evidence).count
    }

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
