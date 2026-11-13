import XCTest
@testable import LokalBot

final class RemoteInferenceGateTests: XCTestCase {

    // MARK: - Admission policy

    func testBackgroundWorkCannotTakeTheLastSlot() {
        var queue = RemoteRequestQueue()
        let digest = UUID(), dream = UUID(), notes = UUID()
        queue.enqueue(id: digest, priority: .background)
        queue.enqueue(id: dream, priority: .background)
        queue.enqueue(id: notes, priority: .pipeline)

        XCTAssertEqual(queue.admit(now: 0), [notes, digest])
        XCTAssertEqual(queue.waiters.map(\.id), [dream])
        XCTAssertEqual(queue.admit(now: 0), [], "the second background request waits for the first")

        queue.finish(id: digest, rateLimited: false, retryAfter: nil, now: 0)
        XCTAssertEqual(queue.admit(now: 0), [dream])
    }

    func testProcessingWaitersStartInPriorityOrderThenArrivalOrder() {
        var queue = RemoteRequestQueue(limits: .init(maximumConcurrent: 1, maximumBackground: 1))
        let brief = UUID(), notes = UUID(), laterNotes = UUID()
        queue.enqueue(id: brief, priority: .background)
        queue.enqueue(id: notes, priority: .pipeline)
        queue.enqueue(id: laterNotes, priority: .pipeline)

        var started: [UUID] = []
        for _ in 0..<3 {
            let admitted = queue.admit(now: 0)
            XCTAssertEqual(admitted.count, 1)
            started += admitted
            queue.finish(id: admitted[0], rateLimited: false, retryAfter: nil, now: 0)
        }
        XCTAssertEqual(started, [notes, laterNotes, brief])
    }

    func testChatIsNeverQueuedBehindProcessing() {
        var queue = RemoteRequestQueue(limits: .init(maximumConcurrent: 1, maximumBackground: 1))
        let notes = UUID(), digest = UUID(), chat = UUID()
        queue.enqueue(id: notes, priority: .pipeline)
        queue.enqueue(id: digest, priority: .background)
        XCTAssertEqual(queue.admit(now: 0), [notes])

        queue.enqueue(id: chat, priority: .interactive)
        XCTAssertEqual(queue.admit(now: 0), [chat], "the person waiting on an answer starts at once")
        XCTAssertEqual(queue.waiters.map(\.id), [digest])
    }

    func testRateLimitPausesTheWholeOriginUntilRetryAfter() {
        var queue = RemoteRequestQueue()
        let first = UUID(), second = UUID()
        queue.enqueue(id: first, priority: .pipeline)
        XCTAssertEqual(queue.admit(now: 0), [first])
        queue.finish(id: first, rateLimited: true, retryAfter: 5, now: 10)

        queue.enqueue(id: second, priority: .interactive)
        XCTAssertEqual(queue.admit(now: 14.9), [], "even interactive work waits out the provider's pause")
        XCTAssertEqual(queue.admit(now: 15), [second])
    }

    func testCooldownGrowsWithConsecutiveRateLimitsAndResetsAfterSuccess() {
        XCTAssertEqual(RemoteRequestQueue.cooldown(afterConsecutiveRateLimits: 1, retryAfter: nil), 2)
        XCTAssertEqual(RemoteRequestQueue.cooldown(afterConsecutiveRateLimits: 2, retryAfter: nil), 4)
        XCTAssertEqual(RemoteRequestQueue.cooldown(afterConsecutiveRateLimits: 3, retryAfter: nil), 8)
        XCTAssertEqual(RemoteRequestQueue.cooldown(afterConsecutiveRateLimits: 9, retryAfter: nil), 60)
        XCTAssertEqual(RemoteRequestQueue.cooldown(afterConsecutiveRateLimits: 1, retryAfter: 600), 60)

        var queue = RemoteRequestQueue()
        let ids = (0..<3).map { _ in UUID() }
        for id in ids.prefix(2) {
            queue.enqueue(id: id, priority: .pipeline)
            _ = queue.admit(now: 1_000)
            queue.finish(id: id, rateLimited: true, retryAfter: nil, now: 0)
        }
        XCTAssertEqual(queue.consecutiveRateLimits, 2)
        queue.enqueue(id: ids[2], priority: .pipeline)
        _ = queue.admit(now: 1_000)
        queue.finish(id: ids[2], rateLimited: false, retryAfter: nil, now: 1_000)
        XCTAssertEqual(queue.consecutiveRateLimits, 0)
    }

    func testOriginIgnoresPathAndCase() {
        XCTAssertEqual(RemoteInferenceGate.origin(for: URL(string: "https://OpenRouter.ai/api/v1")!),
                       "https://openrouter.ai")
        XCTAssertEqual(RemoteInferenceGate.origin(for: URL(string: "http://localhost:11434")!),
                       "http://localhost:11434")
    }

