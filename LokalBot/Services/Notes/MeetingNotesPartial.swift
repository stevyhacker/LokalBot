import Foundation

/// A coherent, revision-checked snapshot for the meeting detail view. Partial
/// work never enters the completed outcome index or replaces final artifacts.
struct MeetingNotesPartial: Codable {
    static let fileName = "notes.partial.json"
    var version = 1
    var transcriptRevision: String
    var summary: String
    var outcomes: MeetingOutcomes
    var completedParts: Int
    var totalParts: Int
    var template: NoteTemplate = .meeting

    var progressLabel: String { "Partial notes · \(completedParts) of \(totalParts) parts complete" }

    func write(in folder: URL) throws {
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static func load(in folder: URL, transcript: Transcript, template: NoteTemplate = .meeting) -> Self? {
        let url = folder.appendingPathComponent(fileName)
        let snapshot: Self?
        let updatedAt: Date
        if FileManager.default.fileExists(atPath: url.path) {
            snapshot = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
            updatedAt = modified(url)
        } else {
            // Show progress saved by the previous app version as soon as the
            // fixed app opens, without rewriting the user's meeting library.
            snapshot = legacy(in: folder, transcript: transcript, template: template)
            updatedAt = modified(folder.appendingPathComponent("summary.partial.md"))
        }
        guard let snapshot, snapshot.version == 1,
              snapshot.transcriptRevision == transcript.evidenceRevision,
              snapshot.outcomes.transcriptRevision == transcript.evidenceRevision,
              snapshot.totalParts > 0, (0...snapshot.totalParts).contains(snapshot.completedParts) else { return nil }
        // A successfully published result supersedes an earlier checkpoint,
        // including if cleanup was interrupted after the final write.
        if MeetingOutcomes.load(from: folder) != nil,
           modified(folder.appendingPathComponent("summary.md")) >= updatedAt { return nil }
        return snapshot
    }

    func projection(for meeting: Meeting, in folder: URL) -> MeetingOutcomeProjection {
        var state = MeetingOutcomeStore.loadState(from: folder)
        if let previous = MeetingOutcomes.load(from: folder) ?? MeetingAttributionArtifacts.previous(in: folder) {
            state = MeetingOutcomeStore.reconcileState(state, from: previous, to: outcomes)
        }
        return .init(meeting: meeting, outcomes: outcomes, state: state,
                     followUp: FollowUpDraft.seeded(for: meeting, outcomes: outcomes))
    }

    private static func legacy(in folder: URL, transcript: Transcript, template: NoteTemplate) -> Self? {
        guard let claimsData = try? Data(contentsOf: folder.appendingPathComponent("summary.claims.partial.json")),
              let claims = try? JSONDecoder().decode(SummaryClaimEvidence.Artifact.self, from: claimsData),
              claims.transcriptRevision == transcript.evidenceRevision,
              let data = try? Data(contentsOf: folder.appendingPathComponent("outcomes.partial.json")),
              let outcomes = try? JSONDecoder().decode(MeetingOutcomes.self, from: data),
              let markdown = try? String(contentsOf: folder.appendingPathComponent("summary.partial.md"), encoding: .utf8),
              let firstLine = markdown.split(separator: "\n").first,
              let range = firstLine.range(of: #"\d+/\d+"#, options: .regularExpression) else { return nil }
        let counts = firstLine[range].split(separator: "/").compactMap { Int($0) }
        guard counts.count == 2 else { return nil }
        // Render from revision-checked evidence rather than trusting a Markdown
        // file that could be left behind by an interrupted multi-file save.
        let overview = MeetingNotesGenerator.overviewClaims(claims.claims, outcomes: outcomes)
            .map { claim in var copy = claim; copy.section = "TL;DR"; return copy }
        let body = MeetingSummaryOutcomeSynchronizer.synchronize(
            SummaryClaimEvidence.render(overview + claims.claims, transcript: transcript, template: template),
            outcomes: outcomes, template: template)
        return Self(transcriptRevision: claims.transcriptRevision, summary: body, outcomes: outcomes,
                    completedParts: counts[0], totalParts: counts[1], template: template)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
