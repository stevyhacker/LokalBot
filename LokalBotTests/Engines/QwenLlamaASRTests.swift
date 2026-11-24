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

    private enum FakeRuntimeError: Error, Equatable {
        case stockDownloadFailed
        case stockStartupFailed
    }

    private actor AsyncSignal {
        private var signaled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            signaled = true
            let current = waiters
            waiters.removeAll()
            for waiter in current { waiter.resume() }
        }

        func wait() async {
            if signaled { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private actor FakeManagedServer: QwenASREngine.ManagedServer {
        let label: String
        private(set) var startedModels: [URL] = []
        private(set) var stopCount = 0
        private var onStart: (@Sendable (URL) async throws -> Void)?
        private let stoppedSignal = AsyncSignal()

        init(label: String, onStart: (@Sendable (URL) async throws -> Void)? = nil) {
            self.label = label
            self.onStart = onStart
        }

        func setOnStart(_ handler: (@Sendable (URL) async throws -> Void)?) {
            onStart = handler
        }

        func ensureRunning(modelAt url: URL) async throws {
            startedModels.append(url)
            if let onStart {
                try await onStart(url)
            }
        }

        func stop() async {
            stopCount += 1
            await stoppedSignal.signal()
        }

        func waitUntilStopped() async {
            await stoppedSignal.wait()
        }
    }

    private actor ServerRecorder {
        private(set) var created: [FakeManagedServer] = []

        func record(_ server: FakeManagedServer) {
            created.append(server)
        }

        func labels() -> [String] {
            created.map(\.label)
        }
    }

    private static func fakePaths(for weights: QwenLlamaASR.Weights) -> QwenASREngine.ServerPaths {
        let root = URL(fileURLWithPath: "/tmp/qwen-tier-test", isDirectory: true)
        return QwenASREngine.ServerPaths(
            model: weights.url(for: weights.model, appSupport: root),
            projector: weights.url(for: weights.projector, appSupport: root))
    }

    func testConcurrentPrepareCoalescesByWeightsAndIsolatesFailures() async throws {
        let stockStarted = AsyncSignal()
        let releaseStock = AsyncSignal()
        let recorder = ServerRecorder()
        let runtime = QwenASREngine.TierRuntime<FakeManagedServer>(
            prepareFiles: { weights, _ in
                if weights == QwenLlamaASR.accuracy {
                    await stockStarted.signal()
                    await releaseStock.wait()
                    throw FakeRuntimeError.stockDownloadFailed
                }
                return Self.fakePaths(for: weights)
            },
            makeServer: { weights, _ in
                let server = FakeManagedServer(label: weights.model.name)
                Task { await recorder.record(server) }
                return server
            }
        )

        let stockTask = Task { try await runtime.prepare(weights: QwenLlamaASR.accuracy) }
        await stockStarted.wait()
        let v3Task = Task { try await runtime.prepare(weights: QwenLlamaASR.accuracyLokalBotV3) }
        await releaseStock.signal()

        let v3Outcome = try await v3Task.value
        XCTAssertEqual(v3Outcome, .ready)
        do {
            _ = try await stockTask.value
            XCTFail("Expected stock preparation to fail")
        } catch let error as FakeRuntimeError {
            XCTAssertEqual(error, .stockDownloadFailed)
        }

        let stockReady = AsyncSignal()
        let releaseStockStartup = AsyncSignal()
        let v3Started = AsyncSignal()
        let serializedRuntime = QwenASREngine.TierRuntime<FakeManagedServer>(
            prepareFiles: { weights, _ in Self.fakePaths(for: weights) },
            makeServer: { weights, _ in
                if weights == QwenLlamaASR.accuracy {
                    return FakeManagedServer(label: weights.model.name) { _ in
                        await stockReady.signal()
                        await releaseStockStartup.wait()
                    }
                }
                return FakeManagedServer(label: weights.model.name) { _ in
                    await v3Started.signal()
                }
            }
        )

        let firstStock = Task { try await serializedRuntime.prepare(weights: QwenLlamaASR.accuracy) }
        await stockReady.wait()
        let secondV3 = Task { try await serializedRuntime.prepare(weights: QwenLlamaASR.accuracyLokalBotV3) }
        await releaseStockStartup.signal()

        let firstOutcome = try await firstStock.value
        let secondOutcome = try await secondV3.value
        XCTAssertEqual(firstOutcome, .ready)
        XCTAssertEqual(secondOutcome, .ready)
        await v3Started.wait()
    }

    func testCanceledAcquireRemovesWaiterAndDoesNotStartServer() async throws {
        let v3Created = ServerRecorder()
        let runtime = QwenASREngine.TierRuntime<FakeManagedServer>(
            prepareFiles: { weights, _ in Self.fakePaths(for: weights) },
            makeServer: { weights, _ in
                let server = FakeManagedServer(label: weights.model.name)
                if weights == QwenLlamaASR.accuracyLokalBotV3 {
                    Task { await v3Created.record(server) }
                }
                return server
            }
        )

        let stockLease = try await runtime.acquireServer(weights: QwenLlamaASR.accuracy)
        let waitingV3 = Task {
            try await runtime.acquireServer(weights: QwenLlamaASR.accuracyLokalBotV3)
        }
        try await Task.sleep(for: .milliseconds(30))
        waitingV3.cancel()

        do {
            _ = try await waitingV3.value
            XCTFail("Expected canceled acquireServer to throw CancellationError")
        } catch is CancellationError {
        }

        await runtime.releaseServer(stockLease)
        try await Task.sleep(for: .milliseconds(30))
        let createdLabels = await v3Created.labels()
        XCTAssertTrue(createdLabels.isEmpty)
    }

    func testAcquireReservesServerGenerationAcrossStartupAndWakesOnFailure() async throws {
        let stockEnteredStartup = AsyncSignal()
        let releaseStockStartup = AsyncSignal()
        let stockServer = FakeManagedServer(label: "stock") { _ in
            await stockEnteredStartup.signal()
            await releaseStockStartup.wait()
        }
        let v3Server = FakeManagedServer(label: "v3")
        let runtime = QwenASREngine.TierRuntime<FakeManagedServer>(
            prepareFiles: { weights, _ in Self.fakePaths(for: weights) },
            makeServer: { weights, _ in
                weights == QwenLlamaASR.accuracy ? stockServer : v3Server
            }
        )

        let stockTask = Task { try await runtime.acquireServer(weights: QwenLlamaASR.accuracy) }
        await stockEnteredStartup.wait()

        let v3Task = Task { try await runtime.acquireServer(weights: QwenLlamaASR.accuracyLokalBotV3) }
        try await Task.sleep(for: .milliseconds(30))
        let v3StartsBeforeRelease = await v3Server.startedModels.count
        XCTAssertEqual(v3StartsBeforeRelease, 0)

        await releaseStockStartup.signal()
        let stockLease = try await stockTask.value
        XCTAssertTrue(stockLease.server === stockServer)

        let v3StartsWhileLeased = await v3Server.startedModels.count
        XCTAssertEqual(v3StartsWhileLeased, 0)

        await runtime.releaseServer(stockLease)
        let v3Lease = try await v3Task.value
        XCTAssertTrue(v3Lease.server === v3Server)
        let stockStopCount = await stockServer.stopCount
        XCTAssertEqual(stockStopCount, 1)
        await runtime.releaseServer(v3Lease)

        let failingEnteredStartup = AsyncSignal()
        let releaseFailingStartup = AsyncSignal()
        let failingStockServer = FakeManagedServer(label: "stock-fail") { _ in
            await failingEnteredStartup.signal()
            await releaseFailingStartup.wait()
            throw FakeRuntimeError.stockStartupFailed
        }
        let recoveryV3Server = FakeManagedServer(label: "v3-recover")
        let failureRuntime = QwenASREngine.TierRuntime<FakeManagedServer>(
            prepareFiles: { weights, _ in Self.fakePaths(for: weights) },
            makeServer: { weights, _ in
                weights == QwenLlamaASR.accuracy ? failingStockServer : recoveryV3Server
            }
        )

        let failingStock = Task { try await failureRuntime.acquireServer(weights: QwenLlamaASR.accuracy) }
        await failingEnteredStartup.wait()
        let waitingRecoveryV3 = Task { try await failureRuntime.acquireServer(weights: QwenLlamaASR.accuracyLokalBotV3) }
        try await Task.sleep(for: .milliseconds(30))
        await releaseFailingStartup.signal()

        do {
            _ = try await failingStock.value
            XCTFail("Expected failing stock startup to throw")
        } catch let error as FakeRuntimeError {
            XCTAssertEqual(error, .stockStartupFailed)
        }
        let recoveredLease = try await waitingRecoveryV3.value
        XCTAssertTrue(recoveredLease.server === recoveryV3Server)
        await failureRuntime.releaseServer(recoveredLease)
    }

    func testPrepareDefersReplacementWithoutReportingReady() async throws {
        let stockServer = FakeManagedServer(label: "stock")
        let v3Server = FakeManagedServer(label: "v3")
        let runtime = QwenASREngine.TierRuntime<FakeManagedServer>(
            prepareFiles: { weights, _ in Self.fakePaths(for: weights) },
            makeServer: { weights, _ in
                weights == QwenLlamaASR.accuracy ? stockServer : v3Server
            }
        )

        let stockLease = try await runtime.acquireServer(weights: QwenLlamaASR.accuracy)
        let statuses = await MainActor.run { StatusBox() }
        let outcome = try await runtime.prepare(weights: QwenLlamaASR.accuracyLokalBotV3) { update in
            statuses.append(update.status)
        }
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(outcome, .deferredUntilIdle)
        let reported = await MainActor.run { statuses.values }
        XCTAssertFalse(reported.contains("Ready"), "Deferred preparation should not report Ready: \(reported)")
        let v3Starts = await v3Server.startedModels.count
        XCTAssertEqual(v3Starts, 0)
        let stopCountBeforeRelease = await stockServer.stopCount
        XCTAssertEqual(stopCountBeforeRelease, 0)

        await runtime.releaseServer(stockLease)
        await stockServer.waitUntilStopped()
        let stopCountAfterRelease = await stockServer.stopCount
        XCTAssertEqual(stopCountAfterRelease, 1)
    }

    func testDeferredResetDoesNotStopServerWhileNextAcquisitionIsStarting() async throws {
        let secondStartEntered = AsyncSignal()
        let releaseSecondStart = AsyncSignal()
        let stockServer = FakeManagedServer(label: "stock")
        let v3Server = FakeManagedServer(label: "v3")
        let runtime = QwenASREngine.TierRuntime<FakeManagedServer>(
            prepareFiles: { weights, _ in Self.fakePaths(for: weights) },
            makeServer: { weights, _ in
                weights == QwenLlamaASR.accuracy ? stockServer : v3Server
            }
        )

        let firstLease = try await runtime.acquireServer(weights: QwenLlamaASR.accuracy)
        let deferredOutcome = try await runtime.prepare(weights: QwenLlamaASR.accuracyLokalBotV3)
        XCTAssertEqual(deferredOutcome, .deferredUntilIdle)

        await stockServer.setOnStart { _ in
            await secondStartEntered.signal()
            await releaseSecondStart.wait()
        }
        let secondAcquire = Task { try await runtime.acquireServer(weights: QwenLlamaASR.accuracy) }
        await secondStartEntered.wait()

        await runtime.releaseServer(firstLease)
        try await Task.sleep(for: .milliseconds(30))
        let stopCountWhileStarting = await stockServer.stopCount
        XCTAssertEqual(stopCountWhileStarting, 0)

        await releaseSecondStart.signal()
        let secondLease = try await secondAcquire.value
        XCTAssertTrue(secondLease.server === stockServer)

        await runtime.releaseServer(secondLease)
        await stockServer.waitUntilStopped()
        let finalStopCount = await stockServer.stopCount
        XCTAssertEqual(finalStopCount, 1)
    }

    @MainActor
    private final class StatusBox {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }
}
