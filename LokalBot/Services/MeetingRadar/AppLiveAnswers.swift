import Foundation

/// Live answers' view of the app: what LokalBot remembers that bears on a
/// question, Ask's meeting and screen tools, and the folders chosen in
/// Settings. Everything is read on this Mac; only what the prompt and the
/// tools return goes to Muse.
@MainActor
final class AppLiveAnswerEnvironment: LiveAnswerEnvironment {
    private weak var app: AppState?
    private var cached: (paths: [String], at: Date, places: [LiveAnswerPlace])?

    static let projectLimit = 2
    static let blockCharacters = 2_500

    init(app: AppState) { self.app = app }

    // MARK: - Memory first

    func context(for question: String, meeting: LiveAnswerMeeting) async -> [LiveAnswerContext] {
        guard let app else { return [] }
        var items = projects(for: ([question, meeting.title] + meeting.recentLines.suffix(4)).joined(separator: " "))
        let actions = await app.libraryTools.run(ChatToolCall(name: "get_action_items",
                                                              arguments: ["status": "active", "days": "30"]))
        if actions.evidence.meetingIDs.isEmpty == false {
            items.append(LiveAnswerContext(kind: .action, title: String(localized: "Open actions from the last 30 days"),
                                           text: String(actions.text.prefix(Self.blockCharacters))))
        }
        if app.settings.askMemoryEnabled {
            let selection = PersonalContextBuilder.select(claims: app.personalModel.usableClaims(), question: question,
                                                          budget: 1_200)
            if !selection.block.isEmpty {
                items.append(LiveAnswerContext(kind: .memory, title: String(localized: "What they told LokalBot about themselves"),
                                               text: selection.block))
            }
        }
        let work = ChatPrompt.workMemoryContext(memory: app.dreamMemory, dreamingEnabled: app.settings.dreamingEnabled)
        if !work.isEmpty {
            items.append(LiveAnswerContext(kind: .memory, title: String(localized: "Work memory"),
                                           text: String(work.prefix(Self.blockCharacters))))
        }
        return items
    }

    /// Tracked projects whose names or "Where it stands" notes share words
    /// with the question, with their notes.
    private func projects(for query: String) -> [LiveAnswerContext] {
        guard let app else { return [] }
        let words = PersonalContextSelection.contentWords(query)
        var scored: [(score: Int, item: LiveAnswerContext)] = []
        for project in app.projectStore.curation.tracked {
            guard let summary = app.projectStore.summaries[project.id] else { continue }
            let body = [summary.overview] + summary.points.map(\.text) + summary.openQuestions
            let shared = words.intersection(PersonalContextSelection.contentWords((project.allNames + body).joined(separator: " ")))
            let named = project.allNames.contains { query.localizedCaseInsensitiveContains($0) }
            let score = shared.count + (named ? 5 : 0)
            guard score > 0 else { continue }
            var lines = [summary.overview]
            for point in summary.points.prefix(8) {
                lines.append("- " + point.text + (point.meetingTitle.map { " (\($0))" } ?? ""))
            }
            if !summary.openQuestions.isEmpty {
                lines.append("Still open: " + summary.openQuestions.prefix(4).joined(separator: "; "))
            }
            let date = summary.generatedAt.formatted(date: .abbreviated, time: .omitted)
            scored.append((score, LiveAnswerContext(kind: .project,
                                                    title: String(localized: "Project \(project.name): where it stands, \(date)"),
                                                    text: String(lines.joined(separator: "\n").prefix(Self.blockCharacters)))))
        }
        return scored.sorted { $0.score > $1.score }.prefix(Self.projectLimit).map(\.item)
    }

    // MARK: - Folders

    func places() async -> [LiveAnswerPlace] {
        let paths = app?.settings.liveAnswerFolders ?? []
        // Re-read git details now and then, so links point at what is checked out.
        if let cached, cached.paths == paths, Date().timeIntervalSince(cached.at) < 600 { return cached.places }
        let places = await LiveAnswerPlace.load(paths)
        cached = (paths, Date(), places)
        return places
    }

    // MARK: - Library tools

    var libraryToolSpecs: [ChatToolSpec] { MeetingChatTools.specs }

    func runLibraryTool(_ call: ChatToolCall) async -> LiveAnswerToolOutput {
        guard let app else { return .message("LokalBot is closing.") }
        let result = await app.libraryTools.run(call)
        let kind: RadarAnswer.Source.Kind = switch call.name {
        case "search_screen": .screen
        case "get_action_items": .action
        default: .meeting
        }
        var output = LiveAnswerToolOutput(text: result.text, kind: kind, title: Self.fallbackTitle(kind))
        // A result from one meeting names that meeting, and opens it.
        if result.evidence.meetingIDs.count == 1, let short = result.evidence.meetingIDs.first,
           let meeting = app.meetings.first(where: { SessionLookup.shortID($0.id).lowercased() == short }) {
            output.title = "\(meeting.displayTitle) · \(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))"
            output.meetingID = meeting.id
            output.time = result.evidence.meetingSeconds[short]?.min().map(Double.init)
        }
        return output
    }

    private static func fallbackTitle(_ kind: RadarAnswer.Source.Kind) -> String {
        switch kind {
        case .screen: String(localized: "What you saw on screen")
        case .action: String(localized: "Your actions")
        default: String(localized: "Your meetings")
        }
    }
}
