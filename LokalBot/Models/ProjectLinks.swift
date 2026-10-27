import Foundation

/// A project joined to the evidence behind it: meetings, open action threads,
/// decisions, overnight review notes, people, and tracked window time.
/// Tracked projects are the ones the person chose to follow; suggestions are
/// names that recur across meetings and overnight review projects nobody
/// tracks yet. Matching is deterministic word matching on the project's
/// names; no model decides what belongs to a project.
struct ProjectProfile: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case tracked(UUID)
        /// A name that recurs across meetings.
        case suggestedTopic
        /// An overnight review project no tracked project covers.
        case suggestedReview
    }

    /// A line that names the project, cut to fit around the name.
    struct Mention: Equatable, Sendable {
        let text: String
        /// Transcript time to open the meeting at, for transcript lines.
        let seek: TimeInterval?
    }

    struct MeetingRef: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        let startedAt: Date
        /// Summary lines naming the project, else transcript lines, else the
        /// action or decision that names it.
        var mentions: [Mention]

        var mention: Mention? { mentions.first }
    }

    struct ReviewNote: Identifiable, Equatable, Sendable {
        var id: String { name }
        let name: String
        let status: String
        let lastActiveDay: String
    }

    struct WindowTime: Identifiable, Equatable, Sendable {
        var id: String { app + "|" + title }
        let app: String
        let title: String
        let seconds: TimeInterval
    }

    struct DayTime: Identifiable, Equatable, Sendable {
        var id: String { dayKey }
        let dayKey: String
        let seconds: TimeInterval
    }

    let id: String
    let name: String
    let kind: Kind
    let otherNames: [String]
    var meetings: [MeetingRef]
    /// The user's open work on the project.
    var myActions: [ActionThread]
    /// Other people's open work mentioned recently or due ahead.
    var othersActions: [ActionThread]
    /// Other people's open work last mentioned long ago; shown on request.
    var olderOthersActions: [ActionThread]
    var decisions: [PersonProfile.DecisionRef]
    /// Overnight review entries about this project.
    var reviewNotes: [ReviewNote]
    /// Tracked time in the reviewed window, newest day first.
    var days: [DayTime]
    var windows: [WindowTime]
    var people: [String]
    /// The newest meeting, review note, or tracked window time.
    var lastActive: Date?

    var trackedID: UUID? {
        if case .tracked(let id) = kind { return id }
        return nil
    }
    var isTracked: Bool { trackedID != nil }
    var openActionCount: Int { myActions.count + othersActions.count }
    var trackedSeconds: TimeInterval { days.reduce(0) { $0 + $1.seconds } }
    var meetingIDs: Set<UUID> { Set(meetings.map(\.id)) }
}

enum ProjectLinks {
    static let reviewDays = 7
    static let maximumWindows = 6
    static let maximumDecisions = 8
    static let maximumMentionCharacters = 180
    static let maximumMentionsPerMeeting = 3
    /// Other people's open actions move behind "Show older" when their last
    /// mention is older than this and no due day lies ahead.
    static let recentOthersActionDays = 14

    /// One rendered transcript line ("**[00:13:21] Them 3:** text").
    struct TranscriptLine: Equatable, Sendable {
        let start: TimeInterval
        let text: String
    }

    /// A meeting's transcript lines and their normalized words, cached by the
    /// caller so a refresh does not re-read and re-fold every transcript.
    struct TranscriptText: Equatable, Sendable {
        let lines: [TranscriptLine]
        /// Each line case- and diacritic-folded, for a quick substring check.
        let foldedLines: [String]
        let words: Set<String>

        init(lines: [TranscriptLine]) {
            self.lines = lines
            // One fold over the whole transcript is far cheaper than one per line.
            let folded: String = lines.map(\.text).joined(separator: "\n")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            var foldedLines: [String] = folded.components(separatedBy: "\n")
            if foldedLines.count != lines.count { foldedLines = lines.map { $0.text.lowercased() } }
            self.foldedLines = foldedLines
            words = ProjectLinks.words(folded)
        }

        init(markdown: String) {
            self.init(lines: ProjectLinks.transcriptLines(fromMarkdown: markdown))
        }
    }

