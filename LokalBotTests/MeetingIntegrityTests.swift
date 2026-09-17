import XCTest
@testable import LokalBot

final class MeetingIntegrityTests: XCTestCase {
    func testBrowserRequiresCallControlsAndSustainedSameDocument() {
        XCTAssertEqual(BrowserMeetingSession.state(buttons: ["Join now", "Turn off microphone"], messages: []), .unavailable)
        XCTAssertEqual(BrowserMeetingSession.state(buttons: ["Leave call", "Turn on microphone (⌘D)"], messages: []), .inCall)
        XCTAssertEqual(BrowserMeetingSession.state(buttons: ["Leave call", "Turn on microphone"], messages: ["You left the meeting"]), .ended)
        let first = URL(string: "https://meet.google.com/abc-defg-hij")!
        let second = URL(string: "https://meet.google.com/klm-nopq-rst")!
        let now = Date(timeIntervalSince1970: 100)
        var gate = BrowserMeetingSession.StartGate()
        XCTAssertFalse(gate.observe(.init(url: first, state: .inCall), at: now))
        XCTAssertFalse(gate.observe(.init(url: first, state: .inCall), at: now.addingTimeInterval(1)))
        XCTAssertTrue(gate.observe(.init(url: first, state: .inCall), at: now.addingTimeInterval(2)))
        XCTAssertFalse(gate.observe(.init(url: second, state: .inCall), at: now.addingTimeInterval(3)))
        XCTAssertFalse(gate.observe(nil, at: now.addingTimeInterval(4)))
        XCTAssertFalse(gate.observe(.init(url: second, state: .inCall), at: now.addingTimeInterval(6)))
        XCTAssertFalse(gate.observe(.init(url: second, state: .inCall), at: now.addingTimeInterval(20)))
    }

    func testVideoAndCalendarNeverProveBrowserSession() {
        XCTAssertTrue(BrowserMeetingSession.hasConflictingAudio(selectedAudibleTabs: [false], hasBoundDocument: true))
        XCTAssertTrue(BrowserMeetingSession.hasConflictingAudio(selectedAudibleTabs: [true], hasBoundDocument: false))
        XCTAssertFalse(BrowserMeetingSession.hasConflictingAudio(selectedAudibleTabs: [true], hasBoundDocument: true))
        for strict in [true, false] {
            XCTAssertFalse(MeetingMatcher.browserCountsAsMeeting(titleMatchesMarker: true, hasOutputAudio: true,
                calendarBacked: true, requireCalendarForBrowser: strict))
            XCTAssertTrue(MeetingMatcher.browserCountsAsMeeting(titleMatchesMarker: false, hasOutputAudio: false,
                calendarBacked: true, requireCalendarForBrowser: strict, verifiedSession: true))
        }
    }

