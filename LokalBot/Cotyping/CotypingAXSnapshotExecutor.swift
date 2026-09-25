import Foundation

/// Options for one Accessibility snapshot. Keeping these as an option set lets
/// the executor merge queued requests into one superset capture.
struct CotypingAXCaptureOptions: OptionSet, Sendable {
    let rawValue: UInt8

    static let surface = Self(rawValue: 1 << 0)
    static let url = Self(rawValue: 1 << 1)
    static let style = Self(rawValue: 1 << 2)
    static let learningScope = Self(rawValue: 1 << 3)
}
struct CotypingAXCaptureResult: Sendable {
    let focus: CotypingFocus?
    let timedOut: Bool

    static let timeout = Self(focus: nil, timedOut: true)
}

/// Runs all routine AX snapshots on one background queue. There can be at most
/// one active capture and one latest-wins pending batch; callers that arrive
/// while a compatible capture is active share its result. Each caller has one
/// wall-clock deadline for the *whole* snapshot, rather than multiplying the AX
/// per-message timeout by every attribute read.
final class CotypingAXSnapshotExecutor: @unchecked Sendable {
    typealias Resolver = @Sendable (CotypingAXCaptureOptions) -> CotypingFocus

    static let shared = CotypingAXSnapshotExecutor()
    static let defaultDeadlineMilliseconds = 120

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<CotypingAXCaptureResult, Never>
    }

    private struct Batch {
        let id: UInt64
        var options: CotypingAXCaptureOptions
        var waiters: [UInt64: Waiter]
    }

    private let stateQueue = DispatchQueue(label: "me.dotenv.LokalBot.cotyping.ax-snapshot-state")
    private let workerQueue = DispatchQueue(
        label: "me.dotenv.LokalBot.cotyping.ax-snapshot-worker",
        qos: .userInitiated)
    private let deadlineMilliseconds: Int
    private let resolver: Resolver
    private var nextIdentifier: UInt64 = 0
    private var active: Batch?
    private var pending: Batch?

    init(
        deadlineMilliseconds: Int = defaultDeadlineMilliseconds,
        resolver: @escaping Resolver = { options in
            CotypingAXHelper.resolveFocus(
                includeSurface: options.contains(.surface),
                includeURL: options.contains(.url),
                includeStyle: options.contains(.style),
                includeLearningScope: options.contains(.learningScope))
        }
    ) {
        self.deadlineMilliseconds = max(1, deadlineMilliseconds)
        self.resolver = resolver
    }

    func capture(options: CotypingAXCaptureOptions = []) async -> CotypingAXCaptureResult {
        await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                nextIdentifier &+= 1
                let waiterID = nextIdentifier
                let waiter = Waiter(id: waiterID, continuation: continuation)
                enqueue(waiter: waiter, options: options)
                stateQueue.asyncAfter(deadline: .now() + .milliseconds(deadlineMilliseconds)) { [weak self] in
                    self?.expire(waiterID: waiterID)
                }
            }
        }
    }

    private func enqueue(waiter: Waiter, options: CotypingAXCaptureOptions) {
        if var active, options.isSubset(of: active.options) {
            active.waiters[waiter.id] = waiter
            self.active = active
            return
        }

        if var pending {
            pending.options.formUnion(options)
            pending.waiters[waiter.id] = waiter
            self.pending = pending
            return
        }

        nextIdentifier &+= 1
        let batch = Batch(id: nextIdentifier, options: options, waiters: [waiter.id: waiter])
        if active == nil {
            start(batch)
        } else {
            pending = batch
        }
    }

    private func start(_ batch: Batch) {
        active = batch
        let batchID = batch.id
        let options = batch.options
        workerQueue.async { [weak self] in
            guard let self else { return }
            let focus = resolver(options)
            stateQueue.async { [weak self] in
                self?.finish(batchID: batchID, focus: focus)
            }
        }
    }

    private func finish(batchID: UInt64, focus: CotypingFocus) {
        guard let completed = active, completed.id == batchID else { return }
        active = nil
        for waiter in completed.waiters.values {
            waiter.continuation.resume(returning: CotypingAXCaptureResult(focus: focus, timedOut: false))
        }
        startPendingIfNeeded()
    }

    private func expire(waiterID: UInt64) {
        if var active, let waiter = active.waiters.removeValue(forKey: waiterID) {
            self.active = active
            waiter.continuation.resume(returning: .timeout)
            return
        }
        if var pending, let waiter = pending.waiters.removeValue(forKey: waiterID) {
            if pending.waiters.isEmpty {
                self.pending = nil
            } else {
                self.pending = pending
            }
            waiter.continuation.resume(returning: .timeout)
        }
    }

    private func startPendingIfNeeded() {
        guard active == nil, let pending else { return }
        self.pending = nil
        guard !pending.waiters.isEmpty else { return }
        start(pending)
    }
}
