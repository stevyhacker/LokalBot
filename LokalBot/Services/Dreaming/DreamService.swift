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
        guard try store.evidenceRevision() == revision else { throw CancellationError() }
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
                note: "Nothing substantive was recorded, so there is no retrospective.")
        } else {
            do {
                let selection = try await makeEngine()
                try Task.checkCancellation()
                guard try store.evidenceRevision() == revision else { throw CancellationError() }
                let output = try await selection.engine.generate(
                    system: DreamPrompts.system,
                    prompt: DreamPrompts.prompt(evidence: evidence),
                    context: DreamPrompts.context(evidence: evidence, memory: contextMemory),
                    schema: DreamPrompts.schema)
                try Task.checkCancellation()
                if let synthesis = DreamPrompts.parse(output) {
                    provenance = contextMemory.provenance(adding: evidence.sources, revision: revision)
                    report = synthesis.report(dayKey: evidence.dayKey,
                                              generatedAt: now(),
                                              engineName: selection.engine.displayName,
                                              inferenceProvenance: selection.provenance)
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
                        note: "The model's reply could not be read, so this brief lists evidence only.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Engine unavailable (no model prepared, server down, remote origin
                // unapproved…). Still deliver the morning surface — evidence only,
                // memory untouched — and mark the day done so the scheduler doesn't
                // hammer a broken backend all night. "Dream now" can redo the day.
                lokalbotLog("dreaming: engine unavailable, writing evidence-only brief error=\(error.localizedDescription)")
                report = DreamCompiler.fallbackReport(
                    from: evidence, generatedAt: now(),
                    reason: .engineUnavailable,
                    note: "No model was reachable overnight, so this brief lists evidence only.")
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
