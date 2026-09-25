import XCTest
@testable import LokalBot

@MainActor
final class ModelSpeechCheckTests: XCTestCase {
    private actor Engine: TranscriptionEngine {
        nonisolated let displayName = "Fixture"
        nonisolated let supportsStreaming = false
        let text: String
        var options: (String?, String?)?
        init(_ text: String) { self.text = text }
        func prepare(progress: ModelPreparationProgressHandler?) async throws {}
        func transcribe(audio: URL, language: String?) async throws -> Transcript {
            try await transcribe(audio: audio, language: language, prompt: nil)
        }
        func transcribe(audio: URL, language: String?, prompt: String?) async throws -> Transcript {
            options = (language, prompt)
            return Transcript(segments: [.init(start: 0, end: 1, speaker: "speaker", text: text, confidence: nil)], engine: "fixture")
        }
    }

    func testEmptyTranscriptCannotPassAndConfiguredOptionsReachInference() async throws {
        let fixture = URL(fileURLWithPath: "/synthetic/speech.wav")
        var settings = AppSettings()
        settings.transcriptionLanguage = .ru
        settings.transcriptionPrompt = "Local vocabulary"
        let empty = Engine("")
        do {
            try await ModelCheckController.checkTranscription(engine: empty, fixture: fixture, configuration: settings)
            XCTFail("VAD skipping every span must not pass a speech check")
        } catch {}
        let spoken = Engine("spoken words")
        try await ModelCheckController.checkTranscription(engine: spoken, fixture: fixture, configuration: settings)
        let options = await spoken.options
        XCTAssertEqual(options?.0, "ru")
        XCTAssertEqual(options?.1, "Local vocabulary")
    }
}
