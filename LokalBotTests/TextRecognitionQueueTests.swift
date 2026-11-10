import XCTest
@testable import LokalBot

/// 2026-11-09: one text-recognition request never returned. Every later one
/// waited behind it inside Vision, and every caller waited with it.
final class TextRecognitionQueueTests: XCTestCase {
    /// A request that does not return until the test lets it.
    private final class Unanswered: @unchecked Sendable {
        private let lock = NSLock()
        private let released = DispatchSemaphore(value: 0)
        private var waiters = 0

        func wait() {
            lock.withLock { waiters += 1 }
            released.wait()
        }

        func release() {
            let count = lock.withLock { () -> Int in
                defer { waiters = 0 }
                return max(waiters, 1)
            }
            for _ in 0..<count { released.signal() }
        }
    }

    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func add(_ entry: String) {
            lock.withLock { entries.append(entry) }
        }

        var all: [String] { lock.withLock { entries } }
    }

    private var unanswered: Unanswered!

    override func setUp() {
        unanswered = Unanswered()
    }

    override func tearDown() {
        // Frees the queue's thread whatever the test's outcome.
        unanswered.release()
    }

    /// Starts a request that holds the queue and returns once it is running.
    private func holdQueue(_ queue: TextRecognitionQueue, purpose: String = "screen capture",
                           within seconds: TimeInterval = 60) async -> Task<String?, Never> {
        let running = expectation(description: "the request is running")
        let task = Task { [unanswered] in
            await queue.run(purpose, within: seconds) {
                running.fulfill()
                unanswered?.wait()
                return "late"
            }
        }
        await fulfillment(of: [running], timeout: 10)
        return task
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func testACallerGoesOnAtItsLimitWhileItsRequestStillRuns() async {
        let queue = TextRecognitionQueue(stallLimit: 60)
        let started = Date()
        let answer = await queue.run("screen capture", within: 0.1) { [unanswered] in
            unanswered?.wait()
            return "late"
        }
        XCTAssertNil(answer)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the caller waited for the request, not for its limit")

        unanswered.release()
        let next = await queue.run("screen capture", within: 10) { "text" }
        XCTAssertEqual(next, "text", "the queue serves requests again once the slow one returned")
    }

    func testACallerThatCannotSuspendWaitsOnlyToItsLimit() {
        let queue = TextRecognitionQueue(stallLimit: 60)
        let started = Date()
        let answer = queue.runAndWait("screen capture", within: 0.1) { [unanswered] in
            unanswered?.wait()
            return "late"
        }
        XCTAssertNil(answer)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        unanswered.release()
        XCTAssertEqual(queue.runAndWait("screen capture", within: 10) { "text" }, "text")
    }

    func testARequestWhoseCallerLeftBeforeItsTurnNeverRuns() async {
        let queue = TextRecognitionQueue(stallLimit: 60)
        let record = Record()
        let first = await holdQueue(queue)

        let second = await queue.run("autocomplete caret", within: 0.1) {
            record.add("second")
            return "text"
        }
        XCTAssertNil(second)

        unanswered.release()
        let firstAnswer = await first.value
        XCTAssertEqual(firstAnswer, "late")
        let third = await queue.run("autocomplete caret", within: 10) { "text" }
        XCTAssertEqual(third, "text")
        XCTAssertEqual(record.all, [], "work nobody waits for must not take a turn")
    }

    func testACancelledCallerStopsWaitingAndItsRequestNeverRuns() async {
        let queue = TextRecognitionQueue(stallLimit: 60)
        let record = Record()
        let first = await holdQueue(queue)

        let find = Task {
            await queue.run("autocomplete caret", within: 60) {
                record.add("cancelled")
                return "text"
            }
        }
        await waitUntil { queue.waitingCount == 1 }
        find.cancel()
        let answer = await find.value
        XCTAssertNil(answer)
        XCTAssertEqual(queue.waitingCount, 0)

        unanswered.release()
        _ = await first.value
        _ = await queue.run("autocomplete caret", within: 10) { "text" }
        XCTAssertEqual(record.all, [])
    }

    func testTypingIsServedBeforeScreenMemoryThatWaitedLonger() async {
        let queue = TextRecognitionQueue(stallLimit: 60)
        let record = Record()
        let first = await holdQueue(queue)

        let capture = Task {
            await queue.run("screen capture", urgency: .background, within: 60) { record.add("screen capture") }
        }
        await waitUntil { queue.waitingCount == 1 }
        let caret = Task {
            await queue.run("autocomplete caret", urgency: .interactive, within: 60) { record.add("caret") }
        }
        await waitUntil { queue.waitingCount == 2 }

        unanswered.release()
        _ = await first.value
        _ = await capture.value
        _ = await caret.value
        XCTAssertEqual(record.all, ["caret", "screen capture"])
    }

    func testRecognitionThatStopsAnsweringTurnsCallersAwayUntilItAnswers() async {
        let queue = TextRecognitionQueue(stallLimit: 0.2)
        let stalled = expectation(description: "the stall is reported")
        let recovered = expectation(description: "the recovery is reported")
        queue.observeStalls { stall in
            (stall == nil ? recovered : stalled).fulfill()
        }

        let first = await holdQueue(queue, purpose: "screen capture")
        // Waiting when the stall is noticed: answered then, not at its own limit.
        let waiting = Task { await queue.run("autocomplete window text", within: 60) { "never read" } }
        await fulfillment(of: [stalled], timeout: 10)
        XCTAssertEqual(queue.currentStall?.purpose, "screen capture")
        let firstAnswer = await first.value
        XCTAssertNil(firstAnswer)
        let waitingAnswer = await waiting.value
        XCTAssertNil(waitingAnswer)

        let started = Date()
        let refused = await queue.run("autocomplete caret", within: 60) { "never read" }
        XCTAssertNil(refused)
        XCTAssertNil(queue.runAndWait("screen capture", within: 60) { "never read" })
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "a caller waited although recognition is stalled")

        unanswered.release()
        await fulfillment(of: [recovered], timeout: 10)
        XCTAssertNil(queue.currentStall)
        let answer = await queue.run("screen capture", within: 10) { "text" }
        XCTAssertEqual(answer, "text")
    }
}
