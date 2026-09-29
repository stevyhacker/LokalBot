import Foundation

/// Writers live here because they reach generation checkpoints; the file
/// names and read-only helpers are shared with the CLI in Models.
extension MeetingAttributionArtifacts {
    static func invalidate(in folder: URL, preservingOutcomes: Bool = false) throws {
        var files = ["summary.md": "summary.previous.md", "summary-claims.json": "summary-claims.previous.json"]
        if !preservingOutcomes { files["outcomes.json"] = previousOutcomes }
        for (current, previous) in files {
            let url = folder.appendingPathComponent(current)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try Data(contentsOf: url).write(to: folder.appendingPathComponent(previous), options: .atomic)
            try FileManager.default.removeItem(at: url)
        }
        try Data("{\"needs_refresh\":true}".utf8).write(
            to: folder.appendingPathComponent(refreshMarker), options: .atomic)
        MeetingSummaryGenerator.removeCheckpoint(in: folder)
        MeetingOutcomesGenerator.removeCheckpoint(in: folder)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("summary.claims.partial.json"))
    }

    static func requireCurrent(_ transcript: Transcript, in folder: URL) throws {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
              let current = try? JSONDecoder().decode(Transcript.self, from: data),
              current.evidenceRevision == transcript.evidenceRevision else {
            throw TextEngineError.badResponse("Speaker attribution changed during generation. Refresh the meeting notes.")
        }
    }
}
