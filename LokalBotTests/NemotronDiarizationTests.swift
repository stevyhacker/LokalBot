import XCTest
@testable import LokalBot

final class NemotronDiarizationTests: XCTestCase {
    private actor Attempts {
        var count = 0
        func fail() throws {
            count += 1
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func testFailedNemotronLoadSurfacesErrorAndCanBeRetriedWithoutCommunityFallback() async {
        let attempts = Attempts()
        let engine = NeuralDiarizationEngine(communityLoader: {
            XCTFail("Selecting Nemotron without remembering must not load Pyannote")
            throw CocoaError(.fileNoSuchFile)
        }, nemotronLoader: {
            try await attempts.fail()
            throw CocoaError(.fileReadCorruptFile)
        })
        for _ in 0..<2 {
            do {
                try await engine.prepareModels(model: .nemotron3, includeVoiceSamples: false)
                XCTFail("A failed selected model must not become a successful empty diarization")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Nemotron"))
            }
        }
        let count = await attempts.count
        XCTAssertEqual(count, 2)
    }

    func testOverlappingSlotsSurviveConversionAndCannotBecomeNamedSpeech() throws {
        // One second of speaker 0, with speaker 7 also active during the middle.
        var probabilities = [Float](repeating: 0, count: 100 * 8)
        for frame in 0..<100 { probabilities[frame * 8] = 0.9 }
        for frame in 30..<70 { probabilities[frame * 8 + 7] = 0.9 }
        let segments = NeuralDiarizationEngine.nemotronSegments(probabilities: probabilities, frameCount: 100)
        XCTAssertEqual(Set(segments.map(\.speakerId)), ["S0", "S7"])
        let regions = AttributedTrackTranscriber.regions(duration: 1, turns: segments, source: .system)
        let overlap = try XCTUnwrap(regions.first { $0.attribution.method == .overlappingSpeech })
        XCTAssertEqual(overlap.attribution.identity, .unresolved)
        XCTAssertEqual(overlap.start, 0.3, accuracy: 0.0001)
        XCTAssertEqual(overlap.end, 0.7, accuracy: 0.0001)
    }

    func testSilenceAndBriefActivationsDoNotProduceSpeakers() {
        var probabilities = [Float](repeating: 0, count: 100 * 8)
        XCTAssertTrue(NeuralDiarizationEngine.nemotronSegments(probabilities: probabilities, frameCount: 100).isEmpty)
        for frame in 0..<19 { probabilities[frame * 8] = 0.9 }
        XCTAssertTrue(NeuralDiarizationEngine.nemotronSegments(probabilities: probabilities, frameCount: 100).isEmpty)
    }

    func testPyannoteSamplesMapByCleanTimeCoverageNotNemotronSlotNumber() {
        let transcript = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "them 2", text: "Clear speech",
                  attribution: .init(source: .system, identity: .other, method: .diarization)),
            .init(start: 5, end: 6, speaker: "them unclear", text: "Overlap",
                  attribution: .init(source: .system, identity: .unresolved, method: .overlappingSpeech)),
        ], engine: "fixture")
        let clean = SpeakerVoiceSample(speaker: "S0", range: .init(start: 0, end: 5), vector: [Float](repeating: 0.1, count: 256))
        var mixed = clean
        mixed.range.end = 6
        let accepted = AttributedTrackTranscriber.samples([clean, mixed], transcript: transcript, source: .system)
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(accepted.first?.speaker, "them 2")
        XCTAssertEqual(accepted.first?.vector, clean.vector)
        XCTAssertEqual(accepted.first?.model, SpeakerVoiceSample.fingerprint)
        XCTAssertTrue(AttributedTrackTranscriber.samples([clean], transcript: transcript, source: .microphone).isEmpty)
    }

    func testCancelledPreparationDoesNotDownloadOrFallBack() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await NeuralDiarizationEngine().prepareModels(model: .nemotron3, includeVoiceSamples: false)
        }
        do {
            try await task.value
            XCTFail("Cancelled preparation must throw")
        } catch is CancellationError {
            // No network or generic-speaker success.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testModelDownloadsArePinnedAndComplete() {
        let artifacts = NemotronDiarizationModels.artifacts
        XCTAssertEqual(Set(artifacts.map(\.path)).count, artifacts.count)
        XCTAssertEqual(artifacts.reduce(0) { $0 + $1.bytes }, 199_164_847)
        for artifact in artifacts {
            XCTAssertTrue(artifact.remoteURL.path.contains("/resolve/\(NemotronDiarizationModels.revision)/"))
            XCTAssertFalse(artifact.remoteURL.path.contains("/main/"))
            XCTAssertEqual(artifact.sha256.count, 64)
        }
    }
}
