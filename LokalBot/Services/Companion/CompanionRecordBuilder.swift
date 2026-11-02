import Foundation

/// Turns a `CompanionLibrary` into companion records. Pure reads: every field
/// a record carries is chosen here, from display-ready sources, so attendee
/// emails, speaker evidence, screenshot paths and OCR text never enter one.
/// Run off the main actor; `activity` is a read-only connection owned by the
/// calling thread.
struct CompanionRecordBuilder {
    let library: CompanionLibrary
    let activity: ActivityStore?
    private let peopleByMeeting: [UUID: [CompanionNamedRef]]
    private let projectsByMeeting: [UUID: [CompanionProjectRef]]

    init(library: CompanionLibrary, activity: ActivityStore? = nil) {
        self.library = library
        self.activity = activity
        var people: [UUID: [CompanionNamedRef]] = [:]
        for person in library.people {
            for meeting in person.meetings {
                people[meeting.id, default: []].append(CompanionNamedRef(id: person.id, displayName: person.name))
            }
        }
        var projects: [UUID: [CompanionProjectRef]] = [:]
        for project in library.projects {
            guard let id = project.trackedID else { continue }
            for meeting in project.meetings {
                projects[meeting.id, default: []].append(CompanionProjectRef(id: CompanionJSON.id(id), name: project.name))
            }
        }
        peopleByMeeting = people
        projectsByMeeting = projects
    }

    private var classes: CompanionSharing.DataClasses { library.scope.dataClasses }
    private var calendar: Calendar { library.calendar }
    private var root: URL { library.root }

    // MARK: - Everything

    /// Every record the current scope shares, manifest excluded.
    func allRecords() -> [CompanionRecord] {
        var records: [CompanionRecord] = []
        for meeting in library.meetings {
            records += meetingRecords(for: meeting)
        }
        records += dayKeys().compactMap(dayRecord(forKey:))
        records += personRecords()
        records += projectRecords()
        return records
    }

    static func manifest(sharing: CompanionSharing, macName: String,
                         libraryName: String = "LokalBot", now: Date = Date()) -> String? {
        try? CompanionJSON.encode(CompanionManifestBody(
            libraryName: libraryName,
            macName: macName,
            dataClasses: sharing.dataClasses.effective,
            historyDays: sharing.history.rawValue,
            askEnabled: sharing.answersQuestions,
            generatedAt: CompanionJSON.instant(now)))
    }

    // MARK: - Meetings

    /// The meeting record and, when transcripts are shared, its transcript.
    func meetingRecords(for meeting: Meeting) -> [CompanionRecord] {
        guard classes.meetings,
              CompanionLibrary.isShared(meeting, history: library.scope.history,
                                        now: library.now, calendar: calendar) else { return [] }
        let folder = root.appendingPathComponent(meeting.relativePath, isDirectory: true)
        let transcript = Self.loadTranscript(in: folder, meeting: meeting)
        let presentation = MeetingSpeakerPresentation(transcript: transcript)
        let transcriptBody = classes.sharesTranscripts
            ? Self.transcriptBody(meeting: meeting, transcript: transcript, presentation: presentation)
            : nil
        guard let body = meetingBody(meeting, folder: folder, transcript: transcript,
                                     presentation: presentation, hasTranscript: transcriptBody != nil),
              let json = try? CompanionJSON.encode(body) else { return [] }
        var records = [CompanionRecord(kind: .meeting, key: body.id, bodyJSON: json)]
        if let transcriptBody, let transcriptJSON = try? CompanionJSON.encode(transcriptBody) {
            records.append(CompanionRecord(kind: .transcript, key: body.id, bodyJSON: transcriptJSON))
        }
        return records
    }

