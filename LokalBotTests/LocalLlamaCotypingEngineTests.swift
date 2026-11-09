import XCTest
@testable import LokalBot

@MainActor
final class LocalLlamaCotypingEngineTests: XCTestCase {
    /// The compact fallback model from the local cache or
    /// `LOKALBOT_COTYPING_TEST_MODEL`, never the checkout (see
    /// `LlamaCotypingRuntimeTests`).
    private func bundledModelPath() throws -> String {
        let entry = ModelCatalog.entry(id: ModelCatalog.compactFallbackID)!
        guard let url = ModelCatalog.localURL(for: entry, storage: StorageManager()) else {
            guard let path = ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_TEST_MODEL"],
                  ModelFileValidator.looksLikeGGUF(URL(fileURLWithPath: path)) else {
                throw XCTSkip("Set LOKALBOT_COTYPING_TEST_MODEL to \(entry.fileName) to run this engine integration test.")
            }
            return path
        }
        return url.path
    }

    private func makeRequest() -> CotypingRequest {
        let field = CotypingField(
            appName: "Mail", bundleID: "com.apple.mail", processID: 0, role: "AXTextArea",
            precedingText: "Hi Sarah,\nThanks for sending this over. I wanted to follow",
            trailingText: "", selectionLength: 0, caretRect: .zero, isSecure: false,
            caretIsExact: true, windowTitle: "Re: Q3", fieldPlaceholder: nil)
        return CotypingRequestBuilder.build(
            field: field, config: .standard,
            personalization: .none, generation: 1, learnedExamples: [])!
    }

    func testGenerateReturnsNormalizedResult() async throws {
        let path = try bundledModelPath()
        let engine = LocalLlamaCotypingEngine(runtime: LlamaCotypingRuntime(), modelPath: path)
        let result = try await engine.generate(makeRequest())
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testStreamingFiresPartials() async throws {
        let path = try bundledModelPath()
        let engine = LocalLlamaCotypingEngine(runtime: LlamaCotypingRuntime(), modelPath: path)
        let partials = PartialCounter()
        _ = try await engine.generateStreaming(makeRequest()) { _ in partials.increment() }
        XCTAssertGreaterThan(partials.value, 0)
    }

    /// `unload()` is callable on the engine seam and is a safe no-op when nothing
    /// is loaded (mirrors LlamaCotypingRuntimeTests.testMemoryPressureUnloadsWhenNotLoaded).
    /// No GGUF needed: the runtime is never loaded, so unload just confirms the
    /// route-away teardown path the selector uses can't crash on an idle engine.
    func testUnloadIsCallableAndLeavesUnloadedRuntimeUnloaded() async {
        let runtime = LlamaCotypingRuntime()
        let engine = LocalLlamaCotypingEngine(runtime: runtime, modelPath: "/nonexistent.gguf")
        let before = await runtime.isLoaded
        XCTAssertFalse(before)
        await engine.unload()
        let after = await runtime.isLoaded
        XCTAssertFalse(after)
    }
}

private final class PartialCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