    struct Input: Sendable {
        var curation = ProjectCuration()
        var memory: DreamMemory?
        var meetings: [Meeting]
        var summaries: [UUID: String] = [:]
        var transcripts: [UUID: TranscriptText] = [:]
        var projections: [MeetingOutcomeProjection] = []
        var activity: [ActivityBlock] = []
        var people: [PersonProfile] = []
        /// Words never offered as topics (people, the user, apps in use).
        var excludedTopicWords: Set<String> = []
    }

    /// A meeting's searchable text, folded once per build.
    private struct MeetingText {
        let meeting: Meeting
        /// Title and calendar title.
        let titleWords: Set<String>
        /// Title, calendar title, summary, and outcome text.
        let words: Set<String>
        let summary: FoldedLines
        let outcomeTexts: [String]
        let transcript: TranscriptText?
    }

    /// Text split into lines, with a case- and diacritic-folded copy for a
    /// quick substring check before the costlier word match.
    struct FoldedLines: Sendable {
        let lines: [String]
        let folded: [String]

        init(_ text: String) {
            lines = text.components(separatedBy: "\n")
            let folded: [String] = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .components(separatedBy: "\n")
            self.folded = folded.count == lines.count ? folded : lines.map { $0.lowercased() }
        }

        func mayMatch(_ termSets: [Set<String>], at index: Int) -> Bool {
            let line: String = folded[index]
            return termSets.contains { (terms: Set<String>) -> Bool in
                !terms.isEmpty && terms.allSatisfy { line.contains($0) }
            }
        }
    }

    private struct LinkedMeeting {
        let meeting: Meeting
        let mentions: [ProjectProfile.Mention]
    }

    private struct Context {
        let input: Input
        let texts: [MeetingText]
        let threads: [ActionThread]
        let windowStart: Date
        let now: Date
        let calendar: Calendar
    }

    static func build(_ input: Input, now: Date = Date(), calendar: Calendar = .current) -> [ProjectProfile] {
        let meetings: [Meeting] = input.meetings.filter { $0.mergedIntoMeetingID == nil }
        let references: [OutcomeActionReference] = input.projections
            .filter { !$0.isArchived }
            .flatMap(\.actionReferences)
        let threads: [ActionThread] = ActionThreadClusterer.cluster(references)
            .filter { $0.status != .done }
        let windowStart: Date = calendar.date(byAdding: .day, value: -(reviewDays - 1),
                                              to: calendar.startOfDay(for: now)) ?? now
        let context = Context(input: input, texts: meetingTexts(meetings, input: input), threads: threads,
                              windowStart: windowStart, now: now, calendar: calendar)
        let curation: ProjectCuration = input.curation
        let reviewProjects: [DreamMemory.Project] = input.memory?.activeProjects ?? []

        // Tracked projects, each with the review entries its names cover.
        var result: [ProjectProfile] = []
        var attachedReviewNames: Set<String> = []
        var trackedTermSets: [Set<String>] = []
        for project in curation.tracked {
            let termSets: [Set<String>] = project.allNames.map(significantTerms)
            trackedTermSets.append(contentsOf: termSets)
            let notes: [DreamMemory.Project] = reviewProjects.filter { matches(termSets, in: $0.name) }
            for note in notes { attachedReviewNames.insert(note.name) }
            result.append(profile(
                id: "tracked:" + project.id.uuidString, name: project.name, kind: .tracked(project.id),
                otherNames: project.otherNames, termSets: termSets, reviewNotes: notes, context: context))
        }

        // Overnight review projects nobody tracks yet.
        let reviewSuggestions: [DreamMemory.Project] = reviewProjects.filter { project in
            !attachedReviewNames.contains(project.name) && !curation.isHidden(project.name)
        }
        let reviewTerms: [Set<String>] = reviewSuggestions.map { significantTerms($0.name) }

        // Names that recur across meetings, unless tracked, hidden, or
        // already offered as a review suggestion.
        var excluded: Set<String> = input.excludedTopicWords
        for name in curation.hiddenNames where !name.contains(" ") { excluded.insert(name) }
        for terms in trackedTermSets where terms.count == 1 { excluded.formUnion(terms) }
        let topics: [ProjectTopicDetector.Topic] = ProjectTopicDetector.topics(
            meetings: meetings, summaries: input.summaries, projections: input.projections,
            excludedWords: excluded)
        var topicProfiles: [ProjectProfile] = []
        for topic in topics {
            let key: String = PeopleDirectory.normalized(topic.name)
            if trackedTermSets.contains(where: { $0.contains(key) }) { continue }
            if reviewTerms.contains(where: { $0.contains(key) }) { continue }
            topicProfiles.append(profile(
                id: "topic:" + key, name: topic.name, kind: .suggestedTopic,
                otherNames: [], termSets: [[key]], reviewNotes: [], context: context))
        }
        // Ordered by the meeting count each row shows.
        result.append(contentsOf: topicProfiles.sorted { (lhs: ProjectProfile, rhs: ProjectProfile) -> Bool in
            if lhs.meetings.count != rhs.meetings.count { return lhs.meetings.count > rhs.meetings.count }
            return (lhs.lastActive ?? .distantPast) > (rhs.lastActive ?? .distantPast)
        })
        for project in reviewSuggestions {
            result.append(profile(
                id: "review:" + PeopleDirectory.normalized(project.name), name: project.name,
                kind: .suggestedReview, otherNames: [], termSets: [significantTerms(project.name)],
                reviewNotes: [project], context: context))
        }
        return result
    }

