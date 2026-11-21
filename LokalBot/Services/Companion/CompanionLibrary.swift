import Foundation

struct CompanionLibrary {
    let root: URL
    let activityDatabaseURL: URL
    let scope: CompanionSharing.RecordScope
    let now: Date
    let calendar: Calendar
    let allMeetings: [Meeting]
    let meetings: [Meeting]
    let projections: [UUID: MeetingOutcomeProjection]
    let people: [PersonProfile]
    let projects: [ProjectProfile]
    let projectSummaries: [UUID: ProjectStatusSummary]

    static func isShared(_ meeting: Meeting, history: CompanionHistoryWindow,
                         now: Date, calendar: Calendar) -> Bool {
        meeting.isOwnWork && meeting.endedAt != nil
            && history.contains(meeting.startedAt, now: now, calendar: calendar)
    }

    static func load(
        root: URL,
        activityDatabaseURL: URL? = nil,
        scope: CompanionSharing.RecordScope,
        now: Date = Date(),
        calendar: Calendar = .current,
        meetings preloaded: [Meeting]? = nil,
        projections known: [UUID: MeetingOutcomeProjection] = [:]
    ) -> CompanionLibrary {
        let activityURL = activityDatabaseURL ?? root.appendingPathComponent("lokalbotv3.sqlite")
        let all = preloaded ?? (try? SessionLookup.loadAllMeetings(root: root, includeMergedSources: true)) ?? []
        let shared = all.filter { isShared($0, history: scope.history, now: now, calendar: calendar) }
        let classes = scope.dataClasses
        let needsOutcomes = classes.meetings || classes.people || classes.projects
        var projections: [UUID: MeetingOutcomeProjection] = [:]
        if needsOutcomes {
            for meeting in shared {
                if let projection = known[meeting.id]
                    ?? MeetingOutcomeProjection.load(for: meeting, root: root) {
                    projections[meeting.id] = projection
                }
            }
        }
        var people: [PersonProfile] = []
        var projects: [ProjectProfile] = []
        if needsOutcomes {
            let profiles = WorkMemoryConnections.profiles(for: .init(
                meetings: shared,
                projections: shared.compactMap { projections[$0.id] },
                memory: nil,
                curation: ProjectCuration.load(libraryRoot: root) ?? ProjectCuration(),
                peopleCuration: PeopleCuration.load(libraryRoot: root) ?? PeopleCuration(),
                root: root,
                activityDatabaseURL: activityURL,
                now: now))
            people = profiles.people
            projects = profiles.projects.filter(\.isTracked)
        }
        return CompanionLibrary(
            root: root, activityDatabaseURL: activityURL, scope: scope, now: now, calendar: calendar,
            allMeetings: all, meetings: shared, projections: projections,
            people: people, projects: projects,
            projectSummaries: classes.projects ? loadProjectSummaries(root: root) : [:])
    }

    private static func loadProjectSummaries(root: URL) -> [UUID: ProjectStatusSummary] {
        let url = root.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(ProjectStatusSummary.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let list = try? decoder.decode([ProjectStatusSummary].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.projectID, $0) }, uniquingKeysWith: { _, latest in latest })
    }
}
