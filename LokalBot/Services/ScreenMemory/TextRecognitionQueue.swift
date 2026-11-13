import Foundation

/// Runs every Vision text-recognition request in the app, one at a time on its
/// own queue, and lets no caller wait past its time limit.
///
/// Vision sends all text recognition in a process through one serial queue.
/// On 2026-11-09 a request never came back from it, so every later one waited
/// behind it for good, and so did its caller: screen capture kept its turn and
/// stored nothing for the rest of the day, and each caret lookup parked a
/// Swift concurrency thread until none was left for the rest of the app.
///
/// A caller that has no answer at its limit goes on without the text. Work
/// that had not started is dropped; work under way finishes, since Vision
/// cannot be interrupted, and its result is thrown away. Once a request has
/// run for `stallLimit`, recognition counts as stalled: callers are turned
/// away at once and `observeStalls` hears of it, until that request returns.
final class TextRecognitionQueue: @unchecked Sendable {
    static let shared = TextRecognitionQueue()

    /// Which waiting request runs next. Requests of one urgency run in order.
    enum Urgency: Int, Sendable {
        /// Someone typing or dictating waits for this text.
        case interactive
        /// Screen memory.
        case background
    }

    /// Recognition that stopped answering: what it was reading for, and how
    /// long that had taken when it was noticed.
    struct Stall: Equatable, Sendable {
        let purpose: String
        let seconds: TimeInterval
    }

    private final class Job: @unchecked Sendable {
        let urgency: Urgency
        let sequence: UInt64
        let purpose: String
        let work: () -> Void
        let answer: (_ finished: Bool) -> Void
        /// Guarded by the queue's lock.
        var answered = false

        init(urgency: Urgency, sequence: UInt64, purpose: String,
             work: @escaping () -> Void, answer: @escaping (Bool) -> Void) {
            self.urgency = urgency
            self.sequence = sequence
            self.purpose = purpose
            self.work = work
            self.answer = answer
        }

        func runsBefore(_ other: Job) -> Bool {
            (urgency.rawValue, sequence) < (other.urgency.rawValue, other.sequence)
        }
    }

    /// What the work returned, on its way from the worker to the caller.
    private final class Slot<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func put(_ value: Value?) {
            lock.withLock { self.value = value }
        }

