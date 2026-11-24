import Foundation

struct RemoteRequestQueue {
    struct Limits: Equatable, Sendable {
        var maximumConcurrent = 2
        var maximumBackground = 1
    }

    struct Waiter: Equatable {
        let id: UUID
        let priority: InferencePriority
        let order: UInt64
    }

    let limits: Limits
    private(set) var inFlight: [UUID: InferencePriority] = [:]
    private(set) var waiters: [Waiter] = []
    private(set) var cooldownUntil: TimeInterval = 0
    private(set) var consecutiveRateLimits = 0
    private var nextOrder: UInt64 = 0

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    var backgroundInFlight: Int {
        inFlight.values.filter { $0 == .background }.count
    }

    var processingInFlight: Int {
        inFlight.values.filter { $0 >= .pipeline }.count
    }

    mutating func enqueue(id: UUID, priority: InferencePriority) {
        waiters.append(Waiter(id: id, priority: priority, order: nextOrder))
        nextOrder &+= 1
    }

    mutating func cancel(id: UUID) {
        waiters.removeAll { $0.id == id }
    }

    mutating func admit(now: TimeInterval) -> [UUID] {
        guard now >= cooldownUntil else { return [] }
        var admitted: [UUID] = []
        let ordered = waiters.sorted { lhs, rhs in
            (lhs.priority.rawValue, lhs.order) < (rhs.priority.rawValue, rhs.order)
        }
        for waiter in ordered {
            if waiter.priority >= .pipeline {
                guard processingInFlight < limits.maximumConcurrent else { break }
                if waiter.priority == .background, backgroundInFlight >= limits.maximumBackground {
                    continue
                }
            }
            inFlight[waiter.id] = waiter.priority
            admitted.append(waiter.id)
        }
        let started = Set(admitted)
        waiters.removeAll { started.contains($0.id) }
        return admitted
    }

    mutating func finish(id: UUID, rateLimited: Bool, retryAfter: TimeInterval?, now: TimeInterval) {
        inFlight[id] = nil
        guard rateLimited else {
            consecutiveRateLimits = 0
            return
        }
        consecutiveRateLimits += 1
        let pause = Self.cooldown(afterConsecutiveRateLimits: consecutiveRateLimits, retryAfter: retryAfter)
        cooldownUntil = max(cooldownUntil, now + pause)
    }

    static let maximumCooldown: TimeInterval = 60

    static func cooldown(afterConsecutiveRateLimits count: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let exponential = min(maximumCooldown, 2 * pow(2, Double(max(0, count - 1))))
        guard let retryAfter else { return exponential }
        return min(maximumCooldown, max(retryAfter, 1))
    }
}

actor RemoteInferenceGate {
    static let shared = RemoteInferenceGate()

    struct Ticket: Sendable {
        let id: UUID
        let origin: String
    }

    private let limits: RemoteRequestQueue.Limits
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var queues: [String: RemoteRequestQueue] = [:]
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var scheduledWakeups: Set<String> = []

    init(limits: RemoteRequestQueue.Limits = .init(),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.limits = limits
        self.now = now
        self.sleep = sleep
    }

    static func origin(for url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "http"
        let host = url.host?.lowercased() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    func acquire(origin: String, priority: InferencePriority) async throws -> Ticket {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                continuations[id] = continuation
                queues[origin, default: RemoteRequestQueue(limits: limits)]
                    .enqueue(id: id, priority: priority)
                pump(origin)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id, origin: origin) }
        }
        return Ticket(id: id, origin: origin)
    }

    func release(_ ticket: Ticket, rateLimited: Bool = false, retryAfter: TimeInterval? = nil) {
        queues[ticket.origin]?.finish(
            id: ticket.id, rateLimited: rateLimited, retryAfter: retryAfter, now: now())
        pump(ticket.origin)
    }

    func snapshot(origin: String) -> (inFlight: Int, waiting: Int) {
        let queue = queues[origin]
        return (queue?.inFlight.count ?? 0, queue?.waiters.count ?? 0)
    }

    private func cancelWaiter(id: UUID, origin: String) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        queues[origin]?.cancel(id: id)
        continuation.resume(throwing: CancellationError())
        pump(origin)
    }

    private func pump(_ origin: String) {
        guard var queue = queues[origin] else { return }
        let current = now()
        let admitted = queue.admit(now: current)
        let cooldown = queue.cooldownUntil
        let stillWaiting = !queue.waiters.isEmpty
        queues[origin] = queue
        for id in admitted {
            continuations.removeValue(forKey: id)?.resume()
        }
        if stillWaiting, cooldown > current, !scheduledWakeups.contains(origin) {
            scheduledWakeups.insert(origin)
            let delay = cooldown - current
            let sleep = sleep
            Task {
                try? await sleep(delay)
                await self.wake(origin)
            }
        }
    }

    private func wake(_ origin: String) {
        scheduledWakeups.remove(origin)
        pump(origin)
    }
}