    private func meetingBody(
        _ meeting: Meeting, folder: URL, transcript: Transcript?,
        presentation: MeetingSpeakerPresentation, hasTranscript: Bool
    ) -> CompanionMeetingBody? {
        guard let endedAt = meeting.endedAt else { return nil }
        let projection = library.projections[meeting.id]
        func speaker(_ key: String) -> String? {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let transcript { return presentation.speaker(trimmed, in: transcript) }
            return SpeakerDisplayName.label(Transcript.defaultSpeakerName(for: trimmed))
        }
        func citations(_ list: [OutcomeSourceCitation]) -> [CompanionCitation] {
            list.map {
                CompanionCitation(start: $0.start, end: $0.end, speaker: speaker($0.speaker),
                                  excerpt: $0.excerpt)
            }
        }
        let actions = (projection?.actionReferences ?? []).map { reference -> CompanionAction in
            let ownerIsUser = reference.isForUser
            let ownerUnclear = !ownerIsUser && (reference.ownerWasCorrected
                ? reference.owner == nil : reference.action.ownershipIsUnclear)
            let owner: String? = ownerIsUser
                ? presentation.owner("Me", isForUser: true)
                : (ownerUnclear ? nil : reference.owner.map { presentation.owner($0, isForUser: false) })
            let due = reference.due?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CompanionAction(
                id: reference.action.id,
                text: reference.text,
                owner: owner,
                ownerIsUser: ownerIsUser,
                ownerUnclear: ownerUnclear,
                dueDate: reference.resolvedDueDate.map { CompanionJSON.day($0, calendar: calendar) },
                dueText: due?.isEmpty == false ? due : nil,
                status: reference.status.rawValue,
                importance: reference.action.importance,
                citations: citations(reference.action.citations))
        }
        let decisions = (projection?.outcomes.decisionRecords ?? []).map {
            CompanionStatement(id: $0.id, text: $0.text, citations: citations($0.citations))
        }
        let questions = (projection?.outcomes.openQuestions ?? []).map {
            CompanionStatement(id: MeetingOutcomes.stableID(kind: "question", text: $0), text: $0, citations: [])
        }
        let summary = (try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8))
            .flatMap { Self.shareableSummary($0, meeting: meeting) }
        let app = meeting.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = meeting.recordedDuration ?? meeting.duration ?? 0
        return CompanionMeetingBody(
            id: CompanionJSON.id(meeting.id),
            title: meeting.displayTitle,
            startedAt: CompanionJSON.instant(meeting.startedAt),
            endedAt: CompanionJSON.instant(endedAt),
            day: CompanionJSON.day(meeting.startedAt, calendar: calendar),
            timeZoneOffsetMinutes: calendar.timeZone.secondsFromGMT(for: meeting.startedAt) / 60,
            durationSeconds: max(0, duration),
            appName: app.isEmpty ? nil : app,
            people: peopleByMeeting[meeting.id] ?? [],
            projects: projectsByMeeting[meeting.id] ?? [],
            summaryMarkdown: summary.map { CompanionDigestText.rewritingScreenCitations($0, time: screenTime, calendar: calendar) },
            notesMarkdown: MeetingNotes.load(from: folder),
            actions: actions,
            decisions: decisions,
            openQuestions: questions,
            hasTranscript: hasTranscript,
            mergedInto: nil)
    }

    /// The summary as the Meetings page shows it: no provenance line and no
    /// title heading, which the phone draws from the record itself.
    static func shareableSummary(_ markdown: String, meeting: Meeting) -> String? {
        let body = SummaryPresentation.meetingBody(SummaryPresentation.split(markdown).body, meeting: meeting)
        var lines = body.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].hasPrefix("# ") {
            lines.remove(at: first)
        }
        let text = SummaryPresentation.split(lines.joined(separator: "\n")).body
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func loadTranscript(in folder: URL, meeting: Meeting) -> Transcript? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else { return nil }
        guard let range = meeting.contentRange, range.isValid else { return transcript }
        return range.applying(to: transcript)
    }

    /// Display text, times, display names and a stable color per speaker;
    /// never attribution, identity evidence or calendar identity links.
    static func transcriptBody(meeting: Meeting, transcript: Transcript?,
                               presentation: MeetingSpeakerPresentation) -> CompanionTranscriptBody? {
        guard let transcript else { return nil }
        let segments = transcript.segments.compactMap { segment -> CompanionTranscriptBody.Segment? in
            let text = segment.displayText
            guard !text.isEmpty else { return nil }
            return CompanionTranscriptBody.Segment(
                start: segment.start, end: segment.end,
                speaker: presentation.speaker(segment.speaker, in: transcript),
                colorIndex: colorIndex(presentation.colorIndex(for: segment.speaker), speaker: segment.speaker),
                text: text)
        }
        guard !segments.isEmpty else { return nil }
        return CompanionTranscriptBody(meetingId: CompanionJSON.id(meeting.id), segments: segments)
    }

    /// 0 is the person themselves, 1–7 the speaker palette in order of first
    /// appearance, -1 a voice that could not be told apart.
    static func colorIndex(_ presentationIndex: Int, speaker: String) -> Int {
        if Transcript.defaultSpeakerName(for: speaker) == "Speaker unclear" { return -1 }
        guard presentationIndex > 0 else { return 0 }
        return (presentationIndex - 1) % 7 + 1
    }

    // MARK: - Days

    /// Days that have a digest, recorded activity, or a shared meeting,
    /// inside the history window, newest first.
    func dayKeys() -> [String] {
        var keys: Set<String> = []
        let start = library.scope.history.startOfWindow(now: library.now, calendar: calendar)
        func inWindow(_ date: Date) -> Bool { start.map { date >= $0 } ?? true }
        if classes.meetings || classes.timeline {
            for meeting in library.meetings { keys.insert(CompanionJSON.day(meeting.startedAt, calendar: calendar)) }
        }
        if classes.digests {
            let folder = root.appendingPathComponent("journal", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for file in files where file.hasSuffix(".md") {
                let key = String(file.dropLast(3))
                guard AskDayScope.isCanonicalKey(key),
                      let date = AskDayScope.date(for: key, calendar: calendar), inWindow(date) else { continue }
                keys.insert(key)
            }
        }
        if classes.timeline, let activity, let earliest = activity.earliestActivityStart() {
            var day = calendar.startOfDay(for: max(earliest, start ?? earliest))
            let today = calendar.startOfDay(for: library.now)
            while day <= today {
                let interval = ActivityStore.dayInterval(containing: day, calendar: calendar)
                if activity.hasActivity(in: interval) { keys.insert(CompanionJSON.day(day, calendar: calendar)) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return keys.sorted(by: >)
    }

    func dayRecord(forKey key: String) -> CompanionRecord? {
        guard let day = AskDayScope.date(for: key, calendar: calendar),
              library.scope.history.contains(day, now: library.now, calendar: calendar) else { return nil }
        let interval = ActivityStore.dayInterval(containing: day, calendar: calendar)
        let meetings = library.meetings
            .filter { interval.contains($0.startedAt) }
            .sorted { $0.startedAt < $1.startedAt }
        let digest = digest(forKey: key)
        let timeline = timeline(for: day, interval: interval, meetings: meetings)
        let meetingIDs = classes.meetings ? meetings.map { CompanionJSON.id($0.id) } : []
        let hasActivity = timeline.map { !$0.sessions.isEmpty || !$0.savedMoments.isEmpty } ?? false
        guard digest != nil || hasActivity || !meetingIDs.isEmpty else { return nil }
        let body = CompanionDayBody(date: key, digest: digest, timeline: timeline, meetingIds: meetingIDs)
        guard let json = try? CompanionJSON.encode(body) else { return nil }
        return CompanionRecord(kind: .day, key: key, bodyJSON: json)
    }

    private func digest(forKey key: String) -> CompanionDayBody.Digest? {
        guard classes.digests else { return nil }
        let url = root.appendingPathComponent("journal/\(key).md")
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let metadata = DayDigestGenerationMetadataStore.loadWithoutRecovery(for: url)
        let generated = metadata.map { DayDigestGenerationMetadataStore.journalMatches($0, at: url) } ?? false
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let generatedAt = generated ? metadata?.generatedAt : modified
        let markdown = CompanionDigestText.shareable(raw, time: screenTime, calendar: calendar)
        let presentation = DayDigestPresentation(markdown: markdown)
        func line(_ block: DayDigestPresentation.FocusBlock) -> String? {
            let text = (block.title ?? block.summaryMarkdown).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return CompanionDayBody.Digest(
            markdown: markdown,
            generatedAt: generatedAt.map(CompanionJSON.instant),
            userEdited: !generated,
            sections: .init(
                highlights: CompanionDigestText.items(in: presentation.atAGlanceMarkdown),
                decisions: presentation.decisions,
                tasks: presentation.focusBlocks.compactMap(line),
                blockers: presentation.blockers,
                followUps: presentation.followUps.compactMap(line)
                    + presentation.focusBlocks.compactMap(\.nextStep)))
    }

    private func timeline(for day: Date, interval: DateInterval, meetings: [Meeting]) -> CompanionDayBody.Timeline? {
        guard classes.timeline else { return nil }
        let blocks = activity?.blocks(in: interval) ?? []
        let bursts = activity?.codingAgentBursts(in: interval) ?? []
        let projection = DayActivityProjection(blocks: blocks, day: day, agentBursts: bursts, calendar: calendar)
        var sessions = projection.sessions.map(workSession)
        for task in TimelineAgentTask.tasks(from: projection.attribution.bursts) {
            let seconds = task.bursts.reduce(0) { $0 + $1.activeDuration }
            sessions.append(.init(
                start: CompanionJSON.instant(task.start), end: CompanionJSON.instant(task.end),
                title: task.title, kind: "agent", project: task.project,
                apps: [.init(name: task.agent.displayName, seconds: seconds)]))
        }
        if classes.meetings {
            for meeting in meetings {
                let end = meeting.endedAt ?? meeting.startedAt
                let app = meeting.appName.trimmingCharacters(in: .whitespacesAndNewlines)
                sessions.append(.init(
                    start: CompanionJSON.instant(meeting.startedAt), end: CompanionJSON.instant(end),
                    title: meeting.displayTitle, kind: "meeting", meetingId: CompanionJSON.id(meeting.id),
                    project: projectsByMeeting[meeting.id]?.first?.name,
                    apps: app.isEmpty ? [] : [.init(name: app, seconds: max(0, end.timeIntervalSince(meeting.startedAt)))]))
            }
        }
        sessions.sort { $0.start == $1.start ? $0.kind < $1.kind : $0.start < $1.start }
        let split = projection.attribution.split(of: projection.blocks)
        var byProject = split.projects.map { CompanionDayBody.Seconds(name: $0.project, seconds: $0.seconds) }
        if !byProject.isEmpty, split.unattributedSeconds > 0 {
            byProject.append(.init(name: "Other", seconds: split.unattributedSeconds))
        }
        byProject.sort { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }
        let moments = (activity?.savedMoments(in: interval) ?? []).map { moment -> CompanionDayBody.SavedMoment in
            let note = moment.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = moment.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = !note.isEmpty ? note
                : (classes.sharesWindowTitles && !title.isEmpty ? title : moment.app)
            return .init(at: CompanionJSON.instant(moment.ts), label: label)
        }
        return CompanionDayBody.Timeline(
            trackedSeconds: projection.activeSeconds,
            sessions: sessions,
            byProject: byProject,
            byApp: projection.perApp.map { .init(name: $0.key, seconds: $0.value) },
            savedMoments: moments)
    }

    /// A work session as the Timeline rail shows it. Without the window
    /// titles class, a title made from window titles falls back to the
    /// session's project or apps.
    private func workSession(_ session: TimelineWorkSession) -> CompanionDayBody.Session {
        let byApp: [String: [ActivityBlock]] = Dictionary(grouping: session.blocks) { (block: ActivityBlock) in block.app }
        var apps: [CompanionDayBody.Seconds] = []
        for (name, blocks) in byApp {
            apps.append(CompanionDayBody.Seconds(name: name, seconds: TimelineWorkSession.mergedDuration(blocks)))
        }
        apps.sort { lhs, rhs in lhs.seconds == rhs.seconds ? lhs.name < rhs.name : lhs.seconds > rhs.seconds }
        var title = session.title
        let namesWindow = session.notableTitles.contains { !$0.isEmpty && title.localizedCaseInsensitiveContains($0) }
        if !classes.sharesWindowTitles, !session.titleNamesApps, namesWindow {
            title = session.project ?? TimelineWorkSession.appSummary(apps.map { $0.name })
        }
        let titles: [String] = session.titleEvidence.filter { $0.duration >= 60 }.prefix(6).map { $0.title }
        return CompanionDayBody.Session(
            start: CompanionJSON.instant(session.start),
            end: CompanionJSON.instant(session.end),
            title: title,
            kind: "work",
            project: session.project,
            apps: apps,
            windowTitles: classes.sharesWindowTitles && !titles.isEmpty ? titles : nil)
    }

    private var screenTime: (Int64) -> Date? {
        { [activity] id in activity?.screenshot(id: id)?.ts }
    }

    // MARK: - People and projects

    func personRecords() -> [CompanionRecord] {
        guard classes.people else { return [] }
        return library.people.compactMap { person in
            let body = CompanionPersonBody(
                id: person.id,
                displayName: person.name,
                lastMetAt: person.lastMetAt.map(CompanionJSON.instant),
                openWork: openWork(person.theirActions, theirs: true) + openWork(person.myActions, theirs: false),
                decisionsTogether: person.decisions.map {
                    .init(meetingId: CompanionJSON.id($0.meetingID), text: $0.text)
                },
                meetingIds: person.meetings.map { CompanionJSON.id($0.id) })
            guard let json = try? CompanionJSON.encode(body) else { return nil }
            return CompanionRecord(kind: .person, key: person.id, bodyJSON: json)
        }
    }

    private func openWork(_ threads: [ActionThread], theirs: Bool) -> [CompanionPersonBody.OpenWork] {
        threads.filter { $0.status == .open }.map { thread in
            let reference = thread.latestReference
            return .init(meetingId: CompanionJSON.id(reference.meetingID), actionId: reference.action.id,
                         text: thread.text,
                         dueDate: thread.resolvedDueDate.map { CompanionJSON.day($0, calendar: calendar) },
                         theirs: theirs)
        }
    }

    func projectRecords() -> [CompanionRecord] {
        guard classes.projects else { return [] }
        let peopleByName = Dictionary(
            library.people.flatMap { person in
                ([person.name] + person.otherNames).map { (PeopleDirectory.normalized($0), person) }
            },
            uniquingKeysWith: { first, _ in first })
        return library.projects.compactMap { project in
            guard let trackedID = project.trackedID else { return nil }
            let key = CompanionJSON.id(trackedID)
            var seen: Set<String> = []
            let people = project.people.compactMap { name -> CompanionNamedRef? in
                guard let person = peopleByName[PeopleDirectory.normalized(name)],
                      seen.insert(person.id).inserted else { return nil }
                return CompanionNamedRef(id: person.id, displayName: person.name)
            }
            let body = CompanionProjectBody(
                id: key,
                name: project.name,
                whereItStands: library.projectSummaries[trackedID].flatMap(Self.whereItStands),
                yourActions: project.myActions.filter { $0.status == .open }.map { thread in
                    let reference = thread.latestReference
                    return .init(meetingId: CompanionJSON.id(reference.meetingID), actionId: reference.action.id,
                                 text: thread.text,
                                 dueDate: thread.resolvedDueDate.map { CompanionJSON.day($0, calendar: calendar) },
                                 status: thread.status.rawValue)
                },
                waitingOnOthers: (project.othersActions + project.olderOthersActions)
                    .filter { $0.status == .open }.map { thread in
                        let reference = thread.latestReference
                        return .init(meetingId: CompanionJSON.id(reference.meetingID), actionId: reference.action.id,
                                     text: thread.text,
                                     owner: thread.owner.map { SpeakerDisplayName.label($0) },
                                     dueDate: thread.resolvedDueDate.map { CompanionJSON.day($0, calendar: calendar) })
                    },
                decisions: project.decisions.map { .init(meetingId: CompanionJSON.id($0.meetingID), text: $0.text) },
                timeThisWeekSeconds: project.trackedSeconds,
                people: people,
                meetingIds: project.meetings.map { CompanionJSON.id($0.id) })
            guard let json = try? CompanionJSON.encode(body) else { return nil }
            return CompanionRecord(kind: .project, key: key, bodyJSON: json)
        }
    }

    /// The note's overview and the points taken from meetings. Points from
    /// overnight review notes stay on the Mac with the rest of Dream memory.
    static func whereItStands(_ summary: ProjectStatusSummary) -> String? {
        var parts: [String] = []
        let overview = summary.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overview.isEmpty { parts.append(overview) }
        let points = summary.points.filter { $0.meetingID != nil }.map { "- \($0.text)" }
        if !points.isEmpty { parts.append(points.joined(separator: "\n")) }
        let questions = summary.openQuestions.map { "- \($0)" }
        if !questions.isEmpty { parts.append("**Open questions**\n" + questions.joined(separator: "\n")) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

/// Day Digest Markdown made fit for a phone: the raw evidence log, which
/// quotes screen text and window titles, stays on the Mac, and screen
/// citations become the time of the moment they point at.
enum CompanionDigestText {
    /// Level-2 sections LokalBot renders from raw capture rather than writes.
    static let evidenceSections: Set<String> = ["full activity log", "chronological work log"]

    static func shareable(_ markdown: String, time: (Int64) -> Date?, calendar: Calendar = .current) -> String {
        rewritingScreenCitations(removingEvidenceSections(markdown), time: time, calendar: calendar)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingEvidenceSections(_ markdown: String) -> String {
        var kept: [String] = []
        var skipping = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                skipping = evidenceSections.contains(title)
            } else if line.hasPrefix("# ") {
                skipping = false
            }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// `[screen:42]` becomes "(screen moment at 14:32)"; a marker whose
    /// capture is gone, and a bare `[screen]`, are dropped.
    static func rewritingScreenCitations(_ text: String, time: (Int64) -> Date?,
                                         calendar: Calendar = .current) -> String {
        guard text.contains("[screen"),
              let regex = try? NSRegularExpression(pattern: #"[ \t]?\[screen(?::(\d+))?\]"#) else { return text }
        var result = text
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var replacement = ""
            if match.range(at: 1).location != NSNotFound,
               let id = Int64(ns.substring(with: match.range(at: 1))), let date = time(id) {
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                replacement = String(format: " (screen moment at %02d:%02d)", parts.hour ?? 0, parts.minute ?? 0)
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// Top-level list items without their markers, or the paragraphs of a
    /// passage written as prose.
    static func items(in markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: "\n")
        let bullets = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !bullets.isEmpty { return bullets }
        return markdown.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