    func testOldMicrophoneDefaultsCannotCreateUserSummaryEvidence() throws {
        let transcript = Transcript(segments: [
            .init(start: 3, end: 9, speaker: "local 1", text: "I will take a holiday before Patagonia.",
                  attribution: .init(source: .microphone, identity: .user, method: .diarization)),
            .init(start: 3.1, end: 9.1, speaker: "them 1", text: "Yes, I will take a holiday before Patagonia.",
                  attribution: .init(source: .system, identity: .other, method: .diarization)),
        ], engine: "fixture", speakerAliases: ["them 1": "Nikola"])
        let reopened = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))
        let evidence = MeetingNotesEvidence(transcript: reopened)
        XCTAssertFalse(evidence.units.contains(where: \.isUserCommitment))
        XCTAssertFalse(evidence.roster.contains("\"identity\":\"user\""))
        let raw = #"{"notes":[],"actions":[{"text":"Take a holiday","source":"s1","context":[],"owner":"source","basis":"commitment","due":"","importance":3}],"has_more":false}"#
        let result = evidence.validate(raw, units: evidence.units, template: .meeting,
            meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.userActionItems.isEmpty)
        let misleading = #"{"notes":[{"section":"Key points","text":"You will take a holiday.","source":"s1"}],"actions":[],"has_more":false}"#
        let protected = evidence.validate(misleading, units: evidence.units, template: .meeting,
            meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(protected.claims.isEmpty)
    }

    func testExplicitOtherSpeakerCorrectionSurvivesEchoFiltering() {
        let text = "I will send the report on Friday."
        let transcript = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "local 1", text: text, timingPrecision: .span,
                  attribution: .init(source: .microphone, identity: .other, method: .confirmation)),
            .init(start: 0, end: 5, speaker: "them 1", text: text, timingPrecision: .span,
                  attribution: .init(source: .system, identity: .other, method: .diarization)),
        ], engine: "fixture")
        let result = SpeakerBleedFilter.filter(transcript, acousticallyVerifiedIndices: [0])
        XCTAssertEqual(result.transcript.segments, transcript.segments)
        XCTAssertTrue(result.acousticCandidateIndices.isEmpty)
    }

    /// Optional replay reads local recordings without modifying them or calling
    /// an inference provider. CI uses only the synthetic regression cases.
    func testLocalSavedTranscriptReplay() throws {
        guard let manifest = ProcessInfo.processInfo.environment["LOKALBOT_INTEGRITY_REPLAY"] else {
            throw XCTSkip("Set LOKALBOT_INTEGRITY_REPLAY to a JSON list of local transcript paths.")
        }
        let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        var checked = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let original = try Data(contentsOf: url)
            let transcript = try JSONDecoder().decode(Transcript.self, from: original)
            let defaults = transcript.segments.filter {
                $0.attribution?.source == .microphone && [.track, .diarization, .legacy].contains($0.attribution?.method ?? .legacy)
            }
            XCTAssertFalse(defaults.isEmpty)
            XCTAssertTrue(defaults.allSatisfy { $0.resolvedAttribution.identity == .unresolved })
            XCTAssertEqual(try Data(contentsOf: url), original)
            checked += defaults.count
        }
        XCTAssertGreaterThan(checked, 0)
        print("Local attribution replay checked \(paths.count) recordings and \(checked) unconfirmed microphone segments; original files unchanged.")
    }

    func testBoundariesExcludeWholeCrossingSpansAndPreserveOriginalTimestamps() throws {
        let original = Transcript(segments: [
            .init(start: 0, end: 10, speaker: "them", text: "Pre-roll"),
            .init(start: 10, end: 20, speaker: "them", text: "Crossing start"),
            .init(start: 20, end: 30, speaker: "them", text: "Meeting"),
            .init(start: 30, end: 40, speaker: "them", text: "Crossing end"),
            .init(start: 40, end: 50, speaker: "them", text: "Video"),
        ], engine: "fixture")
        let range = Meeting.ContentRange(start: 15, end: 35)
        let saved = try JSONDecoder().decode(Meeting.ContentRange.self, from: JSONEncoder().encode(range))
        let filtered = saved.applying(to: original)
        XCTAssertEqual(filtered.segments.map(\.text), ["Meeting"])
        XCTAssertEqual(filtered.segments.first?.start, 20)
        XCTAssertEqual(original.segments.count, 5)
        XCTAssertFalse(Meeting.ContentRange(start: .nan, end: 10).isValid)
        XCTAssertFalse(Meeting.ContentRange(start: 10, end: 10).isValid)
    }

    private struct InspectingASR: TranscriptionEngine {
        var displayName: String { "Boundary fixture" }
        var supportsStreaming: Bool { false }
        func prepare(progress: ModelPreparationProgressHandler?) async throws {}
        func transcribe(audio: URL, language: String?) async throws -> Transcript {
            let reader = try SpanAudioReader(url: audio)
            XCTAssertEqual(reader.duration, 2, accuracy: 0.001)
            let samples = try reader.samples(from: 0, to: reader.duration)
            XCTAssertTrue(samples.allSatisfy { abs($0 - 0.2) < 0.001 }, "ASR must never receive excluded audio")
            return Transcript(segments: [.init(start: 0, end: 2, speaker: "", text: "Included meeting")], engine: displayName)
        }
    }

    @MainActor func testRetranscriptionReadsOnlySelectedAudioRange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("raw.wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000)
        try writer.append(Array(repeating: Float(0.8), count: 16_000))
        try writer.append(Array(repeating: Float(0.2), count: 32_000))
        try writer.append(Array(repeating: Float(0.9), count: 16_000))
        try writer.finish()
        let original = try Data(contentsOf: url)
        let transcript = try await AttributedTrackTranscriber.transcribe(url: url, duration: 4, diarization: [],
            source: .system, engine: InspectingASR(), language: nil, prompt: nil,
            contentRange: .init(start: 1, end: 3))
        XCTAssertEqual(transcript.segments.first?.start, 1)
        XCTAssertEqual(transcript.segments.first?.end, 3)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAcousticSuspicionToleratesColorationWithoutAuthorizingDeletion() {
        let reference: [Float] = (0..<64_000).map { index in
            let t = Double(index) / 16_000
            let envelope = 0.15 + 0.12 * sin(t * 9) + 0.02 * sin(t * 23)
            return Float(envelope * (sin(t * 1_100) + 0.5 * sin(t * 3_137) + 0.3 * sin(t * 5_419)))
        }
        let colored = reference.enumerated().map { index, sample in
            sample * 0.4 + (index > 7 ? reference[index - 8] * 0.3 : 0)
        }
        XCTAssertTrue(EchoWaveformEvidence.suspectedEcho(microphone: colored, reference: reference))
        XCTAssertFalse(EchoWaveformEvidence.nearIdentical(microphone: colored, reference: reference))
        XCTAssertFalse(EchoWaveformEvidence.suspectedEcho(microphone: colored, reference: Array(repeating: 0, count: colored.count)))
    }

    private actor Responses {
        var calls = 0
        let response: String
        init(_ response: String) { self.response = response }
        func next() -> String { calls += 1; return response }
    }
    private struct NotesEngine: TextEngine {
        let responses: Responses
        var displayName: String { "Recovery fixture" }
        func generate(system: String, prompt: String, context: [String]) async throws -> String { await responses.next() }
    }
    private func recoveryJob(_ responses: Responses) -> MeetingNotesGenerator.PartJob {
        let source = Transcript(segments: [.init(start: 0, end: 5, speaker: "them", text: "The release date remains Friday.")], engine: "fixture")
        let evidence = MeetingNotesEvidence(transcript: source)
        return .init(evidence: evidence, units: evidence.units, engine: NotesEngine(responses: responses),
                     template: .meeting, language: .matchTranscript, context: [], contextTokens: 32_768,
                     meetingID: UUID(), number: 1, remainingParts: 1, budget: MeetingGenerationBudget())
    }

    func testLegacySourceLessCheckpointGetsOneFreshScanAndCanComplete() async throws {
        let replies = Responses(#"{"notes":[{"section":"Key points","text":"Release remains Friday.","source":"s1"}],"actions":[],"has_more":false}"#)
        var part = MeetingNotesGenerator.Part(recovery: .init(nextPage: 5, scanComplete: true,
            pending: [.init(sources: [], kind: "notes", reason: "unknown_source")]))
        try await MeetingNotesGenerator.generatePart(part, job: recoveryJob(replies)) { part = $0 }
        XCTAssertTrue(part.complete)
        XCTAssertTrue(part.recovery?.pending.isEmpty == true)
        let count = await replies.calls
        XCTAssertEqual(count, 1)
    }

    func testInvalidProviderIDsBecomeTerminalWithoutRepeatedRequests() async throws {
        let replies = Responses(#"{"notes":[{"section":"Key points","text":"Release remains Friday.","source":"invented"}],"actions":[],"has_more":false}"#)
        var part = MeetingNotesGenerator.Part()
        do {
            try await MeetingNotesGenerator.generatePart(part, job: recoveryJob(replies)) { part = $0 }
            XCTFail("invalid references must never certify completion")
        } catch { XCTAssertTrue(error.localizedDescription.contains("invalid evidence IDs")) }
        let persisted = try JSONDecoder().decode(MeetingNotesGenerator.Part.self, from: JSONEncoder().encode(part))
        XCTAssertNotNil(persisted.recovery?.terminalFailure)
        do {
            try await MeetingNotesGenerator.generatePart(persisted, job: recoveryJob(replies)) { _ in }
            XCTFail("same failed checkpoint must remain explicit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("invalid evidence IDs")) }
        let count = await replies.calls
        XCTAssertEqual(count, 1)
    }

    func testRepeatedEmptyProviderProgressBecomesTerminalAcrossResumes() async throws {
        let replies = Responses(#"{"notes":[],"actions":[],"has_more":true}"#)
        var part = MeetingNotesGenerator.Part()
        try await MeetingNotesGenerator.generatePart(part, job: recoveryJob(replies)) { part = $0 }
        XCTAssertFalse(part.complete)
        do {
            try await MeetingNotesGenerator.generatePart(part, job: recoveryJob(replies)) { part = $0 }
            XCTFail("repeated empty continuations must stop")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no further verifiable progress")) }
        do {
            try await MeetingNotesGenerator.generatePart(part, job: recoveryJob(replies)) { part = $0 }
            XCTFail("a third identical attempt must not call the provider")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no further verifiable progress")) }
        let count = await replies.calls
        XCTAssertEqual(count, 2)
    }

    func testChangingSummaryProviderInvalidatesCheckpointWithoutIncludingCredentials() {
        let first = OpenAICompatibleEngine(baseURL: URL(string: "https://first.example/v1")!, model: "same-model", apiKey: "secret-fixture")
        let second = OpenAICompatibleEngine(baseURL: URL(string: "https://second.example/v1")!, model: "same-model", apiKey: "secret-fixture")
        XCTAssertNotEqual(first.checkpointIdentity, second.checkpointIdentity)
        XCTAssertFalse(first.checkpointIdentity.contains("secret-fixture"))
    }
}
