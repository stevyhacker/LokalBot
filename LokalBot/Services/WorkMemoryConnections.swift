import Foundation

/// Builds the People and Projects read models off the main actor from local
/// meeting metadata, outcomes, applied speaker names, Dream projects, and
/// activity titles. Nothing is persisted; every refresh derives from the
/// current library, so deletions and corrections are reflected immediately.
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
        var root: URL
        var activityDatabaseURL: URL
        var now = Date()
    }

    private struct CachedNames: Sendable {
        var modifiedAt: Date
        var names: MeetingAppliedSpeakerNames
    }

    private var task: Task<Void, Never>?
    private var namesCache: [UUID: CachedNames] = [:]

    func refresh(_ input: Input) {
        task?.cancel()
        let cache = namesCache
        task = Task { [weak self] in
            // Coalesce bursts of outcome and library changes.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                Self.compute(input, cache: cache)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.namesCache = result.cache
            if self.people != result.people { self.people = result.people }
            if self.projects != result.projects { self.projects = result.projects }
            self.hasLoaded = true
        }
    }

    private nonisolated static func compute(
        _ input: Input, cache: [UUID: CachedNames]
    ) -> (people: [PersonProfile], projects: [ProjectProfile], cache: [UUID: CachedNames]) {
        let cutoff = input.now.addingTimeInterval(-TimeInterval(transcriptLookbackDays) * 86_400)
        var nextCache: [UUID: CachedNames] = [:]
        var appliedNames: [UUID: MeetingAppliedSpeakerNames] = [:]
        for meeting in input.meetings where meeting.startedAt >= cutoff && meeting.mergedIntoMeetingID == nil {
            let folder = input.root.appendingPathComponent(meeting.relativePath, isDirectory: true)
            let url = folder.appendingPathComponent("transcript.json")
            guard let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
                continue
            }
            let names = cache[meeting.id].flatMap { $0.modifiedAt == modifiedAt ? $0.names : nil }
                ?? MeetingAppliedSpeakerNames.load(from: folder)
            nextCache[meeting.id] = CachedNames(modifiedAt: modifiedAt, names: names)
            if !names.names.isEmpty { appliedNames[meeting.id] = names }
        }

        let people = PeopleDirectory.build(
            .init(meetings: input.meetings, projections: input.projections, appliedNames: appliedNames),
            now: input.now)

        var projects: [ProjectProfile] = []
        if let memory = input.memory, !memory.activeProjects.isEmpty {
            let meetingCutoff = input.now.addingTimeInterval(-TimeInterval(projectMeetingLookbackDays) * 86_400)
            let recent = input.meetings.filter { $0.startedAt >= meetingCutoff }
            let recentIDs = Set(recent.map(\.id))
            var summaries: [UUID: String] = [:]
            for meeting in recent {
                let url = input.root.appendingPathComponent(meeting.relativePath, isDirectory: true)
                    .appendingPathComponent("summary.md")
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    summaries[meeting.id] = String(text.prefix(ProjectLinks.maximumSummaryCharacters))
                }
            }
            let calendar = Calendar.current
            let start = calendar.date(byAdding: .day, value: -(ProjectLinks.reviewDays - 1),
                                      to: calendar.startOfDay(for: input.now)) ?? input.now
            let activity = ActivityStore(databaseURL: input.activityDatabaseURL, readOnly: true)
                .blocks(in: DateInterval(start: start, end: max(start, input.now)))
            projects = ProjectLinks.build(.init(
                memory: memory, meetings: recent, summaries: summaries,
                projections: input.projections.filter { recentIDs.contains($0.meeting.id) },
                activity: activity, people: people), now: input.now)
        }
        return (people, projects, nextCache)
    }
}
