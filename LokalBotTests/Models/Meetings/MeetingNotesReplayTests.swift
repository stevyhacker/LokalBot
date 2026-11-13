import XCTest
@testable import LokalBot

/// Opt-in, local-only latency/quality replay. Normal unit/CI runs skip it.
/// The manifest and all transcript/output files stay outside the repository.
final class MeetingNotesReplayTests: XCTestCase {
    private actor Recorder {
        let folder: URL
        var count = 0
        init(folder: URL) { self.folder = folder }
        func save(_ content: String) throws {
            count += 1
            try Data(content.utf8).write(to: folder.appendingPathComponent("model-response-\(count).txt"), options: .atomic)
        }
    }

    private struct RecordingEngine: TextEngine {
        let base: OpenAICompatibleEngine
        let recorder: Recorder
        var displayName: String { base.displayName }
        var accountsForGenerationRequests: Bool { true }
        func tokenCount(_ text: String) async throws -> Int? { try await base.tokenCount(text) }
        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            try await base.generate(system: system, prompt: prompt, context: context)
        }
        func generate(system: String, prompt: String, context: [String], schema: [String: Any],
                      options: TextGenerationOptions) async throws -> String {
            do {
                let result = try await base.generate(system: system, prompt: prompt, context: context, schema: schema, options: options)
                try await recorder.save(result)
                return result
            } catch let truncated as TruncatedStructuredResponse {
                try await recorder.save(truncated.content)
                throw truncated
            }
        }
    }
    private struct Manifest: Decodable {
        var transcript: String
        var output: String
        var endpoint: String
        var tokenFile: String
    }

    func testLocalCloudPlanningAndTranscriptCleanup() async throws {
        struct PlanManifest: Decodable { var transcripts: [String]; var output: String }
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_NOTES_PLAN_MANIFEST"] else {
            throw XCTSkip("Set LOKALBOT_NOTES_PLAN_MANIFEST for local-only planning and cleanup measurements.")
        }
        let manifest = try JSONDecoder().decode(PlanManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let folder = URL(fileURLWithPath: manifest.output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // This engine's tokenizer returns nil without a network request. No
        // generation method is called by this planning-only replay.
        let engine = OpenAICompatibleEngine(baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "z-ai/glm-5.3-flash", apiKey: nil, chatDialect: .openRouter)
        var reports: [[String: Any]] = []
        for (index, path) in manifest.transcripts.enumerated() {
            let source = URL(fileURLWithPath: path)
            let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: source))
            let cleanup = TranscriptSanitizer.sanitize(transcript)
            let language = SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: transcript)
            let system = MeetingNotesGenerator.systemPrompt(template: .meeting, language: language)
            let context = MeetingNotes.promptContext(in: source.deletingLastPathComponent())
            var counts: [Int] = []
            for value in [transcript, cleanup.transcript] {
                let evidence = MeetingNotesEvidence(transcript: value)
                let chunks = try await MeetingNotesGenerator.makeChunks(evidence: evidence, engine: engine,
                    system: system, context: context, contextTokens: 32_768)
                counts.append(chunks.count)
                XCTAssertEqual(Set(chunks.flatMap { $0.map(\.source) }), Set(evidence.units.map(\.source)))
                for chunk in chunks {
                    let text = ([system] + context + [MeetingNotesGenerator.prompt(units: chunk, roster: evidence.roster)])
                        .joined(separator: "\n\n")
                    XCTAssertLessThanOrEqual(text.utf8.count + 4_096 + 1_536, 32_768)
                }
            }
            try JSONEncoder().encode(cleanup.transcript)
                .write(to: folder.appendingPathComponent("\(index)-sanitized-transcript.json"), options: .atomic)
            let words = transcript.segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
            reports.append(["source": source.deletingLastPathComponent().lastPathComponent, "words": words,
                            "changedSegments": cleanup.changedSegments, "removedWords": cleanup.removedWords,
                            "partsBeforeCleanup": counts[0], "partsAfterCleanup": counts[1]])
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("planning.json"), options: .atomic)
    }

    func testLocalQwenReplay() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_NOTES_REPLAY_MANIFEST"] else {
            throw XCTSkip("Set LOKALBOT_NOTES_REPLAY_MANIFEST to run the isolated local benchmark.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let endpoint = try XCTUnwrap(URL(string: manifest.endpoint))
        XCTAssertEqual(endpoint.host, "127.0.0.1", "meeting replays must stay local")
        guard endpoint.host == "127.0.0.1" else { return }
        let source = URL(fileURLWithPath: manifest.transcript)
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: source))
        let folder = URL(fileURLWithPath: manifest.output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = try String(contentsOf: URL(fileURLWithPath: manifest.tokenFile), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = OpenAICompatibleEngine(baseURL: endpoint, model: "qwen3.5-4b", apiKey: token,
            extraBody: MainLLMRuntimePolicy.requestOverrides(for: "qwen3.5-4b"), chatDialect: .llamaServer)
        let engine = RecordingEngine(base: base, recorder: Recorder(folder: folder))
        let language = SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: transcript)
        let result = try await MeetingNotesGenerator.generate(transcript: transcript, engine: engine,
            template: .meeting, language: language, context: MeetingNotes.promptContext(in: source.deletingLastPathComponent()),
            contextTokens: MainLLMRuntimePolicy.contextTokens, meetingID: UUID(), folder: folder)
        try SummaryClaimEvidence.commit(transcript: transcript, in: folder)
        try result.outcomes.write(to: folder)
        try Data(result.body.utf8).write(to: folder.appendingPathComponent("summary.md"), options: .atomic)
        // Optional prior outcomes/state live only in the copied replay input.
        // Exercise the same reconciliation as a notes-only regeneration, while
        // preserving unmatched manual edits for review rather than losing them.
        let input = source.deletingLastPathComponent()
        let previousURL = input.appendingPathComponent(MeetingOutcomes.fileName)
        if FileManager.default.fileExists(atPath: previousURL.path) {
            let previous = try JSONDecoder().decode(MeetingOutcomes.self, from: Data(contentsOf: previousURL))
            let state = MeetingOutcomeStore.loadState(from: input)
            let reconciled = MeetingOutcomeStore.reconcileState(state, from: previous, to: result.outcomes)
            try MeetingOutcomeStore.writeState(reconciled, to: folder)
            let edits = Array(state.actions.values) + Array((state.unmatchedActions ?? [:]).values)
            let retained = Array(reconciled.actions.values) + Array((reconciled.unmatchedActions ?? [:]).values)
            XCTAssertEqual(edits.count, retained.count)
            for edit in edits { XCTAssertTrue(retained.contains(edit), "Replay must retain every manual action edit") }
        }
        // Mechanical source/identity checks supplement manual coverage review.
        let claimsJSON = try SummaryClaimEvidence.encode(result.claims)
        XCTAssertNoThrow(try SummaryClaimEvidence.decode(claimsJSON, transcript: transcript, template: .meeting))
        for action in result.outcomes.actionItems {
            XCTAssertFalse(action.citations.isEmpty)
            XCTAssertTrue(action.citations.allSatisfy { transcript.segmentSourceMap[$0.segmentID] != nil })
            if action.isForUser {
                let owner = try XCTUnwrap(action.attribution?.speakerID)
                XCTAssertEqual(transcript.speakerRoster[owner]?.identity, .user)
                XCTAssertNil(action.attribution?.rejectionReason)
            }
        }
    }
}
