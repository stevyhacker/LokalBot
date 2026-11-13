import XCTest
@testable import LokalBot

final class SpeakerMicrophoneEvidenceTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("microphone-evidence-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private var sample: SpeakerVoiceSample {
        var vector = [Float](repeating: 0, count: 256); vector[0] = 1
        return .init(speaker: "local 1", range: .init(start: 3, end: 8), vector: vector, source: .microphone)
    }
    private var transcript: Transcript {
        Transcript(segments: [
            .init(start: 3, end: 8, speaker: "local 1", text: "Synthetic local speech",
                  attribution: .init(source: .microphone, identity: .unresolved, method: .diarization)),
            .init(start: 20, end: 23, speaker: "them 1", text: "Synthetic remote speech",
                  attribution: .init(source: .system, identity: .other, method: .diarization)),
        ], engine: "rule fixture", echoReport: .init(status: .disabled))
    }
    private func prepare(remoteBurst: Range<Int>? = nil, clockOffset: Double = 0) throws {
        var pcm = [Float](repeating: 0, count: 30 * 16_000)
        if let remoteBurst { for index in remoteBurst { pcm[index] = 0.1 } }
        let writer = try WavWriter(url: folder.appendingPathComponent("system.m4a"), sampleRate: 16_000)
        try writer.append(pcm); try writer.finish()
        let mic = AudioClockSpan(hostStart: 100, hostEnd: 130, startFrame: 0, endFrame: 480_000, sampleRate: 16_000, generation: 1)
        var system = mic; system.hostStart -= clockOffset; system.hostEnd -= clockOffset
        let timing = RecordingAudioTiming(microphone: [mic], system: [system])
        try JSONEncoder().encode(timing).write(to: folder.appendingPathComponent(RecordingAudioTiming.fileName))
    }
    private func select(_ value: Transcript? = nil) async -> SpeakerMicrophoneEvidence.Selection {
        let transcript = value ?? self.transcript
        let turns = transcript.segments.map { SpeakerAudioTurn(speaker: $0.speaker,
            range: .init(start: $0.start, end: $0.end), source: $0.resolvedAttribution.source) }
        return await SpeakerMicrophoneEvidence.select(samples: [sample], transcript: transcript, turns: turns, folder: folder)
    }

    func testEchoOffStillAcceptsClockAlignedQuietReferenceTurns() async throws {
        try prepare()
        let result = await select()
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertEqual(result.counts["quietReference"], 1)
        XCTAssertEqual(result.samples.first?.source, .microphone)
    }

    func testRemoteSpeechAndWaveformActivityBothRejectPossibleEcho() async throws {
        try prepare()
        var transcript = transcript
        transcript.segments[1].start = 7; transcript.segments[1].end = 9
        let speech = await select(transcript)
        XCTAssertTrue(speech.samples.isEmpty)
        XCTAssertEqual(speech.counts["remoteSpeech"], 1)
        try prepare(remoteBurst: 80_000..<80_160)
        let burst = await select()
        XCTAssertTrue(burst.samples.isEmpty, "A brief syllable missed by ASR/diarization is still contamination")
        XCTAssertEqual(burst.counts["remoteAudioOrMissingSamples"], 1)
    }

    func testClockOffsetIsAppliedBeforeReadingTheReferenceWaveform() async throws {
        try prepare(remoteBurst: 144_000..<160_000, clockOffset: 2)
        let result = await select()
        XCTAssertTrue(result.samples.isEmpty)
        XCTAssertEqual(result.counts["remoteAudioOrMissingSamples"], 1)
    }

    func testMissingClockAndKnownRemoteWithoutReferenceDoNotBecomeSilence() async throws {
        let missingReference = await select()
        XCTAssertTrue(missingReference.samples.isEmpty)
        try prepare()
        try FileManager.default.removeItem(at: folder.appendingPathComponent(RecordingAudioTiming.fileName))
        let missingClock = await select()
        XCTAssertTrue(missingClock.samples.isEmpty)
        XCTAssertEqual(missingClock.counts["missingClockOrReference"], 1)
    }

    func testAmbiguousOrSuspectedEchoMicrophoneSpeechCannotEnroll() async throws {
        try prepare()
        for method in [SpeakerAttribution.Method.track, .overlappingSpeech, .suspectedEcho] {
            var transcript = transcript
            transcript.segments[0].attribution?.method = method
            let result = await select(transcript)
            XCTAssertTrue(result.samples.isEmpty)
            XCTAssertEqual(result.counts["ambiguousMicrophone"], 1)
        }
    }

    func testQuietReferenceRequiresCompleteFiniteSamplesAndNoShortBurst() {
        let silence = [Float](repeating: 0, count: 48_000)
        XCTAssertTrue(SpeakerMicrophoneEvidence.referenceIsQuiet(silence, expectedDuration: 3))
        XCTAssertFalse(SpeakerMicrophoneEvidence.referenceIsQuiet(Array(silence.prefix(40_000)), expectedDuration: 3))
        var invalid = silence; invalid[100] = .nan
        XCTAssertFalse(SpeakerMicrophoneEvidence.referenceIsQuiet(invalid, expectedDuration: 3))
        invalid[100] = 0.01
        XCTAssertFalse(SpeakerMicrophoneEvidence.referenceIsQuiet(invalid, expectedDuration: 3))
    }
}