enum RemoteRetryPolicy {
    static func maximumAttempts(for priority: InferencePriority) -> Int {
        switch priority {
        case .interactive, .agent: 2
        case .pipeline: 5
        case .background: 4
        }
    }

    static func backoff(attempt: Int, retryAfter: TimeInterval?,
                        jitter: TimeInterval = Double.random(in: 0...0.5)) -> TimeInterval {
        if let retryAfter { return min(RemoteRequestQueue.maximumCooldown, max(0, retryAfter)) }
        return min(RemoteRequestQueue.maximumCooldown, 2 * pow(2, Double(max(0, attempt))) + max(0, jitter))
    }
}

struct GatedTextEngine: TextEngine {
    let base: TextEngine
    let origin: String
    let priority: InferencePriority
    let purpose: String
    var gate: RemoteInferenceGate = .shared
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    var displayName: String { base.displayName }
    var checkpointIdentity: String { base.checkpointIdentity }
    var accountsForGenerationRequests: Bool { base.accountsForGenerationRequests }
    var minimumStructuredOutputTokens: Int { base.minimumStructuredOutputTokens }
    var handlesTransientRetries: Bool { true }
    var structuredOutputEnumLimit: Int? { base.structuredOutputEnumLimit }

    func reasoningAllowance(for options: TextGenerationOptions?) -> Int {
        base.reasoningAllowance(for: options)
    }

    func tokenCount(_ text: String) async throws -> Int? {
        try await base.tokenCount(text)
    }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await replaying { try await base.generate(system: system, prompt: prompt, context: context) }
    }

    func generate(system: String, prompt: String, context: [String],
                  options: TextGenerationOptions) async throws -> String {
        try await replaying {
            try await base.generate(system: system, prompt: prompt, context: context, options: options)
        }
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String {
        try await replaying {
            try await base.generate(system: system, prompt: prompt, context: context, schema: schema)
        }
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any],
                  options: TextGenerationOptions) async throws -> String {
        try await replaying {
            try await base.generate(system: system, prompt: prompt, context: context,
                                    schema: schema, options: options)
        }
    }

    func generateStreaming(system: String, prompt: String, context: [String],
                           options: TextGenerationOptions,
                           onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        try await once {
            try await base.generateStreaming(system: system, prompt: prompt, context: context,
                                             options: options, onPartial: onPartial)
        }
    }

    func complete(_ request: CompletionRequest) async throws -> String {
        try await once { try await base.complete(request) }
    }

    func completeStreaming(_ request: CompletionRequest,
                           onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await once { try await base.completeStreaming(request, onPartial: onPartial) }
    }

    private func once<T>(_ operation: () async throws -> T) async throws -> T {
        let ticket = try await gate.acquire(origin: origin, priority: priority)
        do {
            let value = try await operation()
            await gate.release(ticket)
            return value
        } catch {
            let engineError = error as? TextEngineError
            await gate.release(ticket, rateLimited: engineError?.isRateLimit == true,
                               retryAfter: engineError?.retryAfter)
            throw error
        }
    }

    private func replaying<T>(_ operation: () async throws -> T) async throws -> T {
        let attempts = RemoteRetryPolicy.maximumAttempts(for: priority)
        var attempt = 0
        while true {
            let ticket = try await gate.acquire(origin: origin, priority: priority)
            do {
                let value = try await operation()
                await gate.release(ticket)
                return value
            } catch is CancellationError {
                await gate.release(ticket)
                throw CancellationError()
            } catch {
                let engineError = error as? TextEngineError
                let rateLimited = engineError?.isRateLimit == true
                await gate.release(ticket, rateLimited: rateLimited, retryAfter: engineError?.retryAfter)
                attempt += 1
                guard engineError?.isRetryable == true, attempt < attempts else { throw error }
                lokalbotLog(
                    "remote inference retry purpose=\(purpose) priority=\(priority.label) "
                        + "attempt=\(attempt + 1)/\(attempts) rateLimited=\(rateLimited) "
                        + "error=\(error.localizedDescription)")
                if !rateLimited {
                    try await sleep(RemoteRetryPolicy.backoff(
                        attempt: attempt - 1, retryAfter: engineError?.retryAfter))
                }
            }
        }
    }
}
