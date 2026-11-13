import XCTest
@testable import LokalBot

final class LiveTurnCutterTests: XCTestCase {
    private let chunk: Int64 = 4_096
    private let padding: Int64 = 1_600
    private let speech: Float = 0.95
    private let quiet: Float = 0.05
    private let unsure: Float = 0.75

    /// Feeds one verdict per chunk and returns each turn with the number of
    /// chunks heard when it closed.
    private func run(_ cutter: inout LiveTurnCutter, _ verdicts: [Float]) -> [(turn: LiveTurnCutter.Turn, chunks: Int)] {
        var closed: [(LiveTurnCutter.Turn, Int)] = []
        for (index, verdict) in verdicts.enumerated() {
            if let turn = cutter.consume(probability: verdict) { closed.append((turn, index + 1)) }
        }
        return closed
    }

    private func short() -> LiveTurnCutter {
        var settings = LiveTurnCutter.Settings()
        settings.eagerAfterSeconds = nil
        return LiveTurnCutter(settings: settings)
    }

    func testTwoQuietChunksCloseATurn() {
        var cutter = short()
        let closed = run(&cutter, [quiet, quiet, speech, speech, speech, quiet, quiet, quiet])
        XCTAssertEqual(closed.count, 1)
        // Speech fills chunks 3 to 5; the turn keeps 0.1 s on either side.
        XCTAssertEqual(closed.first?.turn, .init(start: 2 * chunk - padding, end: 5 * chunk + padding, forced: false))
        XCTAssertEqual(closed.first?.chunks, 7, "closed at the second quiet chunk, half a second into the pause")
        XCTAssertNil(cutter.openStart)
    }

    func testOneQuietChunkIsNotAPause() {
        var cutter = short()
        let closed = run(&cutter, [speech, speech, quiet, speech, speech, quiet, quiet])
        XCTAssertEqual(closed.map(\.turn), [.init(start: 0, end: 5 * chunk + padding, forced: false)])
    }

    func testAnUnsureChunkNeitherStartsATurnNorRestartsThePause() {
        var cutter = short()
        XCTAssertTrue(run(&cutter, [unsure, unsure]).isEmpty)
        XCTAssertNil(cutter.openStart, "only a confident chunk starts a turn")
        let closed = run(&cutter, [speech, quiet, unsure, quiet])
        XCTAssertEqual(closed.map(\.turn), [.init(start: 2 * chunk - padding, end: 3 * chunk + padding, forced: false)])
        XCTAssertEqual(closed.first?.chunks, 4, "the pause kept running through the unsure chunk")
    }

    func testALongTurnClosesAtItsFirstQuietChunk() {
        var cutter = LiveTurnCutter()
        XCTAssertEqual(cutter.settings.eagerAfterSeconds, 4)
        // 16 chunks are 4.1 s of speech: one quiet chunk is enough.
        let long = run(&cutter, Array(repeating: speech, count: 16) + [quiet])
        XCTAssertEqual(long.map(\.turn), [.init(start: 0, end: 16 * chunk + padding, forced: false)])

        // 15 chunks are 3.8 s: still two.
        var other = LiveTurnCutter()
        XCTAssertTrue(run(&other, Array(repeating: speech, count: 15) + [quiet]).isEmpty)
        XCTAssertTrue(other.isPausing)
        XCTAssertEqual(run(&other, [quiet]).map(\.turn), [.init(start: 0, end: 15 * chunk + padding, forced: false)])
    }

    func testATurnWithoutAPauseIsHandedOverAtTheMaximumLength() {
        var cutter = short()
        // 15 s are 58.6 chunks, so the 59th reaches the maximum.
        let closed = run(&cutter, Array(repeating: speech, count: 62))
        XCTAssertEqual(closed.map(\.turn), [.init(start: 0, end: 59 * chunk, forced: true)])
        XCTAssertEqual(closed.first?.chunks, 59)
        XCTAssertEqual(cutter.openStart, 59 * chunk, "the speaker is still talking")
        let rest = run(&cutter, [quiet, quiet])
        XCTAssertEqual(rest.map(\.turn), [.init(start: 59 * chunk, end: 62 * chunk + padding, forced: false)])
    }

    func testALengthCutLandsWhereTheCallerFindsQuiet() {
        var cutter = short()
        var turn: LiveTurnCutter.Turn?
        var asked: (from: Int64, to: Int64)?
        for _ in 0..<59 {
            turn = cutter.consume(probability: speech) { from, to in
                asked = (from, to)
                return to - 5_000
            } ?? turn
        }
        XCTAssertEqual(asked?.from, 0)
        XCTAssertEqual(asked?.to, 59 * chunk)
        XCTAssertEqual(turn, .init(start: 0, end: 59 * chunk - 5_000, forced: true))
        XCTAssertEqual(cutter.openStart, 59 * chunk - 5_000, "the next turn starts at the cut")
    }

    func testAPauseRightAfterALengthCutLeavesNoStub() {
        var cutter = short()
        let closed = run(&cutter, Array(repeating: speech, count: 59) + [quiet, quiet, quiet])
        XCTAssertEqual(closed.count, 1, "0.1 s of padding after the cut is not a turn")
        XCTAssertNil(cutter.openStart)
    }

    func testTurnsNeverOverlap() {
        var cutter = LiveTurnCutter()
        var verdicts: [Float] = []
        for burst in [17, 3, 20, 1, 6] { verdicts += Array(repeating: speech, count: burst) + [quiet, quiet] }
        let turns = run(&cutter, verdicts).map(\.turn)
        XCTAssertEqual(turns.count, 5)
        for (earlier, later) in zip(turns, turns.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.end, later.start)
        }
    }

    func testFramesAreOnTheTrackTimelineWhenThePreviewStartsLate() {
        var settings = LiveTurnCutter.Settings()
        settings.eagerAfterSeconds = nil
        var cutter = LiveTurnCutter(settings: settings, startingAt: 160_000)
        let closed = run(&cutter, [speech, speech, quiet, quiet])
        XCTAssertEqual(closed.map(\.turn), [.init(start: 160_000, end: 160_000 + 2 * chunk + padding, forced: false)])
        XCTAssertEqual(cutter.processed, 160_000 + 4 * chunk)
    }
}
