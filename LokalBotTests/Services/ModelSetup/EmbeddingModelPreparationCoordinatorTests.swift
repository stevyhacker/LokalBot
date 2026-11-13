import XCTest
@testable import LokalBot

final class EmbeddingPreparationTests: XCTestCase {
    private actor OperationGate {
        private(set) var invocationCount = 0
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func run(result: URL) async throws -> URL {
            invocationCount += 1
            started = true
            let waitingForStart = startWaiters
            startWaiters.removeAll()
            for waiter in waitingForStart { waiter.resume() }
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            try Task.checkCancellation()
            return result
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            released = true
            let waiting = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
    }

    func testConcurrentWaitersSharePreparationAndCancelIndependently() async throws {
        let coordinator = EmbeddingModelPreparationCoordinator()
        let gate = OperationGate()
        let key = "/tmp/embedding-model.gguf"
        let expected = URL(fileURLWithPath: key)

        let first = Task {
            try await coordinator.prepare(key: key) {
                try await gate.run(result: expected)
            }
        }
        await gate.waitUntilStarted()
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("the canceled waiter should return without canceling shared work")
        } catch is CancellationError {
            // expected
        }
        let waitersAfterCancellation = await coordinator.waiterCount(for: key)
        XCTAssertEqual(waitersAfterCancellation, 0)

        let second = Task {
            try await coordinator.prepare(key: key) {
                return URL(fileURLWithPath: "/tmp/unexpected.gguf")
            }
        }
        while await coordinator.waiterCount(for: key) < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let countWhileSecondWaits = await gate.invocationCount
        XCTAssertEqual(countWhileSecondWaits, 1)

        await gate.release()
        let secondValue = try await second.value
        XCTAssertEqual(secondValue, expected)
        let finalCount = await gate.invocationCount
        XCTAssertEqual(finalCount, 1)
    }
}
