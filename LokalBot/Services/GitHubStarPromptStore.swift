import AppKit
import Combine

/// Keeps the GitHub star request's local facts in the app's preferences (the
/// test suite when one is set), like the other small preference stores, and
/// opens the repository in the default browser.
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

    /// The store for this process, suppressed for UI tests and captures, unit
    /// tests, headless commands, and seeded demo libraries.
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

    /// The pipeline saved a complete meeting summary.
    func recordSummaryCompleted() {
        guard records, !state.summaryCompleted else { return }
        state.summaryCompleted = true
        defaults.set(true, forKey: Self.summaryCompletedKey)
    }

    /// LokalBot was used on the calendar day containing `date`.
    func recordActiveDay(_ date: Date = Date(), calendar: Calendar = .current) {
        guard records else { return }
        let updated = GitHubStarPrompt.recordingActiveDay(
            DreamDay.key(for: date, calendar: calendar), in: state)
        guard updated != state else { return }
        state = updated
        defaults.set(updated.activeDays, forKey: Self.activeDaysKey)
    }

    /// Opening the repository from any entry point also retires the request:
    /// whatever the person did there, they have seen it.
    func openRepository() {
        openURL(GitHubStarPrompt.repositoryURL)
        dismiss()
    }

    /// "Not now". The request never returns.
    func dismiss() {
        guard !state.dismissed else { return }
        state.dismissed = true
        defaults.set(true, forKey: Self.dismissedKey)
    }

    /// Suppressed launches and an answered request record nothing new.
    private var records: Bool { !launch.suppressesPrompt && !state.dismissed }

    private static var appDefaults: UserDefaults {
        if let suite = UITestRuntime.defaultsSuiteName,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }
}