    // MARK: - Profiles

    private static func profile(
        id: String, name: String, kind: ProjectProfile.Kind, otherNames: [String],
        termSets: [Set<String>], reviewNotes: [DreamMemory.Project], context: Context
    ) -> ProjectProfile {
        let linked: [LinkedMeeting] = linkedMeetings(termSets: termSets, texts: context.texts)
        let linkedIDs: Set<UUID> = Set(linked.map(\.meeting.id))
        // A meeting named for the project owns all of its actions; any other
        // meeting contributes only the actions that name the project.
        var titledIDs: Set<UUID> = []
        for text in context.texts where matches(termSets, words: text.titleWords) { titledIDs.insert(text.meeting.id) }
        let actions: [ActionThread] = context.threads.filter { (thread: ActionThread) -> Bool in
            if matches(termSets, in: thread.text) { return true }
            return thread.references.contains { titledIDs.contains($0.meetingID) }
        }
        let ordered: [ActionThread] = ActionAttentionOrder.sorted(actions, now: context.now, calendar: context.calendar)
        var mine: [ActionThread] = []
        var others: [ActionThread] = []
        var older: [ActionThread] = []
        for thread in ordered {
            if thread.isForUser {
                mine.append(thread)
            } else if isRecent(thread, now: context.now, calendar: context.calendar) {
                others.append(thread)
            } else {
                older.append(thread)
            }
        }
        let time = trackedTime(termSets: termSets, activity: context.input.activity,
                               windowStart: context.windowStart, now: context.now,
                               calendar: context.calendar)
        let meetingRefs: [ProjectProfile.MeetingRef] = linked.map { (item: LinkedMeeting) -> ProjectProfile.MeetingRef in
            ProjectProfile.MeetingRef(id: item.meeting.id, title: item.meeting.displayTitle,
                                      startedAt: item.meeting.startedAt, mentions: item.mentions)
        }
        let notes: [ProjectProfile.ReviewNote] = reviewNotes.map { (note: DreamMemory.Project) -> ProjectProfile.ReviewNote in
            ProjectProfile.ReviewNote(name: note.name, status: note.status, lastActiveDay: note.lastActiveDay)
        }
        var lastActive: Date? = meetingRefs.first?.startedAt
        for note in notes {
            guard let day = AskDayScope.date(for: note.lastActiveDay) else { continue }
            lastActive = max(lastActive ?? day, day)
        }
        if let key = time.days.first?.dayKey, let day = AskDayScope.date(for: key) {
            lastActive = max(lastActive ?? day, day)
        }
        return ProjectProfile(
            id: id, name: name, kind: kind, otherNames: otherNames, meetings: meetingRefs,
            myActions: mine, othersActions: others, olderOthersActions: older,
            decisions: decisions(termSets: termSets, linkedIDs: linkedIDs, projections: context.input.projections),
            reviewNotes: notes, days: time.days, windows: time.windows,
            people: people(in: linkedIDs, from: context.input.people), lastActive: lastActive)
    }

