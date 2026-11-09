import XCTest
@testable import LokalBot

/// How big reads share the Mac with the person using it.
final class IndexPacingTests: XCTestCase {
    func testWhileThePersonIsAtTheMacReadingRestsTwiceAsLongAsItWorked() {
        let pacing = IndexPacing(secondsSinceInput: { 5 })
        XCTAssertEqual(pacing.rest(after: 1.5), 3)
        XCTAssertEqual(pacing.rest(after: 0), 0)
        XCTAssertEqual(pacing.rest(after: 60), IndexPacing.longestRest, "a long batch never holds reading up for long")
    }

    func testOnceThePersonStepsAwayReadingGoesAtFullSpeed() {
        let pacing = IndexPacing(secondsSinceInput: { IndexPacing.awayAfter })
        XCTAssertEqual(pacing.rest(after: 4), 0)
        XCTAssertEqual(IndexPacing.unpaced.rest(after: 4), 0)
    }

    func testThePacerRestsBetweenJobsAfterTheJobItTimed() {
        let clock = TestClock()
        let pacer = FileIndexPacer(pacing: IndexPacing(secondsSinceInput: { 1 }),
                                   now: { clock.now }, sleep: { clock.sleep($0) })

        pacer.restBetweenJobs { false }
        XCTAssertEqual(pacer.rested, 0, "nothing to rest after before the first job")

        clock.advance(2)   // the first job
        pacer.restBetweenJobs { false }
        XCTAssertEqual(pacer.rested, 4, accuracy: 0.001)

        clock.advance(0.5)   // the second job; the rest above doesn't count as work
        pacer.restBetweenJobs { false }
        XCTAssertEqual(pacer.rested, 5, accuracy: 0.001)
    }

    func testAStopEndsARestAtOnce() {
        let clock = TestClock()
        let pacer = FileIndexPacer(pacing: IndexPacing(secondsSinceInput: { 1 }),
                                   now: { clock.now }, sleep: { clock.sleep($0) })
        pacer.restBetweenJobs { false }
        clock.advance(5)

        pacer.restBetweenJobs { clock.slept >= 0.3 }

        XCTAssertEqual(pacer.rested, 0.3, accuracy: 0.001)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    private(set) var slept: TimeInterval = 0
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { start.addingTimeInterval(offset) } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { offset += seconds }
    }

    func sleep(_ seconds: TimeInterval) {
        lock.withLock {
            offset += seconds
            slept += seconds
        }
    }
}
