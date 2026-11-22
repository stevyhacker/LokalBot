import XCTest
@testable import LokalBot

final class QwenLlamaASRTests: XCTestCase {
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
        let accuracy = QwenLlamaASR.accuracy, compact = QwenLlamaASR.compact
        XCTAssertEqual(accuracy.url(for: accuracy.model, appSupport: appSupport).path,
                       "/tmp/app/qwen3-asr-models/gguf/Qwen3-ASR-1.7B-Q8_0/Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf")
        XCTAssertEqual(
            accuracy.downloadURL(for: accuracy.model).absoluteString,
            "https://huggingface.co/stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF/resolve/"
                + "33ca434ce773d56914f609cec80e843d085b5645/Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf")
        XCTAssertEqual(
            accuracy.downloadURL(for: accuracy.projector).absoluteString,
            "https://huggingface.co/stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF/resolve/"
                + "33ca434ce773d56914f609cec80e843d085b5645/mmproj-Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf")
        XCTAssertEqual(compact.url(for: compact.model, appSupport: appSupport).path,
                       "/tmp/app/qwen3-asr-models/gguf/Qwen3-ASR-0.6B-Q8_0/Qwen3-ASR-0.6B-LokalBot-v1-Q8_0.gguf")
        XCTAssertEqual(
            compact.downloadURL(for: compact.model).absoluteString,
            "https://huggingface.co/stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF/resolve/"
                + "4f9e435248343b208223ce33fa1a8b0b2f2e6bc6/Qwen3-ASR-0.6B-LokalBot-v1-Q8_0.gguf")
        XCTAssertEqual(
            compact.downloadURL(for: compact.projector).absoluteString,
            "https://huggingface.co/stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF/resolve/"
                + "4f9e435248343b208223ce33fa1a8b0b2f2e6bc6/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf")
        for file in accuracy.files + compact.files {
            XCTAssertEqual(file.sha256.count, 64, file.name)
        }
        XCTAssertEqual(accuracy.legacyMLXDirectory(appSupport: appSupport).path,
                       "/tmp/app/qwen3-asr-models/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit")
        XCTAssertEqual(compact.legacyMLXDirectory(appSupport: appSupport).path,
                       "/tmp/app/qwen3-asr-models/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
        XCTAssertTrue(QwenLlamaASR.serverArguments.contains("--cache-ram"))
    }

    func testLegacyStockGGUFWeightsRemainUsableAndCleanUpAfterUpgrade() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func writeGGUF(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("GGUF".utf8).write(to: url)
        }

        let accuracy = QwenLlamaASR.accuracy
        try writeGGUF(accuracy.url(for: try XCTUnwrap(accuracy.legacyModel), appSupport: root))
        try writeGGUF(accuracy.url(for: try XCTUnwrap(accuracy.legacyProjector), appSupport: root))
        XCTAssertTrue(accuracy.isDownloaded(appSupport: root))
        XCTAssertTrue(accuracy.hasLegacyGGUFWeights(appSupport: root))
        XCTAssertFalse(accuracy.hasCurrentWeights(appSupport: root))
        XCTAssertEqual(accuracy.missingCurrentBytes(appSupport: root),
                       accuracy.model.bytes + accuracy.projector.bytes)

        try writeGGUF(accuracy.url(for: accuracy.model, appSupport: root))
        try writeGGUF(accuracy.url(for: accuracy.projector, appSupport: root))
        accuracy.removeSupersededGGUFWeights(appSupport: root)
        XCTAssertTrue(accuracy.hasCurrentWeights(appSupport: root))
        XCTAssertFalse(accuracy.hasLegacyGGUFWeights(appSupport: root))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: accuracy.url(for: try XCTUnwrap(accuracy.legacyModel), appSupport: root).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: accuracy.url(for: try XCTUnwrap(accuracy.legacyProjector), appSupport: root).path))

        let compact = QwenLlamaASR.compact
        try writeGGUF(compact.url(for: try XCTUnwrap(compact.legacyModel), appSupport: root))
        try writeGGUF(compact.url(for: try XCTUnwrap(compact.legacyProjector), appSupport: root))
        XCTAssertTrue(compact.hasLegacyGGUFWeights(appSupport: root))
        XCTAssertEqual(compact.missingCurrentBytes(appSupport: root), compact.model.bytes)

        try writeGGUF(compact.url(for: compact.model, appSupport: root))
        compact.removeSupersededGGUFWeights(appSupport: root)
        XCTAssertTrue(compact.hasCurrentWeights(appSupport: root))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: compact.url(for: compact.projector, appSupport: root).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: compact.url(for: try XCTUnwrap(compact.legacyModel), appSupport: root).path))
    }

    func testQwenServersHaveTheirOwnPortsAndTranscribeRows() {
        XCTAssertEqual(LlamaServerRole.qwenASR.releasePort, 17_877)
        XCTAssertEqual(LlamaServerRole.qwenASRCompact.releasePort, 17_878)
        XCTAssertEqual(QwenLlamaASR.accuracy.role, .qwenASR)
        XCTAssertEqual(QwenLlamaASR.compact.role, .qwenASRCompact)
        XCTAssertEqual(Set(LlamaServerRole.allCases.map(\.releasePort)).count, LlamaServerRole.allCases.count)
        for role in [LlamaServerRole.qwenASR, .qwenASRCompact] {
            XCTAssertEqual(ResourceMonitorPresentation.role(for: role.residencyID), "Transcribe")
            XCTAssertNil(InferenceRole(serverRole: role))
        }
    }

    func testCachedModelsTranscribeAWindowOnTheAppServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["LOKALBOT_QWEN_LLAMA_TEST_MODEL_DIR"],
              let audioPath = environment["LOKALBOT_QWEN_LLAMA_TEST_AUDIO"] else {
            throw XCTSkip("Set LOKALBOT_QWEN_LLAMA_TEST_MODEL_DIR (both GGUFs) and LOKALBOT_QWEN_LLAMA_TEST_AUDIO")
        }
        let models = URL(fileURLWithPath: modelPath, isDirectory: true)
        let weights = environment["LOKALBOT_QWEN_LLAMA_TEST_TIER"] == "0.6b" ? QwenLlamaASR.compact : QwenLlamaASR.accuracy
        let server = weights.makeServer(
            projector: models.appendingPathComponent(weights.projector.name))
        guard LocalLlamaServerAuthentication.readMarker(port: server.port) == nil else {
            throw XCTSkip("Needs the unused port \(server.port).")
        }
        let reader = try SpanAudioReader(url: URL(fileURLWithPath: audioPath))
        let samples = try reader.samples(from: 0, to: min(15, reader.duration))
        XCTAssertGreaterThan(samples.count, 16_000)
        do {
            try await server.ensureRunning(modelAt: models.appendingPathComponent(weights.model.name))
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
