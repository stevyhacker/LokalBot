import Foundation

/// How messages to agents name the one Settings switch for reading LokalBot
/// data and the box for each kind under it (Settings → Privacy → External
/// agents). The app's toggle uses the same title.
enum AgentReadAccessCopy {
    static let switchTitle = "Allow external agents to read your LokalBot data"

    /// "LokalBot → Settings → Privacy → External agents: "Allow …", then tick Meetings"
    static func path(ticking box: String) -> String {
        "LokalBot → Settings → Privacy → External agents: \"\(switchTitle)\", then tick \(box)"
    }
}
