import XCTest
@testable import LokalBot

@MainActor
final class TerminationDeadlineTests: XCTestCase {
    func testFinishedCleanupReturnsItsOwnAnswer() async {
        let proceed = await TerminationDeadline.run(within: .seconds(5)) { true }
        let refused = await TerminationDeadline.run(within: .seconds(5)) { false }

        XCTAssertTrue(proceed)
        XCTAssertFalse(refused)
    }

    func testCleanupThatNeverFinishesStopsWaitingAtTheLimit() async {
        var release: CheckedContinuation<Void, Never>?
        var timedOut = false
        let started = ContinuousClock.now

        let proceed = await TerminationDeadline.run(
            within: .milliseconds(100),
            onTimeout: { timedOut = true },
            cleanup: {
                await withCheckedContinuation { release = $0 }
                return false
            })

        XCTAssertTrue(proceed)
        XCTAssertTrue(timedOut)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        release?.resume()
    }

    func testCleanupFinishingAfterTheLimitDoesNotAnswerTwice() async {
        let proceed = await TerminationDeadline.run(within: .milliseconds(50)) {
            try? await Task.sleep(for: .milliseconds(200))
            return false
        }
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(proceed)
    }

    func testFastCleanupDoesNotReportATimeout() async {
        var timedOut = false

        _ = await TerminationDeadline.run(
            within: .milliseconds(100),
            onTimeout: { timedOut = true },
            cleanup: { true })
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertFalse(timedOut)
    }
}