    /// Other people's work stays in view while it was mentioned recently or
    /// its due day is still ahead.
    static func isRecent(_ thread: ActionThread, now: Date, calendar: Calendar) -> Bool {
        let today: Date = calendar.startOfDay(for: now)
        if let due = thread.resolvedDueDate, due >= today { return true }
        let cutoff: Date = calendar.date(byAdding: .day, value: -recentOthersActionDays, to: today) ?? today
        return thread.latestReference.meetingStartedAt >= cutoff
    }

    // MARK: - Evidence

    private static func meetingTexts(_ meetings: [Meeting], input: Input) -> [MeetingText] {
        var outcomeTexts: [UUID: [String]] = [:]
        for projection in input.projections where !projection.isArchived {
            var texts: [String] = projection.actionReferences.map(\.text)
            texts.append(contentsOf: projection.outcomes.decisionRecords.map(\.text))
            outcomeTexts[projection.meeting.id, default: []].append(contentsOf: texts)
        }
        var result: [MeetingText] = []
        for meeting in meetings {
            let summary: String = input.summaries[meeting.id] ?? ""
            let outcomes: [String] = outcomeTexts[meeting.id] ?? []
            var titleWords: Set<String> = words(meeting.displayTitle)
            titleWords.formUnion(Self.words(meeting.calendarTitle ?? ""))
            let folded = FoldedLines(summary)
            var words: Set<String> = titleWords
            words.formUnion(Self.words(folded.folded.joined(separator: "\n")))
            for text in outcomes { words.formUnion(Self.words(text)) }
            result.append(MeetingText(meeting: meeting, titleWords: titleWords, words: words, summary: folded,
                                      outcomeTexts: outcomes, transcript: input.transcripts[meeting.id]))
        }
        return result
    }

    /// Meetings whose title, summary, outcomes, or transcript name the
    /// project, newest first, each with the lines that do.
    private static func linkedMeetings(termSets: [Set<String>], texts: [MeetingText]) -> [LinkedMeeting] {
        var linked: [LinkedMeeting] = []
        for text in texts {
            let inText: Bool = matches(termSets, words: text.words)
            let inTranscript: Bool = text.transcript.map { matches(termSets, words: $0.words) } ?? false
            guard inText || inTranscript else { continue }
            var mentions: [ProjectProfile.Mention] = summaryMentions(of: termSets, in: text.summary)
            if mentions.isEmpty, let transcript = text.transcript {
                mentions = transcriptMentions(of: termSets, in: transcript)
            }
            if mentions.isEmpty, let outcome = text.outcomeTexts.first(where: { matches(termSets, in: $0) }) {
                mentions = [ProjectProfile.Mention(text: excerpt(outcome, around: termSets), seek: nil)]
            }
            linked.append(LinkedMeeting(meeting: text.meeting, mentions: mentions))
        }
        return linked.sorted { $0.meeting.startedAt > $1.meeting.startedAt }
    }

    /// Decisions from the project's meetings that name it.
    private static func decisions(termSets: [Set<String>], linkedIDs: Set<UUID>,
                                  projections: [MeetingOutcomeProjection]) -> [PersonProfile.DecisionRef] {
        var result: [PersonProfile.DecisionRef] = []
        for projection in projections where linkedIDs.contains(projection.meeting.id) && !projection.isArchived {
            for decision in projection.outcomes.decisionRecords where matches(termSets, in: decision.text) {
                result.append(PersonProfile.DecisionRef(
                    id: projection.meeting.id.uuidString + ":" + decision.id, text: decision.text,
                    meetingID: projection.meeting.id, meetingTitle: projection.meeting.displayTitle,
                    meetingDate: projection.meeting.startedAt))
            }
        }
        let sorted: [PersonProfile.DecisionRef] = result.sorted { $0.meetingDate > $1.meetingDate }
        return Array(sorted.prefix(maximumDecisions))
    }

