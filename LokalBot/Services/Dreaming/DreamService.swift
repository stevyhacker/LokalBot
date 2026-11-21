import Foundation

struct DreamService {
    typealias EngineSelection = (
        engine: TextEngine,
        provenance: DreamInferenceProvenance
    )

    var storageRoot: URL
    var makeEngine: () async throws -> EngineSelection
    var now: () -> Date = Date.init
    var compileEvidence: @Sendable (DreamScheduler.Target, URL) throws -> DreamEvidence = { target, root in
        try DreamCompiler.compile(day: target.day, storageRoot: root, calendar: target.calendar)
    }

    @discardableResult
    func dream(target: DreamScheduler.Target) async throws -> DreamReport {
        let root = storageRoot
        let store = DreamStore(root: root)
        let revision = try store.evidenceRevision()
        let compileEvidence = compileEvidence
        let evidence = try await Task.detached(priority: .utility) {
            try compileEvidence(target, root)
        }.value
        try Task.checkCancellation()
        guard evidence.dayKey == target.dayKey else {
            throw TargetError.dayKeyMismatch(expected: target.dayKey, actual: evidence.dayKey)
        }

        let memory = try store.loadMemory() ?? DreamMemory(updatedAt: now())
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
            report = DreamCompiler.fallbackReport(
                from: evidence, generatedAt: now(),
                reason: .emptyDay,
                note: "Nothing substantive was recorded, so there is no retrospective.")
        } else {
            do {
                let selection = try await makeEngine()
                try Task.checkCancellation()
                let output = try await Self.generateSynthesis(
                    engine: selection.engine, evidence: evidence, memory: contextMemory)
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
                        note: "The model's reply could not be read, so this brief lists evidence only.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TextEngineError
                        where error.isRetryable && target.isAutomatic
                            && target.transientFailures < DreamScheduler.transientAttemptsBeforeFallback - 1 {
                lokalbotLog("dreaming: deferred after transient error day=\(target.dayKey) "
                    + "attempt=\(target.transientFailures + 1) error=\(error.localizedDescription)")
                throw Deferred(underlying: error)
            } catch {
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

    static let maxOutputTokens = 4_096
    static let reasoningBudgetTokens = 1_024
    static let truncationRetryOutputTokens = 6_144

    static func generateSynthesis(engine: TextEngine, evidence: DreamEvidence,
                                  memory: DreamMemory) async throws -> String {
        let prompt = DreamPrompts.prompt(evidence: evidence)
        let context = DreamPrompts.context(evidence: evidence, memory: memory)
        do {
            return try await engine.generate(
                system: DreamPrompts.system, prompt: prompt, context: context,
                schema: DreamPrompts.schema,
                options: TextGenerationOptions(maxTokens: maxOutputTokens,
                                               reasoningBudgetTokens: reasoningBudgetTokens,
                                               temperature: 0.2))
        } catch TextEngineError.outputTruncated {
            lokalbotLog("dreaming: reply hit the output limit, retrying without reasoning")
            return try await engine.generate(
                system: DreamPrompts.system, prompt: prompt, context: context,
                schema: DreamPrompts.schema,
                options: TextGenerationOptions(maxTokens: truncationRetryOutputTokens,
                                               reasoningBudgetTokens: 0,
                                               temperature: 0))
        }
    }

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
