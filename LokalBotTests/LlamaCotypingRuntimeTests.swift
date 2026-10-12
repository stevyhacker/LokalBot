import XCTest
@testable import LokalBot

final class LlamaCotypingRuntimeTests: XCTestCase {

    /// Resolves the compact fallback model from the local cache or
    /// `LOKALBOT_COTYPING_TEST_MODEL`, or skips. Never from the checkout:
    /// macOS asks each new test host for access to ~/Documents.
    private func bundledModelPath() throws -> String {
        let entry = ModelCatalog.entry(id: ModelCatalog.compactFallbackID)!
        let storage = StorageManager()
        guard let url = ModelCatalog.localURL(for: entry, storage: storage) else {
            guard let path = ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_TEST_MODEL"],
                  ModelFileValidator.looksLikeGGUF(URL(fileURLWithPath: path)) else {
                throw XCTSkip("Set LOKALBOT_COTYPING_TEST_MODEL to \(entry.fileName) to run this libllama integration test.")
            }
            return path
        }
        return url.path
    }

    private let standardSpecs = LlamaSamplerSpec.specs(from: .standard)

    /// A memory warning while suggestions are coming leaves the model loaded,
    /// so the next keystroke does not wait for a reload.
    func testAMemoryWarningFreesTheModelOnlyAfterAMinuteIdle() {
        XCTAssertTrue(LlamaCotypingRuntime.isIdle(lastUsedUptime: nil, now: 100))
        XCTAssertFalse(LlamaCotypingRuntime.isIdle(lastUsedUptime: 90, now: 100))
        XCTAssertTrue(LlamaCotypingRuntime.isIdle(lastUsedUptime: 30, now: 100))
    }

    func testArgmaxTokenChoosesLargestFiniteLogit() {
        let logits: [Float] = [-3.0, .nan, 0.4, 1.2, -0.1]
        let token = logits.withUnsafeBufferPointer { buffer in
            LlamaCotypingRuntime.argmaxToken(
                in: buffer.baseAddress,
                vocabularySize: Int32(buffer.count))
        }

        XCTAssertEqual(token, 3)
    }

    func testArgmaxTokenReturnsNilForInvalidLogits() {
        XCTAssertNil(LlamaCotypingRuntime.argmaxToken(in: nil, vocabularySize: 5))

        let logits: [Float] = [.nan, .nan]
        let token = logits.withUnsafeBufferPointer { buffer in
            LlamaCotypingRuntime.argmaxToken(
                in: buffer.baseAddress,
                vocabularySize: Int32(buffer.count))
        }

        XCTAssertNil(token)
    }