    private static func trackedTime(
        termSets: [Set<String>], activity: [ActivityBlock], windowStart: Date, now: Date, calendar: Calendar
    ) -> (days: [ProjectProfile.DayTime], windows: [ProjectProfile.WindowTime]) {
        var perDay: [String: TimeInterval] = [:]
        var perWindow: [String: ProjectProfile.WindowTime] = [:]
        for block in activity where block.end > windowStart && block.start < now {
            guard matches(termSets, in: block.title) else { continue }
            let start: Date = max(block.start, windowStart)
            let end: Date = min(block.end, now)
            guard end > start else { continue }
            let seconds: TimeInterval = end.timeIntervalSince(start)
            perDay[dayKey(start, calendar: calendar), default: 0] += seconds
            let title: String = TimelineWorkSession.strippingBrowserChrome(block.title)
            let key: String = block.app + "|" + title
            let previous: TimeInterval = perWindow[key]?.seconds ?? 0
            perWindow[key] = ProjectProfile.WindowTime(app: block.app, title: title, seconds: previous + seconds)
        }
        let days: [ProjectProfile.DayTime] = perDay
            .map { ProjectProfile.DayTime(dayKey: $0.key, seconds: $0.value) }
            .sorted { $0.dayKey > $1.dayKey }
        let windows: [ProjectProfile.WindowTime] = perWindow.values.sorted {
            $0.seconds == $1.seconds ? $0.title < $1.title : $0.seconds > $1.seconds
        }
        return (days, Array(windows.prefix(maximumWindows)))
    }

    private static func people(in linkedIDs: Set<UUID>, from people: [PersonProfile]) -> [String] {
        let related: [PersonProfile] = people.filter { !$0.meetingIDs.isDisjoint(with: linkedIDs) }
        let ranked: [PersonProfile] = related.sorted { (lhs: PersonProfile, rhs: PersonProfile) -> Bool in
            lhs.meetingIDs.intersection(linkedIDs).count > rhs.meetingIDs.intersection(linkedIDs).count
        }
        return Array(ranked.prefix(8)).map(\.name)
    }

    // MARK: - Mentions

    /// The first summary line naming every term, without markdown markers,
    /// transcript timestamps, or speaker labels, cut to fit around the name.
    static func mention(of terms: Set<String>, in summary: String) -> String? {
        summaryMentions(of: [terms], in: summary).first?.text
    }

    static func summaryMentions(of termSets: [Set<String>], in summary: String) -> [ProjectProfile.Mention] {
        summaryMentions(of: termSets, in: FoldedLines(summary))
    }

    static func summaryMentions(of termSets: [Set<String>], in summary: FoldedLines) -> [ProjectProfile.Mention] {
        var result: [ProjectProfile.Mention] = []
        for (index, rawLine) in summary.lines.enumerated() where summary.mayMatch(termSets, at: index) {
            guard !rawLine.hasPrefix("# "), matches(termSets, words: words(rawLine)) else { continue }
            let line: String = cleanedLine(rawLine)
            guard line.count >= 12, matches(termSets, in: line) else { continue }
            result.append(ProjectProfile.Mention(text: excerpt(line, around: termSets), seek: nil))
            if result.count == maximumMentionsPerMeeting { break }
        }
        return result
    }

    /// Transcript lines naming the project. A short line borrows the next
    /// lines so the excerpt reads as a sentence.
    static func transcriptMentions(of termSets: [Set<String>],
                                   in transcript: TranscriptText) -> [ProjectProfile.Mention] {
        var result: [ProjectProfile.Mention] = []
        let lines: [TranscriptLine] = transcript.lines
        var index: Int = 0
        while index < lines.count, result.count < maximumMentionsPerMeeting {
            let folded: String = transcript.foldedLines[index]
            let possible: Bool = termSets.contains { (terms: Set<String>) -> Bool in
                !terms.isEmpty && terms.allSatisfy { folded.contains($0) }
            }
            guard possible, matches(termSets, words: words(lines[index].text)) else {
                index += 1
                continue
            }
            var text: String = lines[index].text
            var next: Int = index + 1
            while text.count < 100, next < lines.count, next <= index + 2 {
                text += " " + lines[next].text
                next += 1
            }
            result.append(ProjectProfile.Mention(text: excerpt(text, around: termSets), seek: lines[index].start))
            index = next
        }
        return result
    }

