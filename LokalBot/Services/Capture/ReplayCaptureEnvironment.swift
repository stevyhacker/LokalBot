#if DEBUG
import CoreGraphics
import Foundation

/// Virtual time for replay. `sleep` warps time forward (flows that wait, like
/// the 750 ms capture retry, run instantly and deterministically); timers
/// fire when a test advances the clock.
final class VirtualCaptureClock: CaptureClock, @unchecked Sendable {
    private let lock = NSLock()
    private let start: Date
    private var elapsedValue: TimeInterval = 0

    @MainActor private final class VirtualTimer: CaptureTimer {
        var fireAt: TimeInterval
        let repeatEvery: TimeInterval?
        let order: Int
        let work: @MainActor () -> Void
        var cancelled = false

        init(fireAt: TimeInterval, repeatEvery: TimeInterval?, order: Int, work: @escaping @MainActor () -> Void) {
            self.fireAt = fireAt
            self.repeatEvery = repeatEvery
            self.order = order
            self.work = work
        }

        func cancel() { cancelled = true }
    }

    @MainActor private var timers: [VirtualTimer] = []
    @MainActor private var nextOrder = 0

    init(start: Date) { self.start = start }

    var elapsed: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return elapsedValue
    }

    private func setElapsed(_ value: TimeInterval) {
        lock.lock()
        elapsedValue = max(elapsedValue, value)
        lock.unlock()
    }

    func now() -> Date { start.addingTimeInterval(elapsed) }
    func uptime() -> TimeInterval { 10_000 + elapsed }

    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        setElapsed(elapsed + max(0, seconds))
    }

    @MainActor
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CaptureTimer {
        add(fireAt: elapsed + max(0, seconds), repeatEvery: nil, work)
    }

    @MainActor
    func repeating(every seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CaptureTimer {
        add(fireAt: elapsed + max(0.001, seconds), repeatEvery: max(0.001, seconds), work)
    }

    @MainActor
    private func add(fireAt: TimeInterval, repeatEvery: TimeInterval?,
                     _ work: @escaping @MainActor () -> Void) -> CaptureTimer {
        nextOrder += 1
        let timer = VirtualTimer(fireAt: fireAt, repeatEvery: repeatEvery, order: nextOrder, work: work)
        timers.append(timer)
        return timer
    }

    @MainActor
    func advance(by seconds: TimeInterval) async {
        await advance(to: elapsed + max(0, seconds))
    }

    /// Fires due timers in time order (ties by creation order), letting work
    /// they start run between firings.
    @MainActor
    func advance(to target: TimeInterval) async {
        while let next = timers.filter({ !$0.cancelled && $0.fireAt <= target })
            .min(by: { ($0.fireAt, $0.order) < ($1.fireAt, $1.order) }) {
            setElapsed(next.fireAt)
            if let every = next.repeatEvery {
                next.fireAt += every
            } else {
                next.cancelled = true
            }
            next.work()
            for _ in 0..<10 { await Task.yield() }
        }
        timers.removeAll { $0.cancelled }
        setElapsed(target)
        for _ in 0..<10 { await Task.yield() }
    }
}

/// Wall-clock replay for the UI background host: trace time advances with
/// real time × speed; timers and sleeps use the live clock, scaled.
final class RealTimeReplayClock: CaptureClock, @unchecked Sendable {
    private let start: Date
    private let speed: Double
    private let live = LiveCaptureClock()

    init(start: Date, speed: Double) {
        self.start = start
        self.speed = max(0.1, speed)
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(start) * speed }
    func now() -> Date { start.addingTimeInterval(elapsed) }
    func uptime() -> TimeInterval { 10_000 + elapsed }
    func sleep(seconds: TimeInterval) async throws { try await live.sleep(seconds: seconds / speed) }

    @MainActor
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CaptureTimer {
        live.schedule(after: seconds / speed, work)
    }

    @MainActor
    func repeating(every seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CaptureTimer {
        live.repeating(every: seconds / speed, work)
    }
}

/// Answers every capture-environment query from a trace in virtual time.
final class ReplayCaptureEnvironment: @unchecked Sendable {
    let trace: CaptureTrace
    let clock: VirtualCaptureClock
    private let lock = NSLock()
    private let timelines: [String: [CaptureTrace.Event]]
    private var cursors: [String: Int] = [:]

    let realTimeClock: RealTimeReplayClock?

