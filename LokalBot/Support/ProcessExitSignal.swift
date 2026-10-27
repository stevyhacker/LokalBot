import Foundation

/// Waits for a `Process` to exit without `waitUntilExit()`.
///
/// `waitUntilExit()` returns only after Foundation finishes the exit on the
/// run loop of the thread that called `run()`. After any `await`, Swift
/// concurrency may resume the task on another thread, and nothing turns the
/// launching thread's run loop again, so that wait can block forever after
/// the child has exited and been reaped. The termination handler runs on
/// Foundation's own queue and has no such dependency.
final class ProcessExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// Install before `run()` so an instant exit cannot be missed.
    init(_ process: Process) {
        process.terminationHandler = { [self] _ in
            lock.lock()
            exited = true
            let waiter = waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
        }
    }

    /// Returns once the process has exited. Cancellation does not end the
    /// wait; callers stop the process instead, which ends it.
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if exited {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
