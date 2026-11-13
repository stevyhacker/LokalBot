import Foundation
@testable import LokalBot

/// A scriptable transport: records sent lines and lets the test inject
/// incoming lines.
final class FakeTransport: PiLineTransport, @unchecked Sendable {
    private(set) var sent: [String] = []
    private let lock = NSLock()
    private var sendFailure: Error?
    let incoming: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        var c: AsyncStream<String>.Continuation!
        incoming = AsyncStream { c = $0 }
        continuation = c
    }

    func send(line: String) async throws {
        let failure = lock.withLock {
            let failure = sendFailure
            if failure == nil { sent.append(line) }
            return failure
        }
        if let failure { throw failure }
    }

    func inject(_ line: String) { continuation.yield(line) }
    func close() { continuation.finish() }
    func failFutureSends(_ error: Error = URLError(.cannotConnectToHost)) {
        lock.withLock { sendFailure = error }
    }
    var sentLines: [String] { lock.withLock { sent } }
}
