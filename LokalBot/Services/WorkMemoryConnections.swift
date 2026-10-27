import Foundation

/// Builds the People and Projects read models off the main actor from local
/// meeting metadata, summaries, transcripts, outcomes, applied speaker names,
/// tracked projects, People corrections, Dream projects, and activity
/// titles. Nothing is persisted here; every refresh derives from the current
/// library, so deletions and corrections are reflected immediately.
@MainActor
final class WorkMemoryConnections: ObservableObject {
    @Published private(set) var people: [PersonProfile] = []
    @Published private(set) var projects: [ProjectProfile] = []
    @Published private(set) var hasLoaded = false

    /// Applied speaker names are read from transcripts; only meetings from
    /// this window are opened, and results are cached by file date.
    nonisolated static let transcriptLookbackDays = 180
    nonisolated static let projectMeetingLookbackDays = 120

    struct Input: Sendable {
        var meetings: [Meeting]
        var projections: [MeetingOutcomeProjection]
        var memory: DreamMemory?
        var curation = ProjectCuration()
        var peopleCuration = PeopleCuration()
        var root: URL
        var activityDatabaseURL: URL
        var now = Date()
    }

    private struct CachedNames: Sendable {
        var modifiedAt: Date
        var names: MeetingAppliedSpeakerNames
    }

    private struct CachedTranscript: Sendable {
        var modifiedAt: Date
        var text: ProjectLinks.TranscriptText
    }

    private struct Caches: Sendable {
        var names: [UUID: CachedNames] = [:]
        var transcripts: [UUID: CachedTranscript] = [:]
    }

    /// Summaries are matched whole; this only guards against a runaway file.
    nonisolated static let maximumSummaryCharacters = 100_000

    private var task: Task<Void, Never>?
    private var caches = Caches()

    func refresh(_ input: Input) {
        task?.cancel()
        let cache = caches
        task = Task { [weak self] in
            // Coalesce bursts of outcome and library changes.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                Self.compute(input, cache: cache)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.caches = result.cache
            if self.people != result.people { self.people = result.people }
            if self.projects != result.projects { self.projects = result.projects }
            self.hasLoaded = true
        }
    }

    /// The projects one refresh would publish, without caches.
    nonisolated static func projects(for input: Input) -> [ProjectProfile] {
        compute(input, cache: Caches()).projects
    }

    private nonisolated static func compute(
        _ input: Input, cache: Caches
    ) -> (people: [PersonProfile], projects: [ProjectProfile], cache: Caches) {
        let cutoff = input.now.addingTimeInterval(-TimeInterval(transcriptLookbackDays) * 86_400)
        var nextCache = Caches()
        var appliedNames: [UUID: MeetingAppliedSpeakerNames] = [:]
        for meeting in input.meetings where meeting.startedAt >= cutoff && meeting.mergedIntoMeetingID == nil {
            let folder = input.root.appendingPathComponent(meeting.relativePath, isDirectory: true)
            let url = folder.appendingPathComponent("transcript.json")
            guard let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
                continue
            }
            let names = cache.names[meeting.id].flatMap { $0.modifiedAt == modifiedAt ? $0.names : nil }
                ?? MeetingAppliedSpeakerNames.load(from: folder)
            nextCache.names[meeting.id] = CachedNames(modifiedAt: modifiedAt, names: names)
            if !names.names.isEmpty { appliedNames[meeting.id] = names }
        }

        var people = PeopleDirectory.build(
            .init(meetings: input.meetings, projections: input.projections, appliedNames: appliedNames,
                  curation: input.peopleCuration),
            now: input.now)

        let meetingCutoff = input.now.addingTimeInterval(-TimeInterval(projectMeetingLookbackDays) * 86_400)
        let recent = input.meetings.filter { $0.startedAt >= meetingCutoff }
        let recentIDs = Set(recent.map(\.id))
        var summaries: [UUID: String] = [:]
        var transcripts: [UUID: ProjectLinks.TranscriptText] = [:]
        for meeting in recent {
            let folder = input.root.appendingPathComponent(meeting.relativePath, isDirectory: true)
            if let text = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8) {
                summaries[meeting.id] = String(text.prefix(maximumSummaryCharacters))
            }
            // Project names said in the call count even when the summary
            // leaves them out or the meeting has no summary.
            let transcriptURL = folder.appendingPathComponent("transcript.md")
            guard let modifiedAt = (try? FileManager.default.attributesOfItem(
                atPath: transcriptURL.path))?[.modificationDate] as? Date else { continue }
            let text: ProjectLinks.TranscriptText
            if let cached = cache.transcripts[meeting.id], cached.modifiedAt == modifiedAt {
                text = cached.text
            } else if let markdown = try? String(contentsOf: transcriptURL, encoding: .utf8) {
                text = ProjectLinks.TranscriptText(markdown: markdown)
            } else {
                continue
            }
            nextCache.transcripts[meeting.id] = CachedTranscript(modifiedAt: modifiedAt, text: text)
            transcripts[meeting.id] = text
        }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -(ProjectLinks.reviewDays - 1),
                                  to: calendar.startOfDay(for: input.now)) ?? input.now
        let activity = ActivityStore(databaseURL: input.activityDatabaseURL, readOnly: true)
            .blocks(in: DateInterval(start: start, end: max(start, input.now)))
        let projects = ProjectLinks.build(.init(
            curation: input.curation, memory: input.memory, meetings: recent, summaries: summaries,
            transcripts: transcripts,
            projections: input.projections.filter { recentIDs.contains($0.meeting.id) },
            activity: activity, people: people,
            excludedTopicWords: excludedTopicWords(people: people, activity: activity)), now: input.now)

        // What the newest notes say about each person, and the projects
        // named around them.
        var summaryLines: [UUID: [PersonNotes.SummaryLine]] = [:]
        for (id, summary) in summaries { summaryLines[id] = PersonNotes.lines(fromSummary: summary) }
        for index in people.indices {
            people[index].recentNotes = PersonNotes.recentNotes(
                for: people[index], lines: summaryLines, appliedNames: appliedNames)
            people[index].projects = PersonNotes.projects(
                for: people[index], lines: summaryLines, appliedNames: appliedNames, projects: projects)
        }
        return (people, projects, nextCache)
    }

    /// People, the user, and apps are recurring capitalized words but never
    /// projects of their own.
    nonisolated static func excludedTopicWords(
        people: [PersonProfile], activity: [ActivityBlock]
    ) -> Set<String> {
        let names = people.flatMap { [$0.name] + $0.otherNames } + PeopleDirectory.defaultSelfNames
        var words: Set<String> = []
        for name in names {
            for word in ProjectTopicDetector.tokens(name).map({ $0.lowercased() }) {
                words.insert(word)
                // Short forms people are called by ("Ben" for Benjamin).
                if word.count >= 5 { words.formUnion([String(word.prefix(3)), String(word.prefix(4))]) }
            }
        }
        for app in activity.map(\.app) {
            for word in ProjectTopicDetector.tokens(app) { words.insert(word.lowercased()) }
        }
        return words
    }
}
