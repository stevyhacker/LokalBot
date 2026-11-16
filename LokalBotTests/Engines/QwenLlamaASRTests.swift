import XCTest
@testable import LokalBot

final class QwenLlamaASRTests: XCTestCase {
    /// The prompt must match speech-swift's Qwen3ASRModel token for token, or
    /// the language hint and vocabulary stop working as benchmarked.
    func testPromptMatchesSpeechSwiftLayout() {
        XCTAssertEqual(
            QwenLlamaASR.prompt(language: "sr", context: "Mila Novak, Orion"),
            "<|im_start|>system\nMila Novak, Orion<|im_end|>\n<|im_start|>user\n<__media__><|im_end|>\n"
                + "<|im_start|>assistant\nlanguage sr<asr_text>")
        XCTAssertEqual(
            QwenLlamaASR.prompt(language: nil, context: nil),
            "<|im_start|>system\n<|im_end|>\n<|im_start|>user\n<__media__><|im_end|>\n"
                + "<|im_start|>assistant\n<asr_text>")
        XCTAssertEqual(QwenLlamaASR.serverEnvironment["LLAMA_MEDIA_MARKER"], QwenLlamaASR.mediaMarker)
    }

    func testRequestPostsGreedyCompletionWithAudioAndBearer() throws {
        let base = URL(string: "http://127.0.0.1:17907/v1")!
        let request = try QwenLlamaASR.makeRequest(
            serverBaseURL: base, authenticationToken: "secret", samples: [0, 0.5, -0.5],
            sampleRate: 16_000, language: "en", context: "LokalBot", maxTokens: 128)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:17907/completion")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["n_predict"] as? Int, 128)
        XCTAssertEqual(body["temperature"] as? Double, 0)
        XCTAssertEqual(body["cache_prompt"] as? Bool, false)
        let prompt = try XCTUnwrap(body["prompt"] as? [String: Any])
        XCTAssertEqual(prompt["prompt_string"] as? String,
                       QwenLlamaASR.prompt(language: "en", context: "LokalBot"))
        let audio = try XCTUnwrap((prompt["multimodal_data"] as? [String])?.first)
        let wav = try XCTUnwrap(Data(base64Encoded: audio))
        XCTAssertEqual(wav.count, 44 + 3 * 4)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    }

    func testTranscriptDropsAutoDetectedLanguagePrefix() throws {
        func text(_ content: String) throws -> String {
            try QwenLlamaASR.transcript(fromCompletion: JSONSerialization.data(withJSONObject: ["content": content]))
        }
        XCTAssertEqual(try text(" Dobar dan. "), "Dobar dan.")
        XCTAssertEqual(try text("language Serbian<asr_text>Dobar dan."), "Dobar dan.")
        XCTAssertThrowsError(try QwenLlamaASR.transcript(fromCompletion: Data("{}".utf8)))
    }

    func testPinnedFilesLiveUnderTheQwenCacheAndPointAtTheRevision() {
        let appSupport = URL(fileURLWithPath: "/tmp/app", isDirectory: true)
        XCTAssertEqual(QwenLlamaASR.url(for: QwenLlamaASR.model, appSupport: appSupport).path,
                       "/tmp/app/qwen3-asr-models/gguf/Qwen3-ASR-1.7B-Q8_0/Qwen3-ASR-1.7B-Q8_0.gguf")
        XCTAssertEqual(
            QwenLlamaASR.downloadURL(for: QwenLlamaASR.projector).absoluteString,
            "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/"
                + "36a678687ba7d07a74ca70ccb0e36902e005fb80/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf")
        for file in QwenLlamaASR.files {
            XCTAssertEqual(file.sha256.count, 64, file.name)
        }
        XCTAssertEqual(QwenLlamaASR.legacyMLXDirectory(appSupport: appSupport).path,
                       "/tmp/app/qwen3-asr-models/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit")
        XCTAssertTrue(QwenLlamaASR.serverArguments.contains("--cache-ram"))
    }

    func testQwenServerHasItsOwnPortAndTranscribeRow() {
        XCTAssertEqual(LlamaServerRole.qwenASR.releasePort, 17_877)
        XCTAssertEqual(Set(LlamaServerRole.allCases.map(\.releasePort)).count, LlamaServerRole.allCases.count)
        XCTAssertEqual(ResourceMonitorPresentation.role(for: LlamaServerRole.qwenASR.residencyID), "Transcribe")
        XCTAssertNil(InferenceRole(serverRole: .qwenASR))
    }

    /// Opt-in end to end: the app's `qwen-asr` llama-server with the pinned
    /// GGUFs transcribes real speech through `QwenASREngine.transcribeWindow`.
    /// A request fails if the server ignores LLAMA_MEDIA_MARKER, since the
    /// prompt then lacks its randomized marker. Needs a folder with both GGUFs
    /// and a public speech clip (FLEURS or AMI); only the first 15 s is sent.
    func testCachedModelsTranscribeAWindowOnTheAppServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["LOKALBOT_QWEN_LLAMA_TEST_MODEL_DIR"],
              let audioPath = environment["LOKALBOT_QWEN_LLAMA_TEST_AUDIO"] else {
            throw XCTSkip("Set LOKALBOT_QWEN_LLAMA_TEST_MODEL_DIR (both GGUFs) and LOKALBOT_QWEN_LLAMA_TEST_AUDIO")
        }
        let models = URL(fileURLWithPath: modelPath, isDirectory: true)
        let server = QwenLlamaASR.makeServer(
            projector: models.appendingPathComponent(QwenLlamaASR.projector.name))
        guard LocalLlamaServerAuthentication.readMarker(port: server.port) == nil else {
            throw XCTSkip("Needs the unused port \(server.port).")
        }
        let reader = try SpanAudioReader(url: URL(fileURLWithPath: audioPath))
        let samples = try reader.samples(from: 0, to: min(15, reader.duration))
        XCTAssertGreaterThan(samples.count, 16_000)
        do {
            try await server.ensureRunning(modelAt: models.appendingPathComponent(QwenLlamaASR.model.name))
            for language in [environment["LOKALBOT_QWEN_LLAMA_TEST_LANGUAGE"], nil] {
                let text = try await QwenASREngine.transcribeWindow(
                    samples: samples, language: language, prompt: nil, server: server)
                print("qwen-asr llama window language=\(language ?? "auto"): \(text)")
                XCTAssertFalse(text.isEmpty)
                XCTAssertFalse(text.contains("<asr_text>"), text)
                XCTAssertFalse(text.hasPrefix("language "), text)
                if let expected = environment["LOKALBOT_QWEN_LLAMA_TEST_EXPECT"] {
                    XCTAssertTrue(text.localizedCaseInsensitiveContains(expected), text)
                }
            }
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
}