    init(trace: CaptureTrace, start: Date, realTimeSpeed: Double? = nil) {
        self.trace = trace
        self.clock = VirtualCaptureClock(start: start)
        self.realTimeClock = realTimeSpeed.map { RealTimeReplayClock(start: start, speed: $0) }
        self.timelines = Dictionary(grouping: trace.events, by: \.key).mapValues { $0.sorted { $0.t < $1.t } }
    }

    private var elapsed: TimeInterval { realTimeClock?.elapsed ?? clock.elapsed }

    var environment: CaptureEnvironment {
        CaptureEnvironment(workspace: Workspace(replay: self), accessibility: Accessibility(replay: self),
                           windows: Windows(replay: self), audio: Audio(replay: self), clock: realTimeClock ?? clock)
    }

    func answer(_ query: CaptureTrace.Query, processID: pid_t? = nil, includeText: Bool? = nil) -> CaptureTrace.Event? {
        let key = CaptureTrace.Event(t: 0, query: query, processID: processID, includeText: includeText).key
        guard let timeline = timelines[key], !timeline.isEmpty else { return nil }
        let now = elapsed
        guard let newest = timeline.lastIndex(where: { $0.t <= now }) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let cursor = cursors[key] ?? -1
        let groupStart = timeline.firstIndex { $0.t >= timeline[newest].t - 1 } ?? newest
        let next = cursor + 1
        let chosen: Int
        if next <= newest, next >= groupStart {
            chosen = next
        } else if next < groupStart {
            chosen = groupStart
        } else {
            chosen = min(cursor, newest)
        }
        cursors[key] = max(cursor, chosen)
        return timeline[chosen]
    }

    private struct Workspace: WorkspaceSource {
        let replay: ReplayCaptureEnvironment
        func frontmostApplication() -> RunningApp? { replay.answer(.frontmost)?.app }
        func runningApplications() -> [RunningApp] { replay.answer(.runningApps)?.apps ?? [] }
        func isRunning(processID: pid_t) -> Bool {
            if let flag = replay.answer(.isRunning, processID: processID)?.flag { return flag }
            return runningApplications().contains { $0.processIdentifier == processID }
        }
        func secondsSinceLastInput() -> TimeInterval { replay.answer(.idleSeconds)?.seconds ?? 0 }
    }

    private struct Accessibility: AccessibilitySource {
        let replay: ReplayCaptureEnvironment
        func isTrusted() -> Bool { replay.answer(.trusted)?.flag ?? true }
        func read(processID: pid_t, includeText: Bool) -> AccessibilityRead {
            let read = replay.answer(.axRead, processID: processID, includeText: includeText)?.read
                ?? AccessibilityRead(snapshot: nil, failure: .init(reason: "no recorded read", isTransient: false))
            if includeText { ScreenAccessibilityReader.recordTextReadFailure(read.failure, processID: processID) }
            return read
        }
        func focusedWindowTitle(processID: pid_t) -> String? {
            replay.answer(.focusedTitle, processID: processID)?.title
        }
        func browserMeetingSnapshot(processID: pid_t, expectedURL: URL?) -> BrowserMeetingSession.Snapshot? {
            guard var snapshot = replay.answer(.browserSnapshot, processID: processID)?.browser else { return nil }
            // Like the live reader, only a Meet room document answers, under
            // its canonical URL, and a read for one room never answers with another.
            guard let room = BrowserMeetingSession.meetURL(snapshot.url.absoluteString),
                  let canonical = URL(string: room) else { return nil }
            snapshot.url = canonical
            if let expected = expectedURL.flatMap({ BrowserMeetingSession.meetURL($0.absoluteString) }),
               room != expected { return nil }
            return snapshot
        }
        func browserReadIssue(processID: pid_t) -> BrowserMeetingSession.ReadIssue? {
            replay.answer(.browserReadIssue, processID: processID)?.issue
        }
    }

    private struct Windows: WindowSource {
        let replay: ReplayCaptureEnvironment
        func screenCaptureGranted() -> Bool { replay.answer(.screenCaptureGranted)?.flag ?? false }
        func onScreenWindows() async throws -> [ScreenshotCaptureLayout.Window] {
            replay.answer(.windows)?.windows ?? []
        }
        func captureImage(windowID: CGWindowID) async throws -> CGImage {
            guard let context = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { throw CaptureEnvironmentError.windowUnavailable(windowID) }
            return image
        }
    }

    private struct Audio: AudioProcessSource {
        let replay: ReplayCaptureEnvironment
        func processes() throws -> [AudioProcess] { replay.answer(.audioProcesses)?.processes ?? [] }
        func isProcessRunningInput(processID: pid_t) -> Bool {
            replay.answer(.inputRunning, processID: processID)?.flag ?? false
        }
    }
}
#endif
