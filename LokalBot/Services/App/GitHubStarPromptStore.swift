import AppKit
import Combine

@MainActor
final class GitHubStarPromptStore: ObservableObject {
    static let dismissedKey = "lokalbotv3.githubStar.dismissed"
    static let summaryCompletedKey = "lokalbotv3.githubStar.summaryCompleted"
    static let activeDaysKey = "lokalbotv3.githubStar.activeDays"

    @Published private(set) var state: GitHubStarPrompt.State
    let launch: GitHubStarPrompt.Launch
    private let defaults: UserDefaults
    private let openURL: @MainActor (URL) -> Void

    init(defaults: UserDefaults,
         launch: GitHubStarPrompt.Launch,
         openURL: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.launch = launch
        self.openURL = openURL
        state = GitHubStarPrompt.State(
            dismissed: defaults.bool(forKey: Self.dismissedKey),
            summaryCompleted: defaults.bool(forKey: Self.summaryCompletedKey),
            activeDays: defaults.stringArray(forKey: Self.activeDaysKey) ?? [])
    }

    static func live(libraryRoot: URL) -> GitHubStarPromptStore {
        GitHubStarPromptStore(
            defaults: appDefaults,
            launch: GitHubStarPrompt.Launch(
                uiTesting: UITestRuntime.isEnabled,
                unitTesting: UITestRuntime.isUnitTesting,
                headless: HeadlessCommand.requested != nil,
                seededDemoLibrary: GitHubStarPrompt.isSeededDemoLibrary(libraryRoot)))
    }

    var showsPrompt: Bool { GitHubStarPrompt.shouldShow(state, in: launch) }

    func recordSummaryCompleted() {
        guard records, !state.summaryCompleted else { return }
        state.summaryCompleted = true
        defaults.set(true, forKey: Self.summaryCompletedKey)
    }

    func recordActiveDay(_ date: Date = Date(), calendar: Calendar = .current) {
        guard records else { return }
        let updated = GitHubStarPrompt.recordingActiveDay(
            DreamDay.key(for: date, calendar: calendar), in: state)
        guard updated != state else { return }
        state = updated
        defaults.set(updated.activeDays, forKey: Self.activeDaysKey)
    }

    func openRepository() {
        openURL(GitHubStarPrompt.repositoryURL)
        dismiss()
    }

    func dismiss() {
        guard !state.dismissed else { return }
        state.dismissed = true
        defaults.set(true, forKey: Self.dismissedKey)
    }

    private var records: Bool { !launch.suppressesPrompt && !state.dismissed }

    private static var appDefaults: UserDefaults {
        if let suite = UITestRuntime.defaultsSuiteName,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }
}
