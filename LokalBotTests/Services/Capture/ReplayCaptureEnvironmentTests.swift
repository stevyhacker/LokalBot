import XCTest
@testable import LokalBot

@MainActor
final class ReplayCaptureEnvironmentTests: XCTestCase {
    private func trace(_ events: [CaptureTrace.Event]) -> CaptureTrace {
        CaptureTrace(header: .init(schemaVersion: 1, macOSVersion: "26.0", origin: .reconstructed,
                                   scenario: "test", scrubberVersion: CaptureTraceScrubber.version,
                                   recordedAt: Date(timeIntervalSince1970: 0)),
                     events: events)
    }

    private let chrome = RunningApp(processIdentifier: 501, bundleIdentifier: "com.google.Chrome",
                                    localizedName: "Google Chrome")

    func testAnswersFollowVirtualTimeAndRecordedOrder() async {
        let unknown = AccessibilityRead(snapshot: nil, failure: .init(reason: "changed", isTransient: true))
        let plain = AccessibilityRead(
            snapshot: ScreenAccessibilitySnapshot(text: "x", sourceURL: nil, documentName: nil,
                                                  focusedSecureField: false, windowTitle: "w", windowFrame: nil),
            failure: nil)
        let replay = ReplayCaptureEnvironment(trace: trace([
            .init(t: 0, query: .frontmost, app: chrome),
            .init(t: 0, query: .axRead, processID: 501, includeText: true, read: unknown),
            .init(t: 0.5, query: .axRead, processID: 501, includeText: true, read: plain),
        ]), start: Date(timeIntervalSince1970: 1_000))
        let environment = replay.environment

        XCTAssertEqual(environment.workspace.frontmostApplication(), chrome)
        XCTAssertEqual(environment.accessibility.read(processID: 501, includeText: true), unknown)
        XCTAssertEqual(ScreenAccessibilityReader.lastTextReadFailure(for: 501)?.isTransient, true)
        XCTAssertEqual(environment.accessibility.read(processID: 501, includeText: true), unknown,
                       "t=0.5 has not arrived yet, so the last answer repeats")
        try? await environment.clock.sleep(seconds: 0.75)
        XCTAssertEqual(replay.clock.elapsed, 0.75, accuracy: 0.001)
        XCTAssertEqual(environment.accessibility.read(processID: 501, includeText: true), plain)
        XCTAssertEqual(environment.clock.now(), Date(timeIntervalSince1970: 1_000.75))
    }

    func testDefaultsBeforeTheFirstEvent() {
        let environment = ReplayCaptureEnvironment(trace: trace([]), start: Date()).environment
        XCTAssertNil(environment.workspace.frontmostApplication())
        XCTAssertTrue(environment.accessibility.isTrusted())
        XCTAssertFalse(environment.windows.screenCaptureGranted())
        XCTAssertEqual(try environment.audio.processes(), [])
    }

    func testTimersFireInOrderWhenTimeAdvances() async {
        let replay = ReplayCaptureEnvironment(trace: trace([]), start: Date())
        var fired: [String] = []
        let repeating = replay.clock.repeating(every: 2) { fired.append("tick@\(Int(replay.clock.elapsed))") }
        _ = replay.clock.schedule(after: 3) { fired.append("stop@\(Int(replay.clock.elapsed))") }
        await replay.clock.advance(by: 5)
        repeating.cancel()
        await replay.clock.advance(by: 4)
        XCTAssertEqual(fired, ["tick@2", "stop@3", "tick@4"])
    }

    func testTraceRoundTripsThroughAFile() throws {
        let original = trace([.init(t: 1, query: .idleSeconds, seconds: 3)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(UUID()).json")
        try original.write(to: url)
        XCTAssertEqual(try CaptureTrace.load(from: url), original)
    }

    func testRealTimeReplayFollowsTheWallClock() async throws {
        let replay = ReplayCaptureEnvironment(
            trace: trace([.init(t: 0.2, query: .idleSeconds, seconds: 9)]),
            start: Date(), realTimeSpeed: 1)
        XCTAssertEqual(replay.environment.workspace.secondsSinceLastInput(), 0)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(replay.environment.workspace.secondsSinceLastInput(), 9)
    }
}
