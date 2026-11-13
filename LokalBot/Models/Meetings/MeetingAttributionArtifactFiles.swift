import Foundation

/// Stale-attribution markers written beside a meeting's outcomes. Read-only
/// helpers live here so file-backed readers (CLI, MCP) share one definition.
enum MeetingAttributionArtifacts {
    static let refreshMarker = "attribution-refresh-needed.json"
    static let previousOutcomes = "outcomes.previous.json"

    static func needsRefresh(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(refreshMarker).path)
    }

    static func previous(in folder: URL) -> MeetingOutcomes? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(previousOutcomes)) else { return nil }
        return try? JSONDecoder().decode(MeetingOutcomes.self, from: data)
    }
}
