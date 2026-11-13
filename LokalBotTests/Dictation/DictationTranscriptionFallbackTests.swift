import XCTest
@testable import LokalBot

/// 2026-11-10: OpenRouter stopped accepting the saved key. Every dictation
/// recorded, was refused with HTTP 401, and ended with nothing typed and a
/// message only LokalBot's own window shows.
@MainActor
final class DictationTranscriptionFallbackTests: XCTestCase {
    private let rejected = RemoteTranscriptionError.rejected(status: 401, detail: "User not found.")

    func testAModelOnThisMacTranscribesWhenTheServerRefuses() async throws {
        var transcribedWith: TranscriptionModelChoice?
        let spoken = try await DictationTranscriptionFallback.transcribe(
            settings: settings(),
            localChoice: { _ in .qwenASR06B },
            selected: { throw self.rejected },
            onThisMac: { local in
                transcribedWith = local.transcriptionModel
                return self.transcript("Ship it on Thursday", engine: "Qwen3-ASR 0.6B")
            })

        XCTAssertEqual(transcribedWith, .qwenASR06B)
        XCTAssertEqual(spoken.transcript.segments.map(\.text), ["Ship it on Thursday"])
        XCTAssertEqual(spoken.fallback?.choice, .qwenASR06B)
        // The HUD says what the server said, so the key gets fixed.
        let notice = DictationProblemNotice.transcribedOnThisMac(try XCTUnwrap(spoken.fallback))
        XCTAssertEqual(notice.title, "Transcribed on this Mac")
        XCTAssertEqual(
            notice.detail, "The transcription server rejected the API key (HTTP 401). User not found.")
    }

    func testAWorkingServerIsNotReplaced() async throws {
        let spoken = try await DictationTranscriptionFallback.transcribe(
            settings: settings(),
            localChoice: { _ in .qwenASR06B },
            selected: { self.transcript("From the server", engine: "server") },
            onThisMac: { _ in
                XCTFail("the server answered")
                return self.transcript("", engine: "")
            })
        XCTAssertEqual(spoken.transcript.engine, "server")
        XCTAssertNil(spoken.fallback)
    }

    func testTheServerErrorIsReportedWhenNothingCanTakeOver() async {
        // No model on disk.
        await assertServerError {
            try await DictationTranscriptionFallback.transcribe(
                settings: self.settings(), localChoice: { _ in nil },
                selected: { throw self.rejected },
                onThisMac: { _ in self.transcript("never", engine: "") })
        }
        // The stand-in failed too: the key is still what needs fixing.
        await assertServerError {
            try await DictationTranscriptionFallback.transcribe(
                settings: self.settings(), localChoice: { _ in .whisperLarge },
                selected: { throw self.rejected },
                onThisMac: { _ in throw CocoaError(.fileReadCorruptFile) })
        }
    }

    func testOnlyAServerFailureIsReplaced() async {
        // "No speech", a cancelled dictation and the like keep their meaning.
        do {
            _ = try await DictationTranscriptionFallback.transcribe(
                settings: settings(), localChoice: { _ in .qwenASR06B },
                selected: { throw CancellationError() },
                onThisMac: { _ in
                    XCTFail("nothing to replace")
                    return self.transcript("", engine: "")
                })
            XCTFail("the cancellation is passed on")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testTheStandInIsADownloadedModelThatFitsTheLanguage() {
        let onDisk: Set<TranscriptionModelChoice> = [.parakeetV2, .whisperLarge, .qwenASR06B, .gigaamRussian]
        func choice(_ settings: AppSettings, onDisk: Set<TranscriptionModelChoice>) -> TranscriptionModelChoice? {
            DictationTranscriptionFallback.localChoice(for: settings) { onDisk.contains($0) }
        }

        XCTAssertEqual(choice(settings(), onDisk: onDisk), .whisperLarge, "the best downloaded model")
        XCTAssertEqual(choice(settings(), onDisk: [.qwenASR17B, .whisperLarge]), .qwenASR17B)
        XCTAssertNil(choice(settings(), onDisk: []), "nothing is downloaded for a failed dictation")
        XCTAssertNil(choice(settings(.qwenASR17B), onDisk: onDisk), "only the server is replaced")

        // English-only models stand in for English alone, and narrow ones never.
        XCTAssertNil(choice(settings(), onDisk: [.parakeetV2, .graniteTurbo, .gigaamRussian, .senseVoice]))
        XCTAssertEqual(choice(settings(language: .en), onDisk: [.parakeetV2, .gigaamRussian]), .parakeetV2)
        // Qwen cannot be told to write Ukrainian; Whisper can.
        XCTAssertEqual(choice(settings(language: .uk), onDisk: [.qwenASR17B, .whisperLarge]), .whisperLarge)
        XCTAssertNil(choice(settings(language: .uk), onDisk: [.qwenASR17B]))
    }

    // MARK: - Helpers

    private func settings(
        _ model: TranscriptionModelChoice = .remoteServer, language: TranscriptionLanguage = .auto
    ) -> AppSettings {
        var settings = AppSettings()
        settings.transcriptionModel = model
        settings.transcriptionLanguage = language
        return settings
    }

    private func transcript(_ text: String, engine: String) -> Transcript {
        Transcript(segments: [.init(start: 0, end: 2, speaker: "me", text: text)], engine: engine)
    }

    private func assertServerError(
        _ run: () async throws -> DictationTranscriptionFallback.Spoken,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await run()
            XCTFail("the server's error is passed on", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RemoteTranscriptionError, rejected, file: file, line: line)
        }
    }
}
