import Foundation

@MainActor
enum TerminationDeadline {
    static let cleanupLimit: Duration = .seconds(10)

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        @discardableResult
        func finish(_ proceed: Bool) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            continuation.resume(returning: proceed)
            return true
        }
    }

    static func run(
        within limit: Duration,
        saved: @MainActor () -> Bool = { true },
        onTimeout: @escaping @MainActor () -> Void = {},
        cleanup: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard saved() else { return false }
        return await withCheckedContinuation { continuation in
            let gate = Gate(continuation)
            Task { @MainActor in
                gate.finish(await cleanup())
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                if gate.finish(true) { onTimeout() }
            }
        }
    }
}
