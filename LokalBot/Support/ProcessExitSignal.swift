import Foundation

final class ProcessExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var waiter: CheckedContinuation<Void, Never>?

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
