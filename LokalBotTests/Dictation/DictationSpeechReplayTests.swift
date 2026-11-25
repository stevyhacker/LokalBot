import XCTest
@testable import LokalBot

final class DictationSpeechReplayTests: XCTestCase {
    func testParsesALocalModelAndDefaultsToAutomaticLanguageAndThreePasses() {
        let request = DictationSpeechReplay.parse(["LokalBot", "--dictation-speech-replay", "/tmp/cases.json",
                                                   "--model", "parakeet-v3"])
        XCTAssertEqual(request, .init(input: URL(fileURLWithPath: "/tmp/cases.json"), model: .parakeetV3,
                                      language: .auto, passes: 3))
        XCTAssertEqual(DictationSpeechReplay.parse(["LokalBot", "--dictation-speech-replay", "/tmp/cases.json",
                                                    "--model", "qwen3-asr-1.7b", "--language", "en", "--passes", "99"]),
                       .init(input: URL(fileURLWithPath: "/tmp/cases.json"), model: .qwenASR17B, language: .en,
                             passes: 10))
    }

    func testRefusesRemoteServersAndUnknownModels() {
        XCTAssertNil(DictationSpeechReplay.parse(["LokalBot", "--dictation-speech-replay", "/tmp/c.json",
                                                  "--model", TranscriptionModelChoice.remoteServer.rawValue]))
        XCTAssertNil(DictationSpeechReplay.parse(["LokalBot", "--dictation-speech-replay", "/tmp/c.json",
                                                  "--model", "not-a-model"]))
        XCTAssertNil(DictationSpeechReplay.parse(["LokalBot", "--dictation-speech-replay", "/tmp/c.json"]))
    }

    func testUnparsableArgumentsAreStillRecognisedAsAReplayRequest() {
        XCTAssertTrue(DictationSpeechReplay.isRequested(["LokalBot", "--dictation-speech-replay"]))
        XCTAssertFalse(DictationSpeechReplay.isRequested(["LokalBot"]))
        XCTAssertNil(DictationSpeechReplay.parse(["LokalBot", "--dictation-speech-replay", "/tmp/c.json",
                                                  "--model", "parakeet-v3", "--language", "xx"]))
        XCTAssertNil(DictationSpeechReplay.parse(["LokalBot", "--dictation-speech-replay", "/tmp/c.json",
                                                  "--model", "parakeet-v3", "--passes", "many"]))
        XCTAssertNil(DictationSpeechReplay.parse(["LokalBot", "--dictation-speech-replay", "/tmp/c.json",
                                                  "--model"]))
    }

    func testTheMiddlePassRunsBackwardsAndNoVocabularyIsSent() {
        XCTAssertEqual(DictationSpeechReplay.order(count: 3, pass: 0), [0, 1, 2])
        XCTAssertEqual(DictationSpeechReplay.order(count: 3, pass: 1), [2, 1, 0])
        XCTAssertEqual(DictationSpeechReplay.order(count: 3, pass: 2), [0, 1, 2])
        var request = DictationSpeechReplay.parse(["LokalBot", "--dictation-speech-replay", "/tmp/c.json",
                                                   "--model", "parakeet-ultra"])!
        request.language = .en
        let settings = DictationSpeechReplay.settings(for: request)
        XCTAssertEqual(settings.transcriptionModel, .parakeetUltra)
        XCTAssertEqual(settings.transcriptionLanguage, .en)
        XCTAssertEqual(settings.transcriptionPrompt, "")
    }
}
