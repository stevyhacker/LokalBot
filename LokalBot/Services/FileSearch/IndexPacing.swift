import CoreGraphics
import Foundation

/// How hard a big read works the Mac: a folder's first pass in Files, or the
/// picture vectors of saved screens. While the person is at the Mac, reading
/// gets about a third of the time: after each batch it rests twice as long as
/// the batch took. After two minutes without a key press or mouse move it goes
/// at full speed, and the next input slows it again after the current batch.
struct IndexPacing: Sendable {
    /// Seconds of rest for each second of work while the person is at the Mac.
    static let restPerSecondOfWork = 2.0
    /// No input for this long: they stepped away.
    static let awayAfter: TimeInterval = 120
    /// A long batch (the frames of an hour of video) never holds reading up
    /// for longer than this.
    static let longestRest: TimeInterval = 20

    var secondsSinceInput: @Sendable () -> TimeInterval

    /// Paced by the person's keyboard and mouse. Reading the idle time needs
    /// no permission.
    static let live = IndexPacing(secondsSinceInput: {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    })
    /// Full speed, always: tests.
    static let unpaced = IndexPacing(secondsSinceInput: { .infinity })

    /// How long to rest after `worked` seconds of reading.
    func rest(after worked: TimeInterval) -> TimeInterval {
        guard worked > 0, secondsSinceInput() < Self.awayAfter else { return 0 }
        return min(worked * Self.restPerSecondOfWork, Self.longestRest)
    }
}

/// Paces a Files pass on the index queue. DigUp asks `shouldStop` between
/// jobs (a batch of up to 8 pictures, a file, or a step of a long one), and
/// the pacer rests there in short sleeps, so a stop never waits on a rest.
/// The next job is read and decoded ahead meanwhile, so no rest is wasted.
final class FileIndexPacer: @unchecked Sendable {
    private let pacing: IndexPacing
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) -> Void
    private var resumed: Date?
    /// Seconds rested so far, for the pass report.
    private(set) var rested: TimeInterval = 0

    init(pacing: IndexPacing, now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.pacing = pacing
        self.now = now
        self.sleep = sleep
    }

    /// Between jobs: rests after the job that just finished, if the person is
    /// at the Mac. Returns early once `stop` says so.
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
