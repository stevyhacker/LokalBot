import Foundation

enum GitHubStarPrompt {
    static let repositoryURL = URL(string: "https://github.com/stevyhacker/LokalBot")!

    static let activeDaysBeforeAsking = 7

    static let demoLibraryMarker = ".lokalbot-demo-library"

    struct State: Equatable {
        var dismissed = false
        var summaryCompleted = false
        var activeDays: [String] = []
    }

    struct Launch: Equatable {
        var uiTesting = false
        var unitTesting = false
        var headless = false
        var seededDemoLibrary = false

        var suppressesPrompt: Bool {
            uiTesting || unitTesting || headless || seededDemoLibrary
        }
    }

    static func shouldShow(_ state: State, in launch: Launch) -> Bool {
        guard !launch.suppressesPrompt, !state.dismissed else { return false }
        return state.summaryCompleted || state.activeDays.count >= activeDaysBeforeAsking
    }

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
