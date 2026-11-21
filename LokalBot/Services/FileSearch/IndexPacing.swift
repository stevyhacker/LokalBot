import CoreGraphics
import Foundation

struct IndexPacing: Sendable {
    static let restPerSecondOfWork = 2.0
    static let awayAfter: TimeInterval = 120
    static let longestRest: TimeInterval = 20

    var secondsSinceInput: @Sendable () -> TimeInterval

    static let live = IndexPacing(secondsSinceInput: {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    })
    static let unpaced = IndexPacing(secondsSinceInput: { .infinity })

    func rest(after worked: TimeInterval) -> TimeInterval {
        guard worked > 0, secondsSinceInput() < Self.awayAfter else { return 0 }
        return min(worked * Self.restPerSecondOfWork, Self.longestRest)
    }
}

final class FileIndexPacer: @unchecked Sendable {
    private let pacing: IndexPacing
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) -> Void
    private var resumed: Date?
    private(set) var rested: TimeInterval = 0

    init(pacing: IndexPacing, now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.pacing = pacing
        self.now = now
        self.sleep = sleep
    }

    func restBetweenJobs(stop: () -> Bool) {
        defer { resumed = now() }
        guard let resumed else { return }
        var left = pacing.rest(after: now().timeIntervalSince(resumed))
        while left > 0, !stop() {
            let step = min(left, 0.1)
            sleep(step)
            rested += step
            left -= step
        }
    }
}