    // MARK: - Gate actor

    func testNotesStartWhileBackgroundWorkQueuesBehindTheBackgroundSlot() async throws {
        let gate = RemoteInferenceGate()
        let origin = "https://provider.example"
        let digest = try await gate.acquire(origin: origin, priority: .background)
        let dream = Task { try await gate.acquire(origin: origin, priority: .background) }
        try await waitUntil { await gate.snapshot(origin: origin).waiting == 1 }

        let notes = try await gate.acquire(origin: origin, priority: .pipeline)
        let state = await gate.snapshot(origin: origin)
        XCTAssertEqual(state.inFlight, 2)
        XCTAssertEqual(state.waiting, 1, "Dream still waits behind the digest")

        await gate.release(digest)
        let dreamTicket = try await dream.value
        await gate.release(dreamTicket)
        await gate.release(notes)
        let idle = await gate.snapshot(origin: origin)
        XCTAssertEqual(idle.inFlight, 0)
        XCTAssertEqual(idle.waiting, 0)
    }

    func testCancelledWaiterLeavesTheQueue() async throws {
        let gate = RemoteInferenceGate(limits: .init(maximumConcurrent: 1, maximumBackground: 1))
        let origin = "https://provider.example"
        let held = try await gate.acquire(origin: origin, priority: .pipeline)
        let waiting = Task { try await gate.acquire(origin: origin, priority: .background) }
        try await waitUntil { await gate.snapshot(origin: origin).waiting == 1 }
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("a cancelled waiter must not be admitted")
        } catch is CancellationError {}
        let state = await gate.snapshot(origin: origin)
        XCTAssertEqual(state.waiting, 0)
        await gate.release(held)
    }

    // MARK: - Gated engine

    /// Tonight's meeting notes failed after one replay seven seconds later
    /// while the day digest and Dream kept the provider rate limited. Notes now
    /// wait on the origin's cooldown and retry until the provider recovers.
    func testMeetingNotesSurviveARunOfRateLimits() async throws {
        let clock = VirtualClock()
        let gate = RemoteInferenceGate(now: { clock.now }, sleep: { clock.advance($0) })
        let calls = CallCounter()
        let engine = GatedTextEngine(
            base: FlakyEngine(failures: 3, calls: calls),
            origin: "https://openrouter.ai", priority: .pipeline, purpose: "meeting notes",
            gate: gate, sleep: { clock.advance($0) })

        let reply = try await engine.generate(system: "s", prompt: "p", context: [],
                                              schema: ["type": "object"], options: .init(maxTokens: 64))
        XCTAssertEqual(reply, "{}")
        XCTAssertEqual(calls.count, 4)
        XCTAssertGreaterThanOrEqual(clock.now, 2 + 4 + 8, "each rate limit paused the origin")
    }

    func testInteractiveRequestsGiveUpQuickly() async throws {
        let clock = VirtualClock()
        let gate = RemoteInferenceGate(now: { clock.now }, sleep: { clock.advance($0) })
        let calls = CallCounter()
        let engine = GatedTextEngine(
            base: FlakyEngine(failures: 3, calls: calls),
            origin: "https://openrouter.ai", priority: .interactive, purpose: "chat",
            gate: gate, sleep: { clock.advance($0) })
        do {
            _ = try await engine.generate(system: "s", prompt: "p", context: [])
            XCTFail("chat should surface a persistent rate limit")
        } catch let error as TextEngineError {
            XCTAssertTrue(error.isRateLimit)
        }
        XCTAssertEqual(calls.count, 2)
    }

    func testPermanentErrorsAreNotReplayed() async throws {
        let calls = CallCounter()
        let engine = GatedTextEngine(
            base: FlakyEngine(failures: 5, calls: calls,
                              error: .httpStatus(code: 401, detail: "bad key", retryAfter: nil)),
            origin: "https://openrouter.ai", priority: .pipeline, purpose: "meeting notes",
            gate: RemoteInferenceGate())
        do {
            _ = try await engine.generate(system: "s", prompt: "p", context: [])
            XCTFail("401 is not transient")
        } catch {}
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("condition never became true")
    }

    private final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) {
            lock.withLock { value += max(0, seconds) }
        }
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    private struct FlakyEngine: TextEngine {
        let failures: Int
        let calls: CallCounter
        var error: TextEngineError = .httpStatus(code: 429, detail: "Provider returned error", retryAfter: nil)

        var displayName: String { "flaky" }

        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            try reply()
        }

        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any], options: TextGenerationOptions) async throws -> String {
            try reply()
        }

        private func reply() throws -> String {
            if calls.next() <= failures { throw error }
            return "{}"
        }
    }
}
