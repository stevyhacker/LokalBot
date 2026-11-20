import Foundation

enum AgentReadAccessCopy {
    static let switchTitle = "Allow external agents to read your LokalBot data"

    static func path(ticking box: String) -> String {
        "LokalBot → Settings → External Agents: \"\(switchTitle)\", then tick \(box)"
    }
}