    private static func cleanedLine(_ rawLine: String) -> String {
        var line: String = rawLine
        line = line.replacingOccurrences(of: #"^\s*(#+|[-*•]|\d+\.)\s*"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"^\[[ xX]\]\s*"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: "**", with: "")
        line = line.replacingOccurrences(of: "`", with: "")
        line = line.replacingOccurrences(of: #"\s*[—–-]?\s*\[\d{1,2}:\d{2}(:\d{2})?\]"#, with: "",
                                         options: .regularExpression)
        line = line.replacingOccurrences(of: #"^(Them|Me|Local|Remote|Speaker)( \d+)?( · source \d+)?:\s*"#,
                                         with: "", options: [.regularExpression, .caseInsensitive])
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// The line itself when it fits; otherwise a window that starts a little
    /// before the project's name, cut at word boundaries and marked "…".
    static func excerpt(_ line: String, around termSets: [Set<String>],
                        limit: Int = maximumMentionCharacters) -> String {
        let text: String = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        var allTerms: Set<String> = []
        for terms in termSets { allTerms.formUnion(terms) }
        var anchor: Int = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, stop in
            guard let word, !words(word).isDisjoint(with: allTerms) else { return }
            anchor = text.distance(from: text.startIndex, to: range.lowerBound)
            stop = true
        }
        let characters: [Character] = Array(text)
        let count: Int = characters.count
        var start: Int = max(0, min(anchor - 50, count - (limit - 2)))
        if start > 0, characters[start - 1] != " " {
            // Begin at the next word, but never after the name itself.
            var next: Int = start
            while next < anchor, characters[next] != " " { next += 1 }
            start = next < anchor ? next + 1 : anchor
        }
        let budget: Int = limit - (start > 0 ? 1 : 0) - 1
        var end: Int = min(count, start + budget)
        if end < count, characters[end] != " " {
            var previous: Int = end - 1
            while previous > anchor, characters[previous] != " " { previous -= 1 }
            if previous > anchor { end = previous }
        }
        var result: String = String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > 0 { result = "…" + result }
        if end < count { result += "…" }
        return result
    }

    /// "**[00:13:21] Them 3:** text" lines from `transcript.md`; speaker
    /// labels are dropped because they are only meaningful inside one meeting.
    /// Parsed by hand: a Swift regex took 1.9 s over a 31,000-line library.
    static func transcriptLines(fromMarkdown markdown: String) -> [TranscriptLine] {
        var result: [TranscriptLine] = []
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            guard rawLine.hasPrefix("**["), let close = rawLine.firstIndex(of: "]") else { continue }
            let stamp: Substring = rawLine[rawLine.index(rawLine.startIndex, offsetBy: 3)..<close]
            let parts: [Substring] = stamp.split(separator: ":", omittingEmptySubsequences: false)
            let numbers: [Double] = parts.compactMap { Double($0) }
            guard parts.count == 2 || parts.count == 3, numbers.count == parts.count,
                  let labelEnd = rawLine[close...].range(of: "**") else { continue }
            let start: TimeInterval = numbers.reduce(0) { $0 * 60 + $1 }
            let text: String = rawLine[labelEnd.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            result.append(TranscriptLine(start: start, text: text))
        }
        return result
    }

    // MARK: - Matching

    /// Words of a project name that can identify it: at least three
    /// characters and not a generic work word.
    static func significantTerms(_ name: String) -> Set<String> {
        let words = PeopleDirectory.normalized(name).split(separator: " ").map(String.init)
        let significant = words.filter { $0.count >= 3 && !genericWords.contains($0) }
        return Set(significant.isEmpty ? words.filter { $0.count >= 2 } : significant)
    }

    static func words(_ text: String) -> Set<String> {
        Set(PeopleDirectory.normalized(text).split(separator: " ").map(String.init))
    }

    /// Every significant term must appear as a whole word.
    static func matches(_ terms: Set<String>, in text: String) -> Bool {
        matches([terms], in: text)
    }

    /// Any one of a project's names matches. A substring check rules most
    /// text out before the costlier fold into words.
    static func matches(_ termSets: [Set<String>], in text: String) -> Bool {
        let possible: Bool = termSets.contains { (terms: Set<String>) -> Bool in
            !terms.isEmpty && terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return possible && matches(termSets, words: words(text))
    }

    static func matches(_ termSets: [Set<String>], words: Set<String>) -> Bool {
        termSets.contains { !$0.isEmpty && $0.isSubset(of: words) }
    }

    private static let genericWords: Set<String> = [
        "the", "and", "for", "with", "project", "work", "team", "new", "update", "updates",
        "review", "plan", "planning", "launch", "release", "meeting", "sync", "weekly",
        "migration", "improvements", "support", "feature", "features", "app",
    ]

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