    func testLoadsAndGeneratesDeterministically() async throws {
        let path = try bundledModelPath()
        let runtime = LlamaCotypingRuntime()
        try await runtime.loadIfNeeded(modelPath: path)
        let loaded = await runtime.isLoaded
        XCTAssertTrue(loaded)

        let prompt = await runtime.tokenize("The capital of France is", addBOS: true)
        XCTAssertFalse(prompt.isEmpty)

        let first = try await runtime.generate(
            promptTokens: prompt, maxTokens: 8, samplerSpecs: standardSpecs) { _ in true }
        XCTAssertFalse(first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // Same prompt + fixed seed (0x00C0FFEE in standardSpecs) → identical output.
        try await runtime.loadIfNeeded(modelPath: path) // no-op reload
        let second = try await runtime.generate(
            promptTokens: prompt, maxTokens: 8, samplerSpecs: standardSpecs) { _ in true }
        XCTAssertEqual(first, second, "fixed seed must produce deterministic output")
    }

    func testMemoryPressureUnloadsWhenNotLoaded() async {
        let runtime = LlamaCotypingRuntime()
        let before = await runtime.isLoaded
        XCTAssertFalse(before)
        await runtime.handleMemoryPressure()   // safe no-op when nothing is loaded
        let after = await runtime.isLoaded
        XCTAssertFalse(after)
    }

    func testUnloadInvalidatesLoadSuspendedAfterResidencyAdmission() async {
        let admitted = AsyncGate()
        let resumeAdmission = AsyncGate()
        let runtime = LlamaCotypingRuntime(postLoadAdmissionHook: {
            await admitted.open()
            await resumeAdmission.wait()
        })
        let load = Task {
            try await runtime.loadIfNeeded(modelPath: "/model-that-must-not-load.gguf")
        }

        await admitted.wait()
        await runtime.unload()
        await resumeAdmission.open()

        do {
            try await load.value
            XCTFail("A load admitted before unload must not resume and install weights.")
        } catch is CancellationError {
            // Expected: the unload epoch invalidates the suspended load.
        } catch {
            XCTFail("Expected cancellation from the unload epoch, got \(error).")
        }
        let loaded = await runtime.isLoaded
        XCTAssertFalse(loaded, "unload must remain final after the stale load resumes")
    }

    func testReusedPrefixIsReflectedInPrefillTokenCount() async throws {
        // Validates the IncrementalPrefill reuse SIGNAL — the logical
        // `lastPrefillTokenCount` (prompt.count - sharedPrefix) — not the physical
        // reuse branch. The bundled CI model is hybrid SSM, so it always takes the
        // full-reprefill fallback; the arithmetic below holds on BOTH that fallback
        // and the production attention model's partial-reuse branch, so it cannot
        // observe physical suffix-only prefill on this fixture. The pure-attention
        // partial-reuse branch is exercised only on the production Gemma-4 model /
        // a manual run.
        let path = try bundledModelPath()
        let runtime = LlamaCotypingRuntime()
        try await runtime.loadIfNeeded(modelPath: path)

        let base = await runtime.tokenize("Hi Sarah, thanks for sending this over. I wanted to follow", addBOS: true)
        _ = try await runtime.generate(promptTokens: base, maxTokens: 2, samplerSpecs: standardSpecs) { _ in true }
        let firstPrefill = await runtime.lastPrefillTokenCount
        XCTAssertEqual(firstPrefill, base.count, "cold prompt prefills every token")

        // Extend the prompt: the reuse signal must subtract the shared prefix.
        let extended = base + (await runtime.tokenize(" up tomorrow", addBOS: false))
        _ = try await runtime.generate(promptTokens: extended, maxTokens: 2, samplerSpecs: standardSpecs) { _ in true }
        let secondPrefill = await runtime.lastPrefillTokenCount
        XCTAssertLessThan(secondPrefill, extended.count, "reuse signal must discount the shared prefix")
        XCTAssertEqual(secondPrefill, extended.count - base.count,
                       "logical prefill count should equal only the appended suffix")
    }

    func testFocusPrefillSkipsDecodeWhenPromptPrefixCannotBeReused() async throws {
        let path = try bundledModelPath()
        let runtime = LlamaCotypingRuntime()
        try await runtime.loadIfNeeded(modelPath: path)
        let canReusePromptPrefix = await runtime.canReusePromptPrefix
        guard !canReusePromptPrefix else {
            throw XCTSkip("Bundled model can reuse prompt prefixes; skip hybrid/recurrent prefill test.")
        }

        let prompt = await runtime.tokenize(
            "Hi Sarah, thanks for sending this over. I wanted to follow",
            addBOS: true)
        try await runtime.prefill(promptTokens: prompt)

        let skippedPrefillCount = await runtime.lastPrefillTokenCount
        XCTAssertEqual(skippedPrefillCount, 0)

        let extended = prompt + (await runtime.tokenize(" up tomorrow", addBOS: false))
        _ = try await runtime.generate(
            promptTokens: extended,
            maxTokens: 2,
            samplerSpecs: standardSpecs) { _ in true }

        let generatedPrefillCount = await runtime.lastPrefillTokenCount
        XCTAssertEqual(
            generatedPrefillCount,
            extended.count - prompt.count,
            "Skipped focus prefill should still seed the logical prefix baseline.")
    }

    func testGenerateHonorsTaskCancellationBeforePrefill() async throws {
        let path = try bundledModelPath()
        let runtime = LlamaCotypingRuntime()
        try await runtime.loadIfNeeded(modelPath: path)
        let prompt = await runtime.tokenize(
            "Hi Sarah, thanks for sending this over. I wanted to follow",
            addBOS: true)
        let gate = AsyncGate()

        let task = Task {
            await gate.wait()
            return try await runtime.generate(
                promptTokens: prompt,
                maxTokens: 8,
                samplerSpecs: standardSpecs) { _ in true }
        }
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Cancelled generation should throw before prompt prefill.")
        } catch is CancellationError {
            let prefilled = await runtime.lastPrefillTokenCount
            XCTAssertEqual(prefilled, 0)
        }
    }

    func testAbortSignalDoesNotPoisonNextGeneration() async throws {
        let path = try bundledModelPath()
        let runtime = LlamaCotypingRuntime()
        try await runtime.loadIfNeeded(modelPath: path)
        runtime.abortInFlightDecode()

        let prompt = await runtime.tokenize("The capital of Italy is", addBOS: true)
        let out = try await runtime.generate(
            promptTokens: prompt,
            maxTokens: 4,
            samplerSpecs: standardSpecs) { _ in true }

        XCTAssertFalse(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testOnTokenReturningFalseStopsDecode() async throws {
        let path = try bundledModelPath()
        let runtime = LlamaCotypingRuntime()
        try await runtime.loadIfNeeded(modelPath: path)
        let prompt = await runtime.tokenize("Once upon a time", addBOS: true)
        let counter = TokenCounter()
        let out = try await runtime.generate(
            promptTokens: prompt, maxTokens: 20, samplerSpecs: standardSpecs
        ) { _ in counter.increment() < 3 }   // stop after 3 tokens
        XCTAssertLessThanOrEqual(counter.value, 3)
        XCTAssertFalse(out.isEmpty)
    }
}

/// Thread-safe counter so the `@Sendable` onToken closure can tally tokens
/// without tripping Swift's concurrent-capture diagnostics.
private final class TokenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// Increments and returns the new count (so the first call returns 1).
    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}
