import Foundation

/// How much time and compute one summary + outcomes job may spend before it
/// checkpoints and asks the user to summarize again. Applies to every Think
/// backend (built-in, Apple Intelligence, Ollama, OpenAI-compatible).
enum GenerationBudgetPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case conservative
    case standard
    case generous
    case unlimited

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conservative: "Conservative"
        case .standard: "Default"
        case .generous: "Generous"
        case .unlimited: "Unlimited"
        }
    }

    var detail: String {
        switch self {
        case .conservative: "Half the normal time and tokens. Long meetings may need a second pass."
        case .standard: "Balanced limits that fit most meetings in one pass."
        case .generous: "Three times the normal limits for very long meetings or slower servers."
        case .unlimited: "Runs until finished, with a 6-hour safety stop."
        }
    }

    var limits: MeetingGenerationBudget.Limits {
        switch self {
        case .conservative:
            .init(seconds: 300, requests: 6, inputTokens: 125_000, outputTokens: 12_288)
        case .standard:
            .init()
        case .generous:
            .init(seconds: 1_800, requests: 36, inputTokens: 750_000, outputTokens: 73_728)
        case .unlimited:
            // Finite on purpose: run() races a Task.sleep deadline and
            // allowance() converts seconds * 35 to Int, and a stalled server
            // must not wedge the serialized job queue forever.
            .init(seconds: 21_600, requests: 10_000, inputTokens: 100_000_000, outputTokens: 10_000_000)
        }
    }
}

