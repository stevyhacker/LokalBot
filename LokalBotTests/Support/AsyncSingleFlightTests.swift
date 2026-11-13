import XCTest
@testable import LokalBot

final class AsyncSingleFlightTests: XCTestCase {
    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    private enum ExpectedFailure: Error { case failed }

    func testOverlappingCallersShareOneOperation() async throws {
        let flight = AsyncSingleFlight()
        let counter = Counter()

        async let first: Void = flight.run {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(75))
        }
        async let second: Void = flight.run {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(75))
        }
        async let third: Void = flight.run {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(75))
        }

        _ = try await (first, second, third)
        let sharedCount = await counter.value
        XCTAssertEqual(sharedCount, 1)
    }

    func testFailureDoesNotPoisonNextAttempt() async throws {
        let flight = AsyncSingleFlight()
        do {
            try await flight.run { throw ExpectedFailure.failed }
            XCTFail("Expected first attempt to fail")
        } catch ExpectedFailure.failed {
            // Expected.
        }

        let counter = Counter()
        try await flight.run { await counter.increment() }
        let retryCount = await counter.value
        XCTAssertEqual(retryCount, 1)
    }

    func testCancellingLastWaiterCancelsUnderlyingWorkAndAllowsRetry() async throws {
        let flight = AsyncSingleFlight()
        let cancelled = expectation(description: "underlying preparation cancelled")
        let waiter = Task {
            try await flight.run {
                do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.fulfill(); throw error }
            }
        }
        while await flight.waiterCount == 0 { await Task.yield() }
        waiter.cancel()
        do { try await waiter.value; XCTFail("cancelled waiter reported success") } catch is CancellationError {}
        await fulfillment(of: [cancelled], timeout: 2)
        while await flight.isRunning { await Task.yield() }
        try await flight.run {}
    }

    func testCancellingOneWaiterPreservesAnotherConsumersWork() async throws {
        let flight = AsyncSingleFlight()
        let counter = Counter()
        let first = Task {
            try await flight.run {
                try await Task.sleep(for: .milliseconds(100))
                await counter.increment()
            }
        }
        while await flight.waiterCount == 0 { await Task.yield() }
        let second = Task { try await flight.run { XCTFail("duplicated shared operation") } }
        while await flight.waiterCount != 2 { await Task.yield() }
        first.cancel()
        do { try await first.value; XCTFail("cancelled waiter reported success") } catch is CancellationError {}
        try await second.value
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }
}
