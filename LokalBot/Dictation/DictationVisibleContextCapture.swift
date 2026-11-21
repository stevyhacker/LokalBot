import ApplicationServices
import Foundation

final class DictationVisibleContextCapture: @unchecked Sendable {
    typealias Resolver = @Sendable (DictationScreenTarget, CotypingVisibleContext.Policy) -> CotypingVisibleContext.Snapshot?
    static let shared = DictationVisibleContextCapture()
    private let state = DispatchQueue(label: "me.dotenv.LokalBot.dictation.visible-state")
    private let worker = DispatchQueue(label: "me.dotenv.LokalBot.dictation.visible-worker", qos: .userInitiated)
    private let resolver: Resolver
    private let deadlineMilliseconds: Int
    private var busy = false
    private var generation = 0
    private var waiter: CheckedContinuation<CotypingVisibleContext.Snapshot?, Never>?

    init(deadlineMilliseconds: Int = 150, resolver: @escaping Resolver = DictationVisibleContextCapture.resolve) {
        self.deadlineMilliseconds = max(1, deadlineMilliseconds)
        self.resolver = resolver
    }

    func capture(target: DictationScreenTarget, policy: CotypingVisibleContext.Policy) async -> CotypingVisibleContext.Snapshot? {
        guard policy.enabled, !Task.isCancelled else { return nil }
        let result: CotypingVisibleContext.Snapshot? = await withCheckedContinuation { continuation in
            state.async { [self] in
                guard !busy else { continuation.resume(returning: nil); return }
                busy = true
                generation += 1
                let request = generation
                waiter = continuation
                worker.async { [self] in
                    let snapshot = resolver(target, policy)
                    state.async { [self] in
                        busy = false
                        waiter?.resume(returning: snapshot)
                        waiter = nil
                    }
                }
                state.asyncAfter(deadline: .now() + .milliseconds(deadlineMilliseconds)) { [self] in
                    guard generation == request else { return }
                    waiter?.resume(returning: nil)
                    waiter = nil
                }
            }
        }
        return Task.isCancelled ? nil : result
    }

    private static func resolve(target: DictationScreenTarget, policy: CotypingVisibleContext.Policy)
        -> CotypingVisibleContext.Snapshot? {
        guard policy.enabled, let identity = target.focusIdentityKey,
              let before = CotypingAXHelper.resolveDictationFocusSnapshot(),
              !before.blocksContextCapture, before.processID == target.processID,
              before.focusIdentityKey == identity, let element = CotypingAXHelper.focusedElement() else { return nil }
        let source = CotypingVisibleContextAXSource(
            field: element, processID: target.processID, appName: target.appName, bundleID: target.bundleID,
            focusIsCurrent: { CotypingAXHelper.focusedElement().map { CFEqual($0, element) } ?? false })
        let snapshot = CotypingVisibleContext.capture(from: source, policy: policy)
        guard CotypingAXHelper.resolveDictationFocusSnapshot() == before else { return nil }
        return snapshot
    }
}
