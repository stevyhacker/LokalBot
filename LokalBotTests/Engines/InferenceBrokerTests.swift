import XCTest
@testable import LokalBot

@MainActor
final class InferenceBrokerTests: XCTestCase {

    private actor HookRecorder {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
        func count(of event: String) -> Int { events.filter { $0 == event }.count }
    }

    @MainActor
    private final class SinkRecorder {
        private(set) var pinnedHistory: [Set<String>] = []
        private(set) var descriptionsHistory: [[String: [String]]] = []
        func record(pinned: Set<String>, descriptions: [String: [String]]) {
            pinnedHistory.append(pinned)
            descriptionsHistory.append(descriptions)
        }
        var lastPinned: Set<String> { pinnedHistory.last ?? [] }
        var lastDescriptions: [String: [String]] { descriptionsHistory.last ?? [:] }
    }

    private struct TestFailure: Error {}

    private actor EnsureGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private let modelURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("broker-test-fake.gguf")

    private func makeBroker(recorder: HookRecorder, sink: SinkRecorder,
                            linger: TimeInterval = 0.05,
                            failingRoles: Set<InferenceRole> = []) -> InferenceBroker {
        var hooks: [InferenceRole: InferenceBroker.RuntimeHooks] = [:]
        for role in InferenceRole.allCases {
            hooks[role] = InferenceBroker.RuntimeHooks(
                ensure: { _ in
                    if failingRoles.contains(role) { throw TestFailure() }
                    await recorder.record("ensure:\(role.rawValue)")
                },
                stop: { await recorder.record("stop:\(role.rawValue)") })
        }
        return InferenceBroker(
            hooks: hooks,
            lingerSeconds: Dictionary(uniqueKeysWithValues:
                InferenceRole.allCases.map { ($0, linger) }),
            leaseStateSink: { pinned, descriptions in
                sink.record(pinned: pinned, descriptions: descriptions)
            })
    }

    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    func testLeaseBootsRuntimePinsAndCounts() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink)

        let lease = try await broker.lease(.mainLLM, model: modelURL,
                                           priority: .interactive, purpose: "chat")

        let ensures = await recorder.count(of: "ensure:mainLLM")
        XCTAssertEqual(ensures, 1)
        XCTAssertEqual(sink.lastPinned, ["llama-server:main"])
        XCTAssertEqual(sink.lastDescriptions["llama-server:main"], ["chat (interactive)"])
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 1)
        await broker.release(lease)
    }

    func testReleaseUnpinsImmediatelyThenStopsAfterLinger() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink, linger: 0.05)

        let lease = try await broker.lease(.mainLLM, model: modelURL,
                                           priority: .background, purpose: "summary")
        await broker.release(lease)

        XCTAssertEqual(sink.lastPinned, [])
        let stoppedBeforeLinger = await recorder.count(of: "stop:mainLLM")
        XCTAssertEqual(stoppedBeforeLinger, 0)
        let stopped = await waitUntil { await recorder.count(of: "stop:mainLLM") == 1 }
        XCTAssertTrue(stopped)
    }

    func testNewLeaseCancelsPendingLinger() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink, linger: 0.2)

        let first = try await broker.lease(.mainLLM, model: modelURL,
                                           priority: .background, purpose: "summary")
        await broker.release(first)
        let second = try await broker.lease(.mainLLM, model: modelURL,
                                            priority: .interactive, purpose: "chat")

        try await Task.sleep(nanoseconds: 500_000_000)
        let stops = await recorder.count(of: "stop:mainLLM")
        XCTAssertEqual(stops, 0)
        await broker.release(second)
    }

    func testEnsureFailureLeavesNoLeaseOrPin() async {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink,
                                failingRoles: [.mainLLM])

        do {
            _ = try await broker.lease(.mainLLM, model: modelURL,
                                       priority: .interactive, purpose: "chat")
            XCTFail("expected the ensure failure to propagate")
        } catch {
            XCTAssertTrue(error is TestFailure)
        }
        XCTAssertEqual(sink.lastPinned, [])
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 0)
    }

    func testCancellationAfterEnsureSchedulesIdleStop() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let gate = EnsureGate()
        var hooks: [InferenceRole: InferenceBroker.RuntimeHooks] = [:]
        for role in InferenceRole.allCases {
            hooks[role] = InferenceBroker.RuntimeHooks(
                ensure: { _ in
                    await recorder.record("ensure:\(role.rawValue)")
                    if role == .mainLLM { await gate.wait() }
                },
                stop: { await recorder.record("stop:\(role.rawValue)") })
        }
        let broker = InferenceBroker(
            hooks: hooks,
            lingerSeconds: [.mainLLM: 0.01],
            leaseStateSink: { pinned, descriptions in
                sink.record(pinned: pinned, descriptions: descriptions)
            })

        let acquiring = Task {
            try await broker.lease(
                .mainLLM, model: modelURL, priority: .interactive, purpose: "cancelled")
        }
        await gate.waitUntilStarted()
        acquiring.cancel()
        await gate.release()
        do {
            _ = try await acquiring.value
            XCTFail("expected cancellation after ensure returned")
        } catch is CancellationError {
            // expected
        }

        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 0)
        XCTAssertEqual(sink.lastPinned, [])
        let stopped = await waitUntil {
            await recorder.count(of: "stop:mainLLM") == 1
        }
        XCTAssertTrue(stopped)
    }

    func testWithLeaseReleasesOnSuccessAndOnThrow() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink)

        let value = try await broker.withLease(.embedder, model: modelURL,
                                               priority: .background,
                                               purpose: "embeddings") { 42 }
        XCTAssertEqual(value, 42)
        var active = await broker.activeLeaseCount(.embedder)
        XCTAssertEqual(active, 0)

        do {
            _ = try await broker.withLease(.embedder, model: modelURL,
                                           priority: .background,
                                           purpose: "embeddings") { () async throws -> Int in
                throw TestFailure()
            }
            XCTFail("expected the body error to propagate")
        } catch {
            XCTAssertTrue(error is TestFailure)
        }
        active = await broker.activeLeaseCount(.embedder)
        XCTAssertEqual(active, 0)
        XCTAssertEqual(sink.lastPinned, [])
    }

    func testTTLLeaseExpiresOnItsOwn() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink, linger: 0.05)

        _ = try await broker.lease(.mainLLM, model: modelURL, priority: .agent,
                                   purpose: "ask_library", expiresAfter: 0.05)

        let released = await waitUntil { await broker.activeLeaseCount(.mainLLM) == 0 }
        XCTAssertTrue(released)
        let stopped = await waitUntil { await recorder.count(of: "stop:mainLLM") == 1 }
        XCTAssertTrue(stopped)
    }

    func testSecondLeaseOnSameRoleKeepsRuntimeAlive() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink, linger: 0.05)

        let chat = try await broker.lease(.mainLLM, model: modelURL,
                                          priority: .interactive, purpose: "chat")
        let summary = try await broker.lease(.mainLLM, model: modelURL,
                                             priority: .background, purpose: "summary")
        XCTAssertEqual(sink.lastDescriptions["llama-server:main"],
                       ["chat (interactive)", "summary (background)"])

        await broker.release(chat)
        try await Task.sleep(nanoseconds: 300_000_000)
        let stopsWhileHeld = await recorder.count(of: "stop:mainLLM")
        XCTAssertEqual(stopsWhileHeld, 0)
        XCTAssertEqual(sink.lastPinned, ["llama-server:main"])

        await broker.release(summary)
        let stopped = await waitUntil { await recorder.count(of: "stop:mainLLM") == 1 }
        XCTAssertTrue(stopped)
    }

    func testConflictingModelWaitsUntilExistingLeaseReleases() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink)
        let firstURL = modelURL.appendingPathExtension("first")
        let secondURL = modelURL.appendingPathExtension("second")
        let first = try await broker.lease(
            .mainLLM, model: firstURL, priority: .background, purpose: "first")

        let waiting = Task {
            try await broker.lease(
                .mainLLM, model: secondURL, priority: .interactive, purpose: "second")
        }
        try await Task.sleep(for: .milliseconds(100))
        let ensuresBeforeRelease = await recorder.count(of: "ensure:mainLLM")
        let pathBeforeRelease = await broker.activeModelPath(.mainLLM)
        XCTAssertEqual(ensuresBeforeRelease, 1)
        XCTAssertEqual(pathBeforeRelease,
                       firstURL.standardizedFileURL.resolvingSymlinksInPath().path)

        await broker.release(first)
        let second = try await waiting.value
        let ensuresAfterRelease = await recorder.count(of: "ensure:mainLLM")
        XCTAssertEqual(ensuresAfterRelease, 2)
        XCTAssertEqual(second.modelPath,
                       secondURL.standardizedFileURL.resolvingSymlinksInPath().path)
        await broker.release(second)
    }

    func testCancellingConflictingWaiterDoesNotAcquireOrLeak() async throws {
        let recorder = HookRecorder()
        let sink = SinkRecorder()
        let broker = makeBroker(recorder: recorder, sink: sink)
        let first = try await broker.lease(
            .mainLLM, model: modelURL, priority: .background, purpose: "first")
        let waiting = Task {
            try await broker.lease(
                .mainLLM, model: modelURL.appendingPathExtension("other"),
                priority: .interactive, purpose: "cancelled")
        }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 1)
        await broker.release(first)
    }
}
