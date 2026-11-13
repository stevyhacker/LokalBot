import XCTest
@testable import LokalBot

final class PiProcessTests: XCTestCase {

    private func plan(_ executable: String, _ arguments: [String] = []) -> PiLaunchPlan {
        PiLaunchPlan(executable: URL(fileURLWithPath: executable),
                     arguments: arguments,
                     environment: ["PATH": "/usr/bin:/bin"],
                     workingDirectory: FileManager.default.temporaryDirectory)
    }

    func testRoundTripsLinesThroughCat() async throws {
        let process = PiProcess(plan: plan("/bin/cat"))
        try await process.start()
        try await process.send(line: #"{"type":"get_state"}"#)
        var iterator = (await process.lines).makeAsyncIterator()
        let echoed = await iterator.next()
        XCTAssertEqual(echoed, #"{"type":"get_state"}"#)
        await process.stop()
    }

    func testLinesStreamFinishesOnExit() async throws {
        for iteration in 1...25 {
            let process = PiProcess(plan: plan("/bin/sh", ["-c", "printf 'one\\ntwo\\n'"]))
            try await process.start()
            var collected: [String] = []
            for await line in await process.lines { collected.append(line) }
            XCTAssertEqual(collected, ["one", "two"], "iteration \(iteration)")
            let running = await process.isRunning
            XCTAssertFalse(running, "iteration \(iteration)")
        }
    }

    func testMissingExecutableThrows() async {
        let process = PiProcess(plan: plan("/nonexistent/bun"))
        do {
            try await process.start()
            XCTFail("expected throw")
        } catch PiProcessError.executableNotFound { // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSendAfterExitThrowsNotRunning() async throws {
        let process = PiProcess(plan: plan("/usr/bin/true"))
        try await process.start()
        // Wait for exit by draining the (empty) stream.
        for await _ in await process.lines {}
        do {
            try await process.send(line: "hello")
            XCTFail("expected throw")
        } catch PiProcessError.notRunning { // expected
        }
    }

    func testStderrTailIsCaptured() async throws {
        let process = PiProcess(plan: plan("/bin/sh", ["-c", "echo boom >&2"]))
        try await process.start()
        for await _ in await process.lines {}
        try await Task.sleep(for: .milliseconds(200))   // stderr pipe drains async
        let tail = await process.stderrTail
        XCTAssertTrue(tail.contains("boom"), "\(tail)")
        await process.stop()
    }

    func testStopIsIdempotent() async throws {
        let process = PiProcess(plan: plan("/bin/cat"))
        try await process.start()
        await process.stop()
        await process.stop()
        let running = await process.isRunning
        XCTAssertFalse(running)
    }

    func testStopIsBoundedWhenChildDoesNotDrainStdin() async throws {
        // `sleep` deliberately never reads stdin. A full-size RPC frame fills
        // the pipe and keeps the dedicated writer busy until stop closes it.
        let process = PiProcess(plan: plan("/bin/sh", ["-c", "exec /bin/sleep 3"]))
        try await process.start()
        let line = String(
            repeating: "x",
            count: PiJSONLFrameSplitter.defaultMaximumFrameBytes - 1)
        let blockedSend = Task { try await process.send(line: line) }
        try await Task.sleep(for: .milliseconds(100))

        do {
            try await process.send(line: "second command")
            XCTFail("expected bounded input backpressure")
        } catch PiProcessError.inputBackpressure {
            // expected: the first frame owns the bounded 4 MiB budget
        }

        let started = ContinuousClock.now
        await process.stop()
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))

        do {
            try await blockedSend.value
            XCTFail("expected the blocked write to fail when stdin closes")
        } catch PiProcessError.inputClosed {
            // expected
        } catch PiProcessError.inputWriteFailed {
            // The kernel may report EPIPE before DispatchIO observes close.
        }
    }
}
