import AppKit
import XCTest
@testable import LokalBot

private final class LockedTestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    @discardableResult
    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&storage) }
    }
}

// MARK: - Focus poll backoff

final class CotypingFocusPollBackoffTests: XCTestCase {
    private func idledBackoff(captures count: Int) -> CotypingFocusPollBackoff {
        var backoff = CotypingFocusPollBackoff()
        for _ in 0..<count {
            backoff.recordCapture(didChange: false)
        }
        return backoff
    }

    func testFocusTrackerDefaultCadenceAvoidsAggressiveIdleAXPolling() {
        XCTAssertEqual(CotypingFocusTracker.defaultIntervalMs, 200)
    }

    func testRecentActivityStaysAtFullCadence() {
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 0), 1)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 4), 1)
    }

    func testStrideGrowsAsIdlePersists() {
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 5), 3)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 11), 3)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 12), 6)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 29), 6)
        XCTAssertEqual(CotypingFocusPollBackoff.captureStride(idleCaptureCount: 30), 10)
    }

    func testStrideIsMonotonicNonDecreasing() {
        var previous = 0
        for count in 0...120 {
            let stride = CotypingFocusPollBackoff.captureStride(idleCaptureCount: count)
            XCTAssertGreaterThanOrEqual(stride, previous, "stride decreased at idleCaptureCount=\(count)")
            previous = stride
        }
    }

    func testChangeAfterIdleResetsToFullCadence() {
        var backoff = idledBackoff(captures: 400)
        XCTAssertEqual(backoff.idleCaptureCount, CotypingFocusPollBackoff.idleCaptureCountCap)
        XCTAssertGreaterThan(backoff.captureStride, 1)

        backoff.recordCapture(didChange: true)

        XCTAssertEqual(backoff.idleCaptureCount, 0)
        XCTAssertEqual(backoff.captureStride, 1)
    }

    func testExplicitRefreshResetReturnsToFullCadence() {
        var backoff = idledBackoff(captures: 30)
        XCTAssertEqual(backoff.captureStride, 10)

        backoff.reset()

        XCTAssertEqual(backoff.idleCaptureCount, 0)
        XCTAssertEqual(backoff.captureStride, 1)
    }

    func testMillisecondsSinceCaptureIsNilBeforeFirstCapture() {
        XCTAssertNil(CotypingFocusTracker.millisecondsSinceCapture(
            lastCaptureUptimeNanoseconds: nil,
            nowUptimeNanoseconds: 1_000_000))
    }

    func testMillisecondsSinceCaptureUsesCompletedCaptureTime() {
        XCTAssertEqual(CotypingFocusTracker.millisecondsSinceCapture(
            lastCaptureUptimeNanoseconds: 10_000_000,
            nowUptimeNanoseconds: 42_000_000), 32)
    }

    func testShouldRefreshCaptureWhenAgeUnknownOrOlderThanWindow() {
        XCTAssertTrue(CotypingFocusTracker.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: nil,
            nowUptimeNanoseconds: 42_000_000,
            maxAgeMilliseconds: 30))
        XCTAssertTrue(CotypingFocusTracker.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: 10_000_000,
            nowUptimeNanoseconds: 41_000_000,
            maxAgeMilliseconds: 30))
    }

    func testShouldReuseCaptureWithinFreshnessWindow() {
        XCTAssertFalse(CotypingFocusTracker.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: 10_000_000,
            nowUptimeNanoseconds: 40_000_000,
            maxAgeMilliseconds: 30))
        XCTAssertFalse(CotypingFocusTracker.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: 10_000_000,
            nowUptimeNanoseconds: 25_000_000,
            maxAgeMilliseconds: 30))
    }

    func testSnapshotExecutorEnforcesOneWholeCaptureDeadline() async {
        let executor = CotypingAXSnapshotExecutor(deadlineMilliseconds: 25) { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return .none
        }
        let started = ContinuousClock.now

        let result = await executor.capture()

        let elapsed = started.duration(to: .now)
        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.focus)
        XCTAssertLessThan(elapsed, .milliseconds(150),
                          "many bounded AX reads must not multiply into a UI-visible stall")
    }

    func testSnapshotExecutorRunsResolverOffMainThread() async {
        let resolverWasOnMainThread = LockedTestBox(true)
        let executor = CotypingAXSnapshotExecutor { _ in
            resolverWasOnMainThread.update { $0 = Thread.isMainThread }
            return .none
        }

        let result = await executor.capture()

        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(resolverWasOnMainThread.value)
    }

    func testSnapshotExecutorSharesCompatibleInFlightCapture() async {
        let resolverStarted = expectation(description: "resolver started")
        let releaseResolver = DispatchSemaphore(value: 0)
        let invocationCount = LockedTestBox(0)
        let executor = CotypingAXSnapshotExecutor(deadlineMilliseconds: 1_000) { _ in
            invocationCount.update { $0 += 1 }
            resolverStarted.fulfill()
            releaseResolver.wait()
            return .none
        }

        let first = Task { await executor.capture(options: [.surface, .style]) }
        await fulfillment(of: [resolverStarted], timeout: 1)
        let second = Task { await executor.capture(options: [.style]) }
        try? await Task.sleep(for: .milliseconds(20))
        releaseResolver.signal()

        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertFalse(firstResult.timedOut)
        XCTAssertFalse(secondResult.timedOut)
        XCTAssertEqual(invocationCount.value, 1)
    }

    func testSnapshotExecutorKeepsOnlyOneMergedPendingBatch() async {
        let firstResolverStarted = expectation(description: "first resolver started")
        let releaseFirstResolver = DispatchSemaphore(value: 0)
        let capturedOptions = LockedTestBox<[CotypingAXCaptureOptions]>([])
        let executor = CotypingAXSnapshotExecutor(deadlineMilliseconds: 1_000) { options in
            let invocation = capturedOptions.update { values in
                values.append(options)
                return values.count
            }
            if invocation == 1 {
                firstResolverStarted.fulfill()
                releaseFirstResolver.wait()
            }
            return .none
        }

        let active = Task { await executor.capture() }
        await fulfillment(of: [firstResolverStarted], timeout: 1)
        let pendingSurface = Task { await executor.capture(options: [.surface]) }
        let pendingURL = Task { await executor.capture(options: [.url]) }
        let pendingStyle = Task { await executor.capture(options: [.style]) }
        try? await Task.sleep(for: .milliseconds(30))
        releaseFirstResolver.signal()

        _ = await active.value
        _ = await pendingSurface.value
        _ = await pendingURL.value
        _ = await pendingStyle.value
        let finalOptions = capturedOptions.value
        XCTAssertEqual(finalOptions.count, 2,
                       "polls that arrive during a capture must collapse into one pending snapshot")
        XCTAssertEqual(finalOptions.last, [.surface, .url, .style])
    }

    func testSlowSurfaceCaptureDoesNotHoldCacheLockAndSameKeyCoalesces() async {
        let store = CotypingSurfaceCaptureSingleFlight()
        let seeded = CotypingSurfaceCapture(
            windowTitle: "Seeded",
            fieldPlaceholder: nil,
            urlString: nil)
        _ = store.capture(forKey: "seed") { seeded }

        let slowCaptureStarted = expectation(description: "slow surface capture started")
        let releaseSlowCapture = DispatchSemaphore(value: 0)
        let slowResolveCount = LockedTestBox(0)
        let slowValue = CotypingSurfaceCapture(
            windowTitle: "Resolved",
            fieldPlaceholder: "Message",
            urlString: nil)
        let resolveSlow: @Sendable () -> CotypingSurfaceCapture = {
            slowResolveCount.update { $0 += 1 }
            slowCaptureStarted.fulfill()
            releaseSlowCapture.wait()
            return slowValue
        }

        let first = Task.detached {
            store.capture(forKey: "slow") { resolveSlow() }
        }
        await fulfillment(of: [slowCaptureStarted], timeout: 1)

        let readStarted = ContinuousClock.now
        let cachedWhileResolving = store.cachedValue(forKey: "seed")
        let readElapsed = readStarted.duration(to: .now)
        XCTAssertEqual(cachedWhileResolving, seeded)
        XCTAssertLessThan(readElapsed, .milliseconds(50),
                          "a slow AX resolver must run outside the cache lock")

        let second = Task.detached {
            store.capture(forKey: "slow") { resolveSlow() }
        }
        try? await Task.sleep(for: .milliseconds(20))
        releaseSlowCapture.signal()

        let firstValue = await first.value
        let secondValue = await second.value
        XCTAssertEqual(firstValue, slowValue)
        XCTAssertEqual(secondValue, slowValue)
        XCTAssertEqual(slowResolveCount.value, 1,
                       "same-key callers must share the active surface capture")
    }

    func testSurfaceCaptureMaximumAgeRefreshesAuthorizationContext() {
        let store = CotypingSurfaceCaptureSingleFlight()
        var now: TimeInterval = 10
        var resolveCount = 0

        func capture(_ url: String) -> CotypingSurfaceCapture {
            store.capture(forKey: "browser-field", maxAge: 0.25, clock: { now }) {
                resolveCount += 1
                return CotypingSurfaceCapture(windowTitle: nil, fieldPlaceholder: nil, urlString: url)
            }
        }

        XCTAssertEqual(capture("https://allowed.example").urlString, "https://allowed.example")
        now = 10.2
        XCTAssertEqual(capture("https://blocked.example").urlString, "https://allowed.example")
        now = 10.251
        XCTAssertEqual(capture("https://blocked.example").urlString, "https://blocked.example")
        XCTAssertEqual(resolveCount, 2)
    }

    func testSurfaceCaptureInvalidationPreventsSequentialReuse() {
        let store = CotypingSurfaceCaptureSingleFlight()
        var resolveCount = 0
        _ = store.capture(forKey: "browser-field") {
            resolveCount += 1
            return CotypingSurfaceCapture(windowTitle: nil, fieldPlaceholder: nil, urlString: "https://first.example")
        }

        store.removeAll()
        let refreshed = store.capture(forKey: "browser-field") {
            resolveCount += 1
            return CotypingSurfaceCapture(windowTitle: nil, fieldPlaceholder: nil, urlString: "https://second.example")
        }

        XCTAssertEqual(refreshed.urlString, "https://second.example")
        XCTAssertEqual(resolveCount, 2)
    }

    @MainActor
    func testValidationCaptureFailsClosedOnTimeout() async {
        let executor = CotypingAXSnapshotExecutor(deadlineMilliseconds: 20) { _ in
            Thread.sleep(forTimeInterval: 0.15)
            return .none
        }
        let tracker = CotypingFocusTracker(snapshotExecutor: executor)

        let focus = await tracker.refreshForValidation()

        XCTAssertNil(focus)
    }
}
