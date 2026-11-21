import Foundation

/// One night's dream, end to end: compile the previous day's evidence, ask
/// the Main LLM engine for the retrospective + memory update, merge and
/// persist. When no model is reachable the deterministic evidence-only brief
/// is written instead — the morning surface is never empty, and the report
/// itself says which kind it is. Evidence comes from the local library;
/// generation follows the configured Main LLM privacy boundary (on-device or
/// an explicitly approved remote origin), and artifacts land inside the
/// storage root.
struct DreamService {
    typealias EngineSelection = (
        engine: TextEngine,
        provenance: DreamInferenceProvenance
    )

    var storageRoot: URL
    /// Resolved per-dream so backend/model changes apply to the next night;
    /// same seam as chat/dictation (`ThinkExecution.makeTextEngine`).
    var makeEngine: () async throws -> EngineSelection
    var language: DailySummaryLanguage = .english
    var now: () -> Date = Date.init
    var compileEvidence: @Sendable (DreamScheduler.Target, URL) throws -> DreamEvidence = { target, root in
        try DreamCompiler.compile(day: target.day, storageRoot: root, calendar: target.calendar)
    }

    @discardableResult
    func dream(target: DreamScheduler.Target) async throws -> DreamReport {
        let root = storageRoot
        let store = DreamStore(root: root)
        // Read before the detached compilation: cancellation alone cannot
        // detect a source mutation while the library snapshot is being read.
        let revision = try store.evidenceRevision()
        let compileEvidence = compileEvidence
        // Evidence compilation walks the whole meeting library; keep that off
        // the main actor (the scheduler calls this from a MainActor task).
        let evidence = try await Task.detached(priority: .utility) {
            try compileEvidence(target, root)
        }.value
        try Task.checkCancellation()
        guard evidence.dayKey == target.dayKey else {
            throw TargetError.dayKeyMismatch(expected: target.dayKey, actual: evidence.dayKey)
        }

        let memory = try store.loadMemory() ?? DreamMemory(updatedAt: now())
        // A missing/corrupt historical report may need regeneration after
        // later days have already advanced durable memory. Rebuild that report
        // from its own evidence, but never replay an older synthesis over newer
        // project/goal/pattern state.
        let durableDayWatermark = [memory.lastDreamDay, store.latestReport()?.day]
            .compactMap { $0 }
            .max()
        let advancesMemory = durableDayWatermark.map { $0 <= evidence.dayKey } ?? true
        let contextMemory = advancesMemory
            ? memory
            : DreamMemory(updatedAt: target.day)
        var report: DreamReport
        var updatedMemory = memory
        var provenance = DreamMemory(updatedAt: now()).provenance(
            adding: evidence.sources, revision: revision)

        if evidence.isSubstantivelyEmpty {
            // Nothing happened that day. Don't wake a model to say so — write
            // the deterministic stub through the same save path so the day is
            // durably marked dreamed and catch-up moves on. Memory carries
            // forward untouched.
            report = DreamCompiler.fallbackReport(
                from: evidence, generatedAt: now(),
                reason: .emptyDay,
                note: "Nothing substantive was recorded, so there is no retrospective.", language: language)
        } else {
            do {
                let selection = try await makeEngine()
                try Task.checkCancellation()
                let output = try await Self.generateSynthesis(
                    engine: selection.engine, evidence: evidence, memory: contextMemory, language: language)
                try Task.checkCancellation()
                if let synthesis = DreamPrompts.parse(output) {
                    provenance = contextMemory.provenance(adding: evidence.sources, revision: revision)
                    report = synthesis.report(dayKey: evidence.dayKey,
                                              generatedAt: now(),
                                              engineName: selection.engine.displayName,
                                              inferenceProvenance: selection.provenance,
                                              actionThreadIDs: evidence.openActionThreadIDs)
                    if advancesMemory {
                        updatedMemory = memory.merging(synthesis.memory,
                                                       dreamDay: evidence.dayKey,
                                                       at: now(),
                                                       calendar: target.calendar,
                                                       provenance: provenance)
                    }
                } else {
                    lokalbotLog("dreaming: model reply was unparseable, writing evidence-only brief")
                    report = DreamCompiler.fallbackReport(
                        from: evidence, generatedAt: now(),
                        reason: .unparseableResponse,
                        note: "The model's reply could not be read, so this brief lists evidence only.", language: language)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TextEngineError
                        where error.isRetryable && target.isAutomatic
                            && target.transientFailures < DreamScheduler.transientAttemptsBeforeFallback - 1 {
                // A rate limit or dropped connection is not a broken backend.
                // Leave the day undreamed so the scheduler retries after its
                // backoff instead of keeping an evidence-only brief for good.
                lokalbotLog("dreaming: deferred after transient error day=\(target.dayKey) "
                    + "attempt=\(target.transientFailures + 1) error=\(error.localizedDescription)")
                throw Deferred(underlying: error)
            } catch {
                // Engine unavailable (no model prepared, server down, remote origin
                // unapproved…) or still failing after retries. Still deliver the
                // morning surface — evidence only, memory untouched — and mark the
                // day done so the scheduler doesn't hammer a broken backend all
                // night. "Dream now" can redo the day.
                lokalbotLog("dreaming: engine unavailable, writing evidence-only brief error=\(error.localizedDescription)")
                report = DreamCompiler.fallbackReport(
                    from: evidence, generatedAt: now(),
                    reason: .engineUnavailable,
                    note: "No model was reachable overnight, so this brief lists evidence only.", language: language)
            }
        }

        report.evidenceProvenance = provenance
        report = report.redacted()
        try Task.checkCancellation()
        if advancesMemory {
            updatedMemory.lastDreamDay = evidence.dayKey
            updatedMemory.updatedAt = now()
            updatedMemory = updatedMemory.redacted()
            try store.saveGenerated(report: report, memory: updatedMemory, basedOnRevision: revision)
        } else {
            try store.saveGenerated(report: report, memory: nil, basedOnRevision: revision)
        }
        return report
    }

    /// Output allowance for the retrospective plus memory update. Visible
    /// replies run about 1–2K tokens; without a cap a reasoning model on a
    /// remote server spent 4–27K hidden tokens and up to eight minutes per day.
    static let maxOutputTokens = 4_096
    static let reasoningBudgetTokens = 1_024
    static let truncationRetryOutputTokens = 6_144

    /// The model ran out of room: retry once with thinking off and more room
    /// for the visible JSON, as the day digest does.
    static func generateSynthesis(engine: TextEngine, evidence: DreamEvidence,
                                  memory: DreamMemory, language: DailySummaryLanguage = .english) async throws -> String {
        let system = language.system(DreamPrompts.system)
        let prompt = DreamPrompts.prompt(evidence: evidence)
        let context = DreamPrompts.context(evidence: evidence, memory: memory)
        do {
            return try await engine.generate(
                system: system, prompt: prompt, context: context,
                schema: DreamPrompts.schema,
                options: TextGenerationOptions(maxTokens: maxOutputTokens,
                                               reasoningBudgetTokens: reasoningBudgetTokens,
                                               temperature: 0.2))
        } catch TextEngineError.outputTruncated {
            lokalbotLog("dreaming: reply hit the output limit, retrying without reasoning")
            return try await engine.generate(
                system: system, prompt: prompt, context: context,
                schema: DreamPrompts.schema,
                options: TextGenerationOptions(maxTokens: truncationRetryOutputTokens,
                                               reasoningBudgetTokens: 0,
                                               temperature: 0))
        }
    }

    /// A transient failure the scheduler retries after its backoff, quietly:
    /// it is not a user-facing error and the day stays undreamed.
    struct Deferred: LocalizedError {
        let underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }

    private enum TargetError: LocalizedError {
        case dayKeyMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case let .dayKeyMismatch(expected, actual):
                return "Dream evidence day \(actual) did not match scheduled day \(expected)."
            }
        }
    }
}
