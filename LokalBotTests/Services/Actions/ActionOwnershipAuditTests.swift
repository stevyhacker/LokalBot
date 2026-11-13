import XCTest
@testable import LokalBot

/// Opt-in, local-only audit of action ownership on real meetings. Normal
/// unit/CI runs skip it. The copied meetings and the report stay outside the
/// repository.
///
/// Saved outcomes keep the rows each action cites but not the model's answer.
/// The audit therefore replays every saved action through the current rules
/// twice: once as the model claiming the cited speaker committed to it, and
/// once with no claim, which is what the rows prove on their own.
final class ActionOwnershipAuditTests: XCTestCase {
    private struct Replay {
        var resolution = "dropped"
        var owner = ""
        var reason = ""
    }

    func testSavedActionsThroughCurrentOwnershipRules() throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_OWNERSHIP_AUDIT"] else {
            throw XCTSkip("Set LOKALBOT_OWNERSHIP_AUDIT to a folder of copied meeting folders.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines: [String] = []
        var totals: [String: Int] = [:]
        for folder in folders {
            guard let transcript = try? JSONDecoder().decode(Transcript.self,
                      from: Data(contentsOf: folder.appendingPathComponent("transcript.json"))),
                  let outcomes = try? JSONDecoder().decode(MeetingOutcomes.self,
                      from: Data(contentsOf: folder.appendingPathComponent(MeetingOutcomes.fileName))) else { continue }
            let evidence = MeetingNotesEvidence(transcript: transcript)
            let compact = Dictionary(uniqueKeysWithValues: transcript.summaryCitationSources.map { ($0.value, $0.key) })
            for action in outcomes.actionItems {
                let ids = action.citations.compactMap { compact[$0.segmentID] }
                guard !ids.isEmpty, ids.count == action.citations.count else { continue }
                let stored = action.attribution?.resolution.rawValue ?? "legacy"
                let claimed = try replay(action, ids: ids, owner: "source", basis: "commitment", evidence: evidence)
                let proven = try replay(action, ids: ids, owner: "unknown", basis: "unclear", evidence: evidence)
                totals["stored \(stored)", default: 0] += 1
                totals["claimed \(claimed.resolution)", default: 0] += 1
                totals["proven \(proven.resolution)", default: 0] += 1
                let speaker = action.citations.first.map { Transcript.canonicalSpeakerKey($0.speaker) } ?? ""
                let microphone = MeetingOutcomes.isMicrophoneSpeaker(speaker)
                if microphone {
                    totals["microphone stored \(stored)", default: 0] += 1
                    totals["microphone claimed \(claimed.resolution)", default: 0] += 1
                    totals["microphone proven \(proven.resolution)", default: 0] += 1
                }
                lines.append([
                    folder.lastPathComponent, microphone ? "mic" : "remote",
                    "stored=\(stored)/\(action.attribution?.rejectionReason?.rawValue ?? "-")/\(action.owner ?? "-")",
                    "claimed=\(claimed.resolution)/\(claimed.reason)/\(claimed.owner)",
                    "proven=\(proven.resolution)/\(proven.reason)/\(proven.owner)",
                    action.text,
                    action.citations.map { "[\($0.speaker)] \($0.excerpt)" }.joined(separator: " || "),
                ].joined(separator: "\t"))
            }
        }
        let summary = totals.keys.sorted().map { "\($0): \(totals[$0]!)" }
        try (summary + [""] + lines).joined(separator: "\n")
            .write(to: root.appendingPathComponent("ownership-audit.tsv"), atomically: true, encoding: .utf8)
        print(summary.joined(separator: "\n"))
        XCTAssertFalse(lines.isEmpty, "no saved actions with resolvable citations under \(path)")
    }

    private func replay(_ action: MeetingOutcomes.ActionItem, ids: [String], owner: String, basis: String,
                        evidence: MeetingNotesEvidence) throws -> Replay {
        let raw: [String: Any] = [
            "text": action.text, "source": ids[0], "context": Array(ids.dropFirst().prefix(2)), "owner": owner,
            "basis": basis, "quote": "", "due": "", "importance": 3,
        ]
        let output = String(decoding: try JSONSerialization.data(withJSONObject: [
            "notes": [[String: Any]](), "actions": [raw], "has_more": false] as [String: Any]), as: UTF8.self)
        let result = evidence.validate(output, units: evidence.units, template: .meeting, meetingID: UUID(),
                                       maximumNotes: 12, maximumActions: 10)
        guard let item = result.outcomes.actionItems.first else {
            return Replay(reason: result.rejected.first?.reason ?? "")
        }
        return Replay(resolution: item.attribution?.resolution.rawValue ?? "", owner: item.owner ?? "-",
                      reason: item.attribution?.rejectionReason?.rawValue ?? "-")
    }
}