        func take() -> Value? {
            lock.withLock {
                defer { value = nil }
                return value
            }
        }
    }

    /// Lets a cancelled caller stop waiting, whether it is cancelled before or
    /// after its request went in.
    private final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var release: (() -> Void)?

        func hold(_ release: @escaping () -> Void) {
            let alreadyCancelled = lock.withLock { () -> Bool in
                if !cancelled { self.release = release }
                return cancelled
            }
            if alreadyCancelled { release() }
        }

        func cancel() {
            let release = lock.withLock { () -> (() -> Void)? in
                cancelled = true
                defer { self.release = nil }
                return self.release
            }
            release?()
        }
    }

    /// Longer than any request that came back: the slowest in six weeks of
    /// one Mac's log took 86 s, across a sleep.
    static let defaultStallLimit: TimeInterval = 120

    private let stallLimit: TimeInterval
    private let worker = DispatchQueue(label: "me.dotenv.LokalBot.text-recognition", qos: .utility)
    private let limits = DispatchQueue(label: "me.dotenv.LokalBot.text-recognition.limits", qos: .userInitiated)
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0
    private var waiting: [Job] = []
    private var running: (job: Job, since: DispatchTime)?
    private var stall: Stall?
    private var stallObserver: (@Sendable (Stall?) -> Void)?

    init(stallLimit: TimeInterval = TextRecognitionQueue.defaultStallLimit) {
        self.stallLimit = max(0.001, stallLimit)
    }

    /// Set while recognition is not answering.
    var currentStall: Stall? {
        lock.withLock { stall }
    }

    /// Requests whose turn has not come. For tests.
    var waitingCount: Int {
        lock.withLock { waiting.count }
    }

    /// Called with the stall when recognition stops answering, and with nil
    /// when it answers again. One observer at a time.
    func observeStalls(_ observer: (@Sendable (Stall?) -> Void)?) {
        lock.withLock { stallObserver = observer }
    }

    /// What `work` returns, or nil when there is no answer within `seconds`
    /// (counted from now, waiting for earlier requests included) or
    /// recognition is stalled. Never blocks the caller's thread.
    func run<Value: Sendable>(
        _ purpose: String, urgency: Urgency = .background, within seconds: TimeInterval,
        _ work: @escaping @Sendable () -> Value
    ) async -> Value? {
        let ticket = Ticket()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                let job = submit(purpose, urgency: urgency, within: seconds, work) {
                    continuation.resume(returning: $0)
                }
                if let job {
                    ticket.hold { [weak self] in self?.stopWaiting(for: job) }
                }
            }
        } onCancel: {
            ticket.cancel()
        }
    }

    /// The same for a caller that cannot suspend. Its thread waits, for at
    /// most `seconds`.
    func runAndWait<Value: Sendable>(
        _ purpose: String, urgency: Urgency = .background, within seconds: TimeInterval,
        _ work: @escaping @Sendable () -> Value
    ) -> Value? {
        let answered = DispatchSemaphore(value: 0)
        let result = Slot<Value>()
        submit(purpose, urgency: urgency, within: seconds, work) { value in
            result.put(value)
            answered.signal()
        }
        // The limit's own timer answers; the extra second is for a late timer.
        _ = answered.wait(timeout: .now() + max(0, seconds) + 1)
        return result.take()
    }

    @discardableResult
    private func submit<Value: Sendable>(
        _ purpose: String, urgency: Urgency, within seconds: TimeInterval,
        _ work: @escaping @Sendable () -> Value, answer: @escaping @Sendable (Value?) -> Void
    ) -> Job? {
        let produced = Slot<Value>()
        let job = lock.withLock { () -> Job? in
            guard stall == nil else { return nil }
            nextSequence &+= 1
            let job = Job(
                urgency: urgency, sequence: nextSequence, purpose: purpose,
                work: { produced.put(work()) },
                answer: { finished in answer(finished ? produced.take() : nil) })
            waiting.append(job)
            return job
        }
        guard let job else {
            answer(nil)
            return nil
        }
        limits.asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
            self?.stopWaiting(for: job)
        }
        worker.async(qos: urgency == .interactive ? .userInitiated : .utility) { [weak self] in
            self?.runNext()
        }
        return job
    }

    /// One call per request. A request whose caller stopped waiting before its
    /// turn is gone by then, so a call can find nothing to run.
    private func runNext() {
        let next = lock.withLock { () -> Job? in
            guard let job = waiting.min(by: { $0.runsBefore($1) }) else { return nil }
            waiting.removeAll { $0 === job }
            running = (job, .now())
            return job
        }
        guard let job = next else { return }
        limits.asyncAfter(deadline: .now() + stallLimit) { [weak self] in
            self?.noteStall(of: job)
        }
        job.work()

        let finished = lock.withLock { () -> (wanted: Bool, seconds: TimeInterval, recovered: Bool, observer: (@Sendable (Stall?) -> Void)?) in
            let seconds = running.map { Self.seconds(since: $0.since) } ?? 0
            running = nil
            let recovered = stall != nil
            stall = nil
            let wanted = !job.answered
            job.answered = true
            return (wanted, seconds, recovered, stallObserver)
        }
        if finished.wanted { job.answer(true) }
        if finished.recovered {
            lokalbotLog("text recognition: answered after \(Int(finished.seconds)) s (\(job.purpose)); back on")
            finished.observer?(nil)
        }
    }

    /// The caller goes on without the text.
    private func stopWaiting(for job: Job) {
        let wanted = lock.withLock { () -> Bool in
            guard !job.answered else { return false }
            job.answered = true
            waiting.removeAll { $0 === job }
            return true
        }
        if wanted { job.answer(false) }
    }

    private func noteStall(of job: Job) {
        let noted = lock.withLock { () -> (stall: Stall, unanswered: [Job], observer: (@Sendable (Stall?) -> Void)?)? in
            guard let running, running.job === job, stall == nil else { return nil }
            let found = Stall(purpose: job.purpose, seconds: Self.seconds(since: running.since))
            stall = found
            let unanswered = (waiting + [job]).filter { !$0.answered }
            unanswered.forEach { $0.answered = true }
            waiting.removeAll()
            return (found, unanswered, stallObserver)
        }
        guard let noted else { return }
        noted.unanswered.forEach { $0.answer(false) }
        lokalbotLog("text recognition: no answer after \(Int(noted.stall.seconds)) s (\(noted.stall.purpose)); "
            + "off until it answers or LokalBot restarts")
        noted.observer?(noted.stall)
    }

    private static func seconds(since start: DispatchTime) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return now > start.uptimeNanoseconds ? Double(now - start.uptimeNanoseconds) / 1_000_000_000 : 0
    }
}
