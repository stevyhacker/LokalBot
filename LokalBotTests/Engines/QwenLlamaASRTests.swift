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
        let v3 = QwenLlamaASR.accuracyLokalBotV3, stock17 = QwenLlamaASR.accuracy
        let v1 = QwenLlamaASR.compactLokalBotV1, stock06 = QwenLlamaASR.compact
        XCTAssertEqual(v3.url(for: v3.model, appSupport: appSupport).path,
                       "/tmp/app/qwen3-asr-models/gguf/Qwen3-ASR-1.7B-Q8_0/Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf")
        XCTAssertEqual(
            v3.downloadURL(for: v3.model).absoluteString,
            "https://huggingface.co/stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF/resolve/"
                + "33ca434ce773d56914f609cec80e843d085b5645/Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf")
        XCTAssertEqual(
            v3.downloadURL(for: v3.projector).absoluteString,
            "https://huggingface.co/stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF/resolve/"
                + "33ca434ce773d56914f609cec80e843d085b5645/mmproj-Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf")
        XCTAssertEqual(stock17.url(for: stock17.model, appSupport: appSupport).path,
                       "/tmp/app/qwen3-asr-models/gguf/Qwen3-ASR-1.7B-Q8_0/Qwen3-ASR-1.7B-Q8_0.gguf")
        XCTAssertEqual(
            stock17.downloadURL(for: stock17.model).absoluteString,
            "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/"
                + "36a678687ba7d07a74ca70ccb0e36902e005fb80/Qwen3-ASR-1.7B-Q8_0.gguf")
        XCTAssertEqual(v1.url(for: v1.model, appSupport: appSupport).path,
                       "/tmp/app/qwen3-asr-models/gguf/Qwen3-ASR-0.6B-Q8_0/Qwen3-ASR-0.6B-LokalBot-v1-Q8_0.gguf")
        XCTAssertEqual(
            v1.downloadURL(for: v1.model).absoluteString,
            "https://huggingface.co/stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF/resolve/"
                + "4f9e435248343b208223ce33fa1a8b0b2f2e6bc6/Qwen3-ASR-0.6B-LokalBot-v1-Q8_0.gguf")
        XCTAssertEqual(
            v1.downloadURL(for: v1.projector).absoluteString,
            "https://huggingface.co/stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF/resolve/"
                + "4f9e435248343b208223ce33fa1a8b0b2f2e6bc6/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf")
        XCTAssertEqual(stock06.url(for: stock06.model, appSupport: appSupport).path,
                       "/tmp/app/qwen3-asr-models/gguf/Qwen3-ASR-0.6B-Q8_0/Qwen3-ASR-0.6B-Q8_0.gguf")
        XCTAssertEqual(
            stock06.downloadURL(for: stock06.model).absoluteString,
            "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/"
                + "928ab958557df9aa2ef1c93e0e83c7ad0933fae2/Qwen3-ASR-0.6B-Q8_0.gguf")
        for file in QwenLlamaASR.allWeights.flatMap(\.files) {
            XCTAssertEqual(file.sha256.count, 64, file.name)
        }
        XCTAssertEqual(v3.legacyMLXDirectory(appSupport: appSupport).path,
                       "/tmp/app/qwen3-asr-models/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit")
        XCTAssertEqual(v1.legacyMLXDirectory(appSupport: appSupport).path,
                       "/tmp/app/qwen3-asr-models/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
        XCTAssertTrue(QwenLlamaASR.serverArguments.contains("--cache-ram"))
    }

    func testFineTunedAndStockGGUFWeightsCoexistAndRemoveIndependently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-coexist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func writeGGUF(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("GGUF".utf8).write(to: url)
        }

        let v3 = QwenLlamaASR.accuracyLokalBotV3
        let stock17 = QwenLlamaASR.accuracy
        for file in stock17.files { try writeGGUF(stock17.url(for: file, appSupport: root)) }
        XCTAssertTrue(stock17.isDownloaded(appSupport: root))
        XCTAssertFalse(v3.isDownloaded(appSupport: root))
        XCTAssertEqual(v3.missingBytes(appSupport: root), v3.totalBytes)

        for file in v3.files { try writeGGUF(v3.url(for: file, appSupport: root)) }
        XCTAssertTrue(stock17.isDownloaded(appSupport: root))
        XCTAssertTrue(v3.isDownloaded(appSupport: root))
        XCTAssertEqual(v3.missingBytes(appSupport: root), 0)

        try stock17.removeFiles(appSupport: root)
        XCTAssertFalse(stock17.isDownloaded(appSupport: root))
        XCTAssertTrue(v3.isDownloaded(appSupport: root))

        let v1 = QwenLlamaASR.compactLokalBotV1
        let stock06 = QwenLlamaASR.compact
        for file in stock06.files { try writeGGUF(stock06.url(for: file, appSupport: root)) }
        XCTAssertTrue(stock06.isDownloaded(appSupport: root))
        XCTAssertFalse(v1.isDownloaded(appSupport: root))
        XCTAssertEqual(v1.missingBytes(appSupport: root), v1.model.bytes)

        try writeGGUF(v1.url(for: v1.model, appSupport: root))
        XCTAssertTrue(v1.isDownloaded(appSupport: root))
        try stock06.removeFiles(appSupport: root)
        XCTAssertFalse(stock06.isDownloaded(appSupport: root))
        XCTAssertTrue(v1.isDownloaded(appSupport: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: v1.url(for: v1.projector, appSupport: root).path))

        try v1.removeFiles(appSupport: root)
        XCTAssertFalse(v1.isDownloaded(appSupport: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: v1.modelRoot(appSupport: root).path))
    }

    func testQwenServersHaveTheirOwnPortsAndTranscribeRows() {
        XCTAssertEqual(LlamaServerRole.qwenASR.releasePort, 17_877)
        XCTAssertEqual(LlamaServerRole.qwenASRCompact.releasePort, 17_878)
        XCTAssertEqual(QwenLlamaASR.accuracyLokalBotV3.role, .qwenASR)
        XCTAssertEqual(QwenLlamaASR.accuracy.role, .qwenASR)
        XCTAssertEqual(QwenLlamaASR.compactLokalBotV1.role, .qwenASRCompact)
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

    func testServerTransitionDefersReplacementWhileTranscriptionUsesServer() {
        XCTAssertEqual(
            QwenASREngine.serverTransition(
                hasServer: true,
                loadedModelPath: "/models/legacy.gguf",
                loadedProjectorPath: "/models/legacy-mmproj.gguf",
                nextModelPath: "/models/v3.gguf",
                nextProjectorPath: "/models/v3-mmproj.gguf",
                activeServerUses: 1
            ),
            .deferReplacement
        )
        XCTAssertEqual(
            QwenASREngine.serverTransition(
                hasServer: true,
                loadedModelPath: "/models/legacy.gguf",
                loadedProjectorPath: "/models/shared-mmproj.gguf",
                nextModelPath: "/models/v1.gguf",
                nextProjectorPath: "/models/shared-mmproj.gguf",
                activeServerUses: 1
            ),
            .deferReplacement
        )
        XCTAssertEqual(
            QwenASREngine.serverTransition(
                hasServer: true,
                loadedModelPath: "/models/legacy.gguf",
                loadedProjectorPath: "/models/legacy-mmproj.gguf",
                nextModelPath: "/models/v3.gguf",
                nextProjectorPath: "/models/v3-mmproj.gguf",
                activeServerUses: 0
            ),
            .replaceNow
        )
        XCTAssertEqual(
            QwenASREngine.serverTransition(
                hasServer: true,
                loadedModelPath: "/models/v3.gguf",
                loadedProjectorPath: "/models/v3-mmproj.gguf",
                nextModelPath: "/models/v3.gguf",
                nextProjectorPath: "/models/v3-mmproj.gguf",
                activeServerUses: 2
            ),
            .reuse
        )
        XCTAssertEqual(
            QwenASREngine.serverTransition(
                hasServer: false,
                loadedModelPath: nil,
                loadedProjectorPath: nil,
                nextModelPath: "/models/v3.gguf",
                nextProjectorPath: "/models/v3-mmproj.gguf",
                activeServerUses: 1
            ),
            .reuse
        )
    }
}
