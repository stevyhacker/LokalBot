import Foundation

/// The one-time request on Today to star LokalBot's repository, and the
/// address the permanent "Star on GitHub" links open. Everything here stays on
/// this Mac: LokalBot keeps only whether a meeting summary has finished, which
/// calendar days it was used, and whether the request was answered. It sends
/// nothing and never learns whether anyone starred.
enum GitHubStarPrompt {
    static let repositoryURL = URL(string: "https://github.com/stevyhacker/LokalBot")!

    /// Distinct days of use that make the request eligible without a summary.
    static let activeDaysBeforeAsking = 7

    /// Written by `Scripts/seed_demo_library.py` at the root of every library
    /// it plants, including the screenshot, film, and upgrade-fixture ones.
    static let demoLibraryMarker = ".lokalbot-demo-library"

    struct State: Equatable {
        /// Set by either button on the request, and never cleared.
        var dismissed = false
        /// The processing pipeline has saved a complete meeting summary.
        var summaryCompleted = false
        /// Distinct local calendar days ("yyyy-MM-dd") LokalBot was used,
        /// kept only until there are enough to ask.
        var activeDays: [String] = []
    }

    /// Launches that must never show the request or count toward it.
    struct Launch: Equatable {
        /// XCUITest, and the README, website, and film captures, which all run
        /// the UI-test host or pass the UI-test flag.
        var uiTesting = false
        var unitTesting = false
        /// `--process`, `--digest`, and the other headless flags.
        var headless = false
        /// A library planted by `Scripts/seed_demo_library.py`.
        var seededDemoLibrary = false

        var suppressesPrompt: Bool {
            uiTesting || unitTesting || headless || seededDemoLibrary
        }
    }

    /// After the first completed meeting summary or `activeDaysBeforeAsking`
    /// distinct days of use, whichever comes first, until it is answered.
    static func shouldShow(_ state: State, in launch: Launch) -> Bool {
        guard !launch.suppressesPrompt, !state.dismissed else { return false }
        return state.summaryCompleted || state.activeDays.count >= activeDaysBeforeAsking
    }

    /// `state` with `dayKey` counted once. Further launches or activations on
    /// the same day leave it unchanged.
    static func recordingActiveDay(_ dayKey: String, in state: State) -> State {
        guard !state.activeDays.contains(dayKey),
              state.activeDays.count < activeDaysBeforeAsking else { return state }
        var updated = state
        updated.activeDays.append(dayKey)
        return updated
    }

    static func isSeededDemoLibrary(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(demoLibraryMarker).path)
    }
}
