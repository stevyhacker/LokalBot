import XCTest
@testable import LokalBot

/// A prompt-capable speech model answers a near-silent span with its
/// vocabulary hint. Synthetic names stand in for the rows seen in a library.
final class TranscriptionPromptEchoTests: XCTestCase {
    private let prompt = "LokalBot\nJelena Marković, Them 6 · source 2, Mila Novak, Orion Launch, Acme."

    func testMatchesRowsMadeOnlyOfPromptWords() throws {
        let echo = try XCTUnwrap(TranscriptionPromptEcho(prompt: prompt))
        for text in [
            "Jelena Marković, Them 6 · source 2, Mila Novak, Orion Launch, Acme.",
            "Them 6 · source 2, Mila Novak, Orion Launch, Acme.",
            "Orion Launch, Acme.",
            "acme mila novak",
            "Jelena Markovic, LokalBot.",
            "LokalBot LokalBot",
        ] {
            XCTAssertTrue(echo.matches(text), text)
        }
        for text in [
            "Mila Novak.",
            "Acme",
            "Acme ships Orion Launch on Monday.",
            "Mila, are you there?",
            "",
            "...",
        ] {
            XCTAssertFalse(echo.matches(text), text)
        }
        XCTAssertNil(TranscriptionPromptEcho(prompt: nil))
        XCTAssertNil(TranscriptionPromptEcho(prompt: " , ."))
    }

    @MainActor func testTrackTranscriberNeverEmitsPromptEchoRows() async throws {
        let engine = EchoingASR(rows: [
            ("Let's review the Orion Launch budget.", 0, 3),
            ("Mila Novak, Orion Launch, Acme.", 3.1, 3.5),
            ("Agreed, Mila Novak.", 4, 5),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")

        let transcript = try await AttributedTrackTranscriber.transcribe(
            url: url, duration: 6, diarization: [], source: .microphone, engine: engine,
            language: nil, prompt: prompt)

        XCTAssertEqual(transcript.segments.map(\.text),
                       ["Let's review the Orion Launch budget.", "Agreed, Mila Novak."])
        XCTAssertEqual(transcript.segments.map(\.speaker), ["local", "local"])
        let unprompted = try await AttributedTrackTranscriber.transcribe(
            url: url, duration: 6, diarization: [], source: .microphone, engine: engine,
            language: nil, prompt: nil)
        XCTAssertEqual(unprompted.segments.count, 3, "without a prompt no row can be an echo")
    }

    func testQwenDropsEchoSpansBeforeVotingOnTheTrackLanguage() {
        let segments: [Transcript.Segment] = [
            .init(start: 0, end: 4, speaker: "speaker", text: "Wir treffen uns morgen um zehn Uhr im Büro."),
            .init(start: 5, end: 5.4, speaker: "speaker", text: "Mila Novak, Orion Launch, Acme."),
        ]

        let kept = QwenASREngine.withoutPromptEchoes(segments, prompt: prompt)

        XCTAssertEqual(kept.map(\.text), ["Wir treffen uns morgen um zehn Uhr im Büro."])
        XCTAssertEqual(QwenASREngine.withoutPromptEchoes(segments, prompt: nil).count, 2)
    }

    private struct EchoingASR: TranscriptionEngine {
        var rows: [(text: String, start: Double, end: Double)]
        var displayName: String { "Echo fixture" }
        var supportsStreaming: Bool { false }
        func prepare(progress: ModelPreparationProgressHandler?) async throws {}
        func transcribe(audio: URL, language: String?) async throws -> Transcript {
            Transcript(segments: rows.map { .init(start: $0.start, end: $0.end, speaker: "", text: $0.text) },
                       engine: displayName)
        }
    }
}