/// One allowance for the entire summary + outcomes job, including transport
/// replays. Task-local propagation keeps provider and runtime retries inside it.
actor MeetingGenerationBudget {
    struct Limits: Sendable {
        var seconds: Double = 600
        var requests: Int = 12
        var inputTokens: Int = 250_000
        var outputTokens: Int = 24_576
    }

    struct Exhausted: LocalizedError {
        var errorDescription: String? {
            "Notes reached their processing limit. Verified progress was saved; summarize again to continue."
        }
    }

    struct Reservation: Sendable {
        let outputTokens: Int
        let started: Double
        let stage: String
    }

    @TaskLocal static var current: MeetingGenerationBudget?
    @TaskLocal static var stage = "generation"
    @TaskLocal static var promptTokens = 0

    let limits: Limits
    private let attemptID = UUID()
    private let startedAt = Date()
    private let started = ProcessInfo.processInfo.systemUptime
    private var requests = 0
    private var inputTokens = 0
    private var outputTokens = 0
    private var calls: [GenerationCallTelemetry] = []
    private var validations: [ValidationTelemetry] = []
    private var phases: [String: Double] = [:]
    private var model: String?
    private var transcriptRevision: String?
    private var plannedParts: Int?

    init(limits: Limits = Limits()) { self.limits = limits }

    var remainingSeconds: Double { max(0, limits.seconds - elapsed) }
    private var elapsed: Double { ProcessInfo.processInfo.systemUptime - started }

    func allowance(remainingParts: Int, desired: Int = 4_096, minimum: Int = 512) throws -> Int {
        try Task.checkCancellation()
        // Allocate useful output to the parts this run can actually process,
        // reserving one possible repair per part. Very long meetings continue
        // from verified checkpoints instead of starving every part with a tiny
        // allowance divided across work that cannot fit the request limit.
        let processableParts = max(1, (limits.requests - requests + 1) / 2)
        let parts = min(max(1, remainingParts), processableParts)
        let available = min(desired, (limits.outputTokens - outputTokens) / parts,
                            Int(remainingSeconds * 35 / Double(parts)))
        guard requests < limits.requests, available >= max(512, minimum) else { throw Exhausted() }
        return available
    }

    func reserve(input: Int, output: Int) throws -> Reservation {
        try Task.checkCancellation()
        guard remainingSeconds > 0, requests < limits.requests,
              inputTokens + input <= limits.inputTokens,
              outputTokens + output <= limits.outputTokens else { throw Exhausted() }
        requests += 1
        inputTokens += input
        outputTokens += output
        return Reservation(outputTokens: output, started: ProcessInfo.processInfo.systemUptime,
                           stage: Self.stage)
    }

    func finish(_ reservation: Reservation, metric: GenerationCallTelemetry) {
        // Unknown usage retains the reservation; absence is never zero usage.
        if let actual = metric.outputTokens {
            outputTokens += actual - reservation.outputTokens
        }
        var call = metric
        call.stage = reservation.stage
        calls.append(call)
    }

    func recordPhase(_ phase: String, seconds: Double) {
        phases[phase, default: 0] += seconds
    }

    func recordPlan(model: String, transcriptRevision: String, parts: Int) {
        self.model = model
        self.transcriptRevision = transcriptRevision
        plannedParts = parts
    }

    struct ValidationTelemetry: Codable {
        var stage: String
        var completeEnvelope: Bool
        var hasMore: Bool?
        var truncated: Bool
        var notes: Int
        var actions: Int
        var rejections: [String: Int]
    }

    func recordValidation(_ value: ValidationTelemetry) { validations.append(value) }

    /// URLSession and the inference lease both respond to task cancellation.
    /// Structured concurrency waits for their cleanup before another job starts.
    func run<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let seconds = remainingSeconds
        return try await Self.$current.withValue(self) {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    throw Exhausted()
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        }
    }

    func saveMetrics(in folder: URL, outcome: String) {
        struct Report: Encodable {
            var version = 2
            var attemptID: UUID
            var startedAt: Date
            var model: String?
            var transcriptRevision: String?
            var plannedParts: Int?
            var outcome: String
            var elapsedSeconds: Double
            var requests: Int
            var reservedInputTokens: Int
            var accountedOutputTokens: Int
            var phases: [String: Double]
            var calls: [GenerationCallTelemetry]
            var validations: [ValidationTelemetry]
        }
        let report = Report(attemptID: attemptID, startedAt: startedAt, model: model,
                            transcriptRevision: transcriptRevision, plannedParts: plannedParts,
                            outcome: outcome, elapsedSeconds: elapsed, requests: requests,
                            reservedInputTokens: inputTokens, accountedOutputTokens: outputTokens,
                            phases: phases, calls: calls, validations: validations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report) {
            let runs = folder.appendingPathComponent("notes-generation-runs", isDirectory: true)
            try? FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
            try? data.write(to: runs.appendingPathComponent("\(attemptID.uuidString).json"), options: .atomic)
            try? data.write(to: folder.appendingPathComponent("notes-generation-metrics.json"), options: .atomic)
        }
    }
}

/// Content-free diagnostics. Optional runtime values stay absent when a
/// provider does not report them (especially cache and reasoning usage).
struct GenerationCallTelemetry: Codable, Equatable, Sendable {
    var stage: String = "generation"
    var outcome: String
    var wallSeconds: Double
    var inputTokens: Int?
    var outputTokens: Int?
    var cachedTokens: Int?
    var reasoningTokens: Int?
    var prefillSeconds: Double?
    var generationSeconds: Double?

    func log() {
        func value<T>(_ value: T?) -> String { value.map { String(describing: $0) } ?? "unavailable" }
        lokalbotLog("generation call stage=\(stage) outcome=\(outcome) wall=\(wallSeconds) "
            + "input=\(value(inputTokens)) output=\(value(outputTokens)) "
            + "cached=\(value(cachedTokens)) reasoning=\(value(reasoningTokens)) "
            + "prefill=\(value(prefillSeconds)) decode=\(value(generationSeconds))")
    }
}

/// Only the structured notes validator may salvage this content. Other text
/// consumers continue to receive the ordinary outputTruncated error.
struct TruncatedStructuredResponse: LocalizedError {
    let content: String
    var errorDescription: String? { TextEngineError.outputTruncated.errorDescription }
}
