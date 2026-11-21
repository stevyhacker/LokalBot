import Foundation

final class TextRecognitionQueue: @unchecked Sendable {
    static let shared = TextRecognitionQueue()

    enum Urgency: Int, Sendable {
        case interactive
        case background
    }

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

    var currentStall: Stall? {
        lock.withLock { stall }
    }

    var waitingCount: Int {
        lock.withLock { waiting.count }
    }

    func observeStalls(_ observer: (@Sendable (Stall?) -> Void)?) {
        lock.withLock { stallObserver = observer }
    }

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
