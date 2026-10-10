import XCTest
@testable import LokalBot

@MainActor
final class CotypingEngineSelectorTests: XCTestCase {
    private let modelURL = URL(fileURLWithPath: "/models/gemma.gguf")

    func testHybridSwitchRebuildsSameModelAndRestoresCurrentDecoder() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon)
        let env = try GGUFFixture()
        defer { env.tearDown() }
        var settings = env.settings
        var modes: [Bool] = []
        var locals: [RecordingLocalEngine] = []
        let selector = CotypingEngineSelector(
            http: RecordingHTTPEngine(),
            makeLocal: { _, hybrid in
                if let previous = locals.last { XCTAssertEqual(previous.unloadCalls, 1) }
                modes.append(hybrid)
                let engine = RecordingLocalEngine()
                locals.append(engine)
                return engine
            }, settings: { settings }, storage: env.storage,
            verifyModel: { _, _ in self.modelURL })
        for hybrid in [false, true, false] {
            settings.cotypingSelectiveOneWordHybrid = hybrid
            _ = try awaitGenerate(selector, makeMinimalRequestExpectingNoServer())
            _ = try awaitGenerate(selector, makeMinimalRequestExpectingNoServer())
        }
        XCTAssertEqual(modes, [false, true, false], "reuse only within the same mode")
        awaitUnload(selector)
    }

    func testHybridSwitchInvalidatesSuspendedModelResolution() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon)
        let env = try GGUFFixture()
        defer { env.tearDown() }
        var settings = env.settings
        let entered = expectation(description: "verification suspended")
        let verifier = SuspendedModelVerifier { entered.fulfill() }
        let http = RecordingHTTPEngine()
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { _, _ in XCTFail("stale mode must not be installed"); return RecordingLocalEngine() },
            settings: { settings }, storage: env.storage,
            verifyModel: { _, _ in await verifier.verify() })
        let finished = expectation(description: "old request cancelled")
        var failure: Error?
        Task { @MainActor in
            do { _ = try await selector.generate(makeMinimalRequestExpectingNoServer()) } catch { failure = error }
            finished.fulfill()
        }
        wait(for: [entered], timeout: 5)
        settings.cotypingSelectiveOneWordHybrid = true
        verifier.resumeAll(with: modelURL)
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(failure is CancellationError)
        XCTAssertEqual(http.generateCalls, 0)
    }

    func testUsesLocalWhenFlagOnAppleSiliconAndModelResolves() {
        var s = AppSettings(); s.cotypingInProcessRuntime = true
        XCTAssertTrue(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: modelURL, isAppleSilicon: true))
    }

    func testFallsBackWhenFlagOff() {
        var s = AppSettings(); s.cotypingInProcessRuntime = false
        XCTAssertFalse(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: modelURL, isAppleSilicon: true))
    }

    func testFallsBackOnIntel() {
        var s = AppSettings(); s.cotypingInProcessRuntime = true
        XCTAssertFalse(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: modelURL, isAppleSilicon: false))
    }

    func testFallsBackWhenModelMissing() {
        var s = AppSettings(); s.cotypingInProcessRuntime = true
        XCTAssertFalse(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: nil, isAppleSilicon: true))
    }

    // MARK: - Route-away unload (Fix 1) + decode-failure fallback (Fix 2)

    /// FIX 1: when the runtime flag flips OFF the selector must drop its cached
    /// in-process engine (and unload its model); flipping it back ON rebuilds a
    /// fresh engine. We prove the cache is dropped by counting `makeLocal` calls
    /// through the injectable seam: build → drop → rebuild ⇒ exactly two builds.
    ///
    /// These selector paths only run on Apple Silicon (`isAppleSilicon`), so the
    /// test is skipped on Intel where `localIfEligible()` always returns nil.
    func testRouteAwayDropsCacheAndRebuildOnReenable() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon,
                          "Selector routes to local only on Apple Silicon.")
        let env = try GGUFFixture()
        defer { env.tearDown() }

        var flagOn = true
        var events: [String] = []
        let http = RecordingHTTPEngine()
        http.onGenerate = { events.append("http") }
        let counter = BuildCounter()
        var locals: [RecordingLocalEngine] = []
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { _, _ in
                counter.bump()
                let engine = RecordingLocalEngine()
                engine.delayUnload = true
                engine.onUnload = { events.append("local-unload") }
                locals.append(engine)
                return engine
            },
            settings: {
                var s = env.settings
                s.cotypingInProcessRuntime = flagOn
                return s
            },
            storage: env.storage)

        // Flag ON + model resolves → first build, routes local (HTTP untouched).
        let r1 = makeMinimalRequestExpectingNoServer()
        _ = try? awaitGenerate(selector, r1)
        XCTAssertEqual(counter.value, 1, "flag ON should build the local engine once")
        XCTAssertEqual(selector.debounceProfile, .inProcess)

        // Flag OFF → ineligible branch calls dropLocalEngine(), routes to HTTP.
        flagOn = false
        events.removeAll()
        let httpBefore = http.generateCalls
        _ = try? awaitGenerate(selector, r1)
        XCTAssertEqual(http.generateCalls, httpBefore + 1, "flag OFF should route to HTTP")
        XCTAssertEqual(counter.value, 1, "flag OFF must not build a new local engine")
        XCTAssertEqual(locals[0].unloadCalls, 1,
                       "routing away must explicitly unload the local model")
        XCTAssertEqual(events, ["local-unload", "http"],
                       "the old local model must finish unloading before HTTP starts")
        XCTAssertEqual(selector.debounceProfile, .modelServer)

        // Flag ON again → cache was dropped, so a FRESH engine is rebuilt.
        flagOn = true
        _ = try? awaitGenerate(selector, r1)
        XCTAssertEqual(counter.value, 2,
                       "re-enabling after route-away must rebuild a fresh local engine")
        XCTAssertEqual(selector.debounceProfile, .inProcess)
    }

    func testConcurrentRouteAwayCoalescesLocalUnloadBeforeHTTP() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon,
                          "Selector routes to local only on Apple Silicon.")
        let env = try GGUFFixture()
        defer { env.tearDown() }

        var flagOn = true
        var events: [String] = []
        let http = RecordingHTTPEngine()
        http.onGenerate = { events.append("http") }
        let local = RecordingLocalEngine()
        local.delayUnload = true
        local.onUnload = { events.append("local-unload") }
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { _, _ in local },
            settings: {
                var settings = env.settings
                settings.cotypingInProcessRuntime = flagOn
                return settings
            },
            storage: env.storage)
        let request = makeMinimalRequestExpectingNoServer()
        _ = try awaitGenerate(selector, request)

        flagOn = false
        events.removeAll()
        let completions = expectation(description: "route-away completions")
        completions.expectedFulfillmentCount = 2
        Task { @MainActor in
            _ = try? await selector.generate(request)
            completions.fulfill()
        }
        Task { @MainActor in
            _ = try? await selector.generate(request)
            completions.fulfill()
        }
        wait(for: [completions], timeout: 5)

        XCTAssertEqual(local.unloadCalls, 1,
                       "re-entrant route changes must share one local teardown")
        XCTAssertEqual(events, ["local-unload", "http"],
                       "HTTP must not start until the shared local unload finishes")
        XCTAssertEqual(selector.debounceProfile, .modelServer)
    }

    /// Changing the selected GGUF used to overwrite the cached local engine
    /// without unloading it. Prove replacement is ordered: old local unload,
    /// stale HTTP stop, then the new local generation.
    func testModelChangeUnloadsOldLocalBeforeBuildingReplacement() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon,
                          "Selector routes to local only on Apple Silicon.")
        let env = try GGUFFixture()
        defer { env.tearDown() }

        let first = ModelCatalog.Entry(
            id: "first", displayName: "First", fileName: "first.gguf",
            url: "", sizeGB: 0, blurb: "", disablesThinking: false)
        let second = ModelCatalog.Entry(
            id: "second", displayName: "Second", fileName: "second.gguf",
            url: "", sizeGB: 0, blurb: "", disablesThinking: false)
        var selectedID = first.id
        var currentSettings: AppSettings {
            var settings = AppSettings()
            settings.cotypingInProcessRuntime = true
            settings.customBuiltInModels = [first, second]
            settings.cotypingBuiltInModelID = selectedID
            return settings
        }

        var events: [String] = []
        let http = RecordingHTTPEngine()
        http.onUnload = { events.append("http-unload") }
        var locals: [RecordingLocalEngine] = []
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { path, _ in
                let engine = RecordingLocalEngine()
                engine.onGenerate = { events.append("generate:\(path)") }
                engine.onUnload = { events.append("local-unload") }
                locals.append(engine)
                return engine
            },
            settings: { currentSettings },
            storage: env.storage,
            verifyModel: { entry, _ in URL(fileURLWithPath: "/models/\(entry.fileName)") })

        let request = makeMinimalRequestExpectingNoServer()
        _ = try awaitGenerate(selector, request)
        XCTAssertEqual(locals.count, 1)

        events.removeAll()
        selectedID = second.id
        _ = try awaitGenerate(selector, request)

        XCTAssertEqual(locals.count, 2)
        XCTAssertEqual(locals[0].unloadCalls, 1,
                       "the old model must not remain resident after replacement")
        XCTAssertEqual(events, [
            "local-unload",
            "http-unload",
            "generate:/models/second.gguf",
        ])
    }

    /// FIX 2 (selector half): a `LlamaRuntimeError` thrown by the local engine must
    /// reach the selector's `catch let error as LlamaRuntimeError` and route the
    /// completion to HTTP. This injects a `ThrowingLocalEngine` fake (enabled by the
    /// `CotypingCompleting` seam on `makeLocal`), so it proves the selector's
    /// fallback wiring — NOT that `LlamaCotypingRuntime.generate` actually throws on
    /// a failed `llama_decode`. That runtime half is locked by compilation (the
    /// `try await` propagation in `LlamaCotypingRuntimeTests`); a genuine
    /// `llama_decode == 0` fault (KV exhaustion / OOM) can't be provoked
    /// deterministically in a unit test.
    func testLocalRuntimeErrorRoutesToHTTPFallback() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon,
                          "Selector routes to local only on Apple Silicon.")
        let env = try GGUFFixture()
        defer { env.tearDown() }

        let http = RecordingHTTPEngine()
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { _, _ in ThrowingLocalEngine(error: .decodeFailed) },
            settings: { env.settings },
            storage: env.storage)

        let result = try awaitGenerate(selector, makeMinimalRequestExpectingNoServer())
        XCTAssertEqual(http.generateCalls, 1,
                       "a thrown LlamaRuntimeError must route the completion to HTTP")
        XCTAssertEqual(result.text, RecordingHTTPEngine.sentinel,
                       "the returned result must be the HTTP engine's output")
        XCTAssertEqual(selector.debounceProfile, .modelServer,
                       "a local failure must immediately restore server debounce")
    }

    /// The HTTP fallback runs the SAME GGUF in its own llama-server process, so
    /// a failed in-process engine must not stay loaded beside it (two model
    /// copies resident). A failure must (1) unload the local engine's weights
    /// BEFORE the HTTP fallback starts (the failure is likely memory pressure,
    /// so the copies must never overlap), (2) route to HTTP without rebuilding
    /// local for `localRetryCooldown`, and (3) rebuild + retry local once the
    /// cooldown passes.
    func testLocalFailureFreesModelAndCoolsDownBeforeRetry() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon,
                          "Selector routes to local only on Apple Silicon.")
        let env = try GGUFFixture()
        defer { env.tearDown() }

        var clock = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var events: [String] = []
        let http = RecordingHTTPEngine()
        http.onGenerate = { events.append("http") }
        var locals: [ThrowingLocalEngine] = []
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { _, _ in
                let engine = ThrowingLocalEngine(error: .decodeFailed)
                engine.onUnload = { events.append("unload") }
                locals.append(engine)
                return engine
            },
            settings: { env.settings },
            storage: env.storage,
            now: { clock })

        let request = makeMinimalRequestExpectingNoServer()

        // Failure → HTTP fallback + the failed engine's weights are freed.
        _ = try awaitGenerate(selector, request)
        XCTAssertEqual(locals.count, 1)
        XCTAssertEqual(http.generateCalls, 1, "the failed completion must land on HTTP")
        XCTAssertEqual(locals[0].unloadCalls, 1,
                       "a local failure must unload the in-process weights, not keep them resident")
        XCTAssertEqual(events, ["unload", "http"],
                       "the local weights must be freed before the HTTP fallback starts")

        // Inside the cooldown: straight to HTTP, no local rebuild (no reload thrash).
        clock += CotypingEngineSelector.localRetryCooldown - 1
        _ = try awaitGenerate(selector, request)
        XCTAssertEqual(locals.count, 1, "no rebuild while the failure cooldown is active")
        XCTAssertEqual(http.generateCalls, 2)

        // Past the cooldown: rebuild a fresh local engine and retry it.
        clock += 2
        _ = try awaitGenerate(selector, request)
        XCTAssertEqual(locals.count, 2, "cooldown expiry must rebuild and retry the local engine")
        XCTAssertEqual(http.generateCalls, 3, "the retried engine failed again, so HTTP serves it")
    }

    func testExplicitUnloadAwaitsLocalEngineAndRebuilds() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon,
                          "Selector routes to local only on Apple Silicon.")
        let env = try GGUFFixture()
        defer { env.tearDown() }

        let http = RecordingHTTPEngine()
        var locals: [RecordingLocalEngine] = []
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { _, _ in
                let engine = RecordingLocalEngine()
                locals.append(engine)
                return engine
            },
            settings: { env.settings },
            storage: env.storage)

        let request = makeMinimalRequestExpectingNoServer()
        _ = try awaitGenerate(selector, request)
        XCTAssertEqual(locals.count, 1, "first eligible completion should build one local engine")

        awaitUnload(selector)
        XCTAssertEqual(locals[0].unloadCalls, 1, "explicit unload must await the local engine unload")
        XCTAssertEqual(http.unloadCalls, 2,
                       "explicit unload must also stop the dedicated HTTP runtime")
        XCTAssertEqual(selector.debounceProfile, .modelServer)

        _ = try awaitGenerate(selector, request)
        XCTAssertEqual(locals.count, 2, "next eligible completion should rebuild after explicit unload")
    }

    /// Model verification suspends outside the main actor. An older generate
    /// and prewarm must not resume after an explicit unload and resurrect the
    /// in-process runtime that shutdown just released.
    func testExplicitUnloadInvalidatesSuspendedLocalResolution() throws {
        try XCTSkipUnless(CotypingEngineSelector.isAppleSilicon,
                          "Selector routes to local only on Apple Silicon.")
        let env = try GGUFFixture()
        defer { env.tearDown() }

        let verificationEntered = expectation(description: "verification suspended")
        verificationEntered.expectedFulfillmentCount = 2
        let verifier = SuspendedModelVerifier {
            verificationEntered.fulfill()
        }
        let http = RecordingHTTPEngine()
        var locals: [RecordingLocalEngine] = []
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { _, _ in
                let engine = RecordingLocalEngine()
                locals.append(engine)
                return engine
            },
            settings: { env.settings },
            storage: env.storage,
            verifyModel: { _, _ in await verifier.verify() })

        let request = makeMinimalRequestExpectingNoServer()
        let generateFinished = expectation(description: "generate cancelled")
        let prewarmFinished = expectation(description: "prewarm abandoned")
        var generateError: Error?
        Task { @MainActor in
            do {
                _ = try await selector.generate(request)
            } catch {
                generateError = error
            }
            generateFinished.fulfill()
        }
        Task { @MainActor in
            await selector.prewarm()
            prewarmFinished.fulfill()
        }

        wait(for: [verificationEntered], timeout: 5)
        awaitUnload(selector)
        verifier.resumeAll(with: URL(fileURLWithPath: "/models/suspended.gguf"))
        wait(for: [generateFinished, prewarmFinished], timeout: 5)

        XCTAssertTrue(generateError is CancellationError,
                      "the stale generation should terminate instead of falling through to HTTP")
        XCTAssertTrue(locals.isEmpty,
                      "a suspended lookup must not install local after explicit unload")
        XCTAssertEqual(http.generateCalls, 0,
                       "invalidated work must not restart the HTTP runtime after unload either")
        XCTAssertEqual(http.unloadCalls, 1)
        XCTAssertEqual(selector.debounceProfile, .modelServer)
    }

    func testExplicitUnloadStopsHTTPRuntimeWithoutLocalEngine() {
        var settings = AppSettings()
        settings.cotypingInProcessRuntime = false
        let http = RecordingHTTPEngine()
        let selector = CotypingEngineSelector(
            http: http,
            makeLocal: { _, _ in XCTFail("local engine should not be built"); return RecordingLocalEngine() },
            settings: { settings },
            storage: StorageManager())

        awaitUnload(selector)

        XCTAssertEqual(http.unloadCalls, 1,
                       "disable must stop HTTP even when no local engine was cached")
    }

    func testHTTPEngineUnloadAwaitsRuntimeStopHook() {
        var stopped = false
        let engine = CotypingEngine(
            makeEngine: { throw TextEngineError.unavailable("not used") },
            stopRuntime: {
                try? await Task.sleep(for: .milliseconds(25))
                stopped = true
            })

        awaitUnload(engine)

        XCTAssertTrue(stopped, "HTTP engine unload must await its dedicated server stop")
    }

    func testPlainCompletingEngineDefaultsToModelServerDebounce() {
        XCTAssertEqual(RecordingHTTPEngine().debounceProfile, .modelServer)
    }

    // MARK: - Helpers

    /// Builds a temp StorageManager rooted at a throwaway dir with a GGUF-magic
    /// file and a matching custom catalog entry, so `resolvedModelURL` resolves
    /// without a real multi-gigabyte model. `looksLikeGGUF` only checks the first 4
    /// bytes are the ASCII magic "GGUF".
    private struct GGUFFixture {
        let storage: StorageManager
        let settings: AppSettings
        private let tempRoot: URL
        private let previousDefault: String?

        init() throws {
            tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("lokalbot-selector-\(UUID().uuidString)", isDirectory: true)
            let modelsDir = tempRoot.appendingPathComponent("models", isDirectory: true)
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

            let fileName = "selector-fixture.gguf"
            let modelFile = modelsDir.appendingPathComponent(fileName)
            try Data("GGUF".utf8).write(to: modelFile)   // magic-only stub; not loaded

            // Point StorageManager at the temp root via the UI-test override hook.
            previousDefault = UserDefaults.standard.string(forKey: UITestRuntime.storageRootKey)
            UserDefaults.standard.set(tempRoot.path, forKey: UITestRuntime.storageRootKey)
            storage = StorageManager()

            let custom = ModelCatalog.Entry(
                id: "selector-fixture", displayName: "Selector Fixture",
                fileName: fileName, url: "", sizeGB: 0, blurb: "", disablesThinking: false)
            var s = AppSettings()
            s.cotypingInProcessRuntime = true
            s.customBuiltInModels = [custom]
            s.cotypingBuiltInModelID = custom.id
            settings = s
        }

        func tearDown() {
            if let previousDefault {
                UserDefaults.standard.set(previousDefault, forKey: UITestRuntime.storageRootKey)
            } else {
                UserDefaults.standard.removeObject(forKey: UITestRuntime.storageRootKey)
            }
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    /// A request whose generation never reaches a real server: the fakes above
    /// short-circuit before any network/model call, so the prompt content is
    /// irrelevant — we only need a valid `CotypingRequest`.
    private func makeMinimalRequestExpectingNoServer() -> CotypingRequest {
        let field = CotypingField(
            appName: "Mail", bundleID: "com.apple.mail", processID: 0, role: "AXTextArea",
            precedingText: "Hi Sarah,\nThanks for sending this over. I wanted to follow",
            trailingText: "", selectionLength: 0, caretRect: .zero, isSecure: false,
            caretIsExact: true, windowTitle: "Re: Q3", fieldPlaceholder: nil)
        return CotypingRequestBuilder.build(
            field: field, config: .standard,
            personalization: .none, generation: 1, learnedExamples: [])!
    }

    private func awaitGenerate(
        _ selector: CotypingEngineSelector, _ request: CotypingRequest
    ) throws -> CotypingNormalizationResult {
        let exp = expectation(description: "generate")
        var captured: Result<CotypingNormalizationResult, Error>!
        Task { @MainActor in
            do { captured = .success(try await selector.generate(request)) } catch { captured = .failure(error) }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        return try captured.get()
    }

    private func awaitUnload(_ engine: CotypingCompleting) {
        let exp = expectation(description: "unload")
        Task { @MainActor in
            await engine.unload()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }
}

/// Thread-safe build counter for the `makeLocal` seam.
private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
private final class SuspendedModelVerifier {
    private let onSuspend: () -> Void
    private var continuations: [CheckedContinuation<URL?, Never>] = []

    init(onSuspend: @escaping () -> Void) {
        self.onSuspend = onSuspend
    }

    func verify() async -> URL? {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            onSuspend()
        }
    }

    func resumeAll(with url: URL?) {
        let suspended = continuations
        continuations.removeAll()
        suspended.forEach { $0.resume(returning: url) }
    }
}

/// Stands in for the HTTP `CotypingCompleting` and records that it was invoked,
/// returning a sentinel result so the caller can assert the fallback path ran.
@MainActor
private final class RecordingHTTPEngine: CotypingCompleting {
    static let sentinel = "HTTP-FALLBACK"
    private(set) var generateCalls = 0
    private(set) var unloadCalls = 0
    var onGenerate: (() -> Void)?
    var onUnload: (() -> Void)?
    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        generateCalls += 1
        onGenerate?()
        return CotypingNormalizationResult(text: Self.sentinel, suppression: nil)
    }
    func unload() async {
        unloadCalls += 1
        onUnload?()
    }
}

@MainActor
private final class RecordingLocalEngine: CotypingCompleting {
    private(set) var generateCalls = 0
    private(set) var unloadCalls = 0
    var delayUnload = false
    var onGenerate: (() -> Void)?
    var onUnload: (() -> Void)?

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        generateCalls += 1
        onGenerate?()
        return CotypingNormalizationResult(text: "LOCAL", suppression: nil)
    }

    func unload() async {
        if delayUnload {
            try? await Task.sleep(for: .milliseconds(25))
        }
        unloadCalls += 1
        onUnload?()
    }
}

/// A local-engine fake that always throws a `LlamaRuntimeError`, used to prove
/// the selector's HTTP fallback fires on a decode failure (Fix 2). Records
/// unloads so tests can assert the failed engine's weights were freed.
@MainActor
private final class ThrowingLocalEngine: CotypingCompleting {
    let error: LlamaRuntimeError
    private(set) var unloadCalls = 0
    var onUnload: (() -> Void)?
    init(error: LlamaRuntimeError) { self.error = error }
    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        throw error
    }
    func unload() async {
        unloadCalls += 1
        onUnload?()
    }
}
