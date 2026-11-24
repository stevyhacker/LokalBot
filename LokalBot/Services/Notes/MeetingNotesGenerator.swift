import CryptoKit
import Foundation

enum MeetingNotesGenerator {
    struct Result {
        var claims: [SummaryClaimEvidence.Claim]
        var outcomes: MeetingOutcomes
        var body: String
    }

    struct Incomplete: LocalizedError {
        var completed: Int
        var total: Int
        var errorDescription: String? {
            "Partial notes saved (\(completed) of \(total) parts source-linked). Summarize again to continue."
        }
    }

    struct Part: Codable {
        var claims: [SummaryClaimEvidence.Claim] = []
        var outcomes = MeetingOutcomes()
        var complete = false
        var recovery: Recovery?
    }
    private struct Checkpoint: Codable {
        var version = 2
        var fingerprint: String
        var parts: [String: Part] = [:]
    }

    static func checkpointURL(in folder: URL) -> URL { folder.appendingPathComponent("notes.parts.partial.json") }

    static func removeCheckpoint(in folder: URL) {
        for file in ["notes.parts.partial.json", "summary.partial.md", "outcomes.partial.json", MeetingNotesPartial.fileName] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }

    static func systemPrompt(template: NoteTemplate, language: SummaryLanguage) -> String {
        PromptTemplates.meetingNotesSystem(template: template, language: language)
    }

    static func tokenCount(_ text: String, engine: TextEngine) async throws -> Int {
        try await promptSize(text, engine: engine).upperBound
    }

    private struct PromptSize {
        var upperBound: Int
        var planningEstimate: Int
    }

    private static func promptSize(_ text: String, engine: TextEngine) async throws -> PromptSize {
        let started = ProcessInfo.processInfo.systemUptime
        let native = try await engine.tokenCount(text)
        await MeetingGenerationBudget.current?.recordPhase("tokenization", seconds: ProcessInfo.processInfo.systemUptime - started)
        let bytes = text.utf8.count
        return PromptSize(upperBound: max(1, native ?? bytes),
                          planningEstimate: max(1, native ?? ((bytes + 2) / 3)))
    }

    static func prompt(units: [MeetingNotesEvidence.Unit], roster: String) -> String {
        let commitments = Array(Set(units.filter(\.isUserCommitment).map(\.source))).sorted()
        let priority = commitments.isEmpty ? "" : "\nExplicit user commitments: \(commitments.joined(separator: ", ")). "
            + "Include these actions; use nearby context to resolve what the user accepted.\n"
        return "Speaker roster: \(roster)\(priority)\nEvidence rows are source|speaker|spoken text:\n"
            + units.map(\.line).joined(separator: "\n")
    }

    static func makeChunks(evidence: MeetingNotesEvidence, engine: TextEngine, system: String,
                           context: [String], contextTokens: Int,
                           template: NoteTemplate = .meeting) async throws -> [[MeetingNotesEvidence.Unit]] {
        guard !evidence.units.isEmpty else { return [] }
        let contextCeiling = contextTokens - 4_096 - 1_536
        let planningCeiling = min(MeetingSummaryGenerator.notesPartTokens(contextTokens: contextTokens), contextCeiling)
        let fixed = ([system] + context).joined(separator: "\n\n") + "\n\n"
        let enumLimit = engine.structuredOutputEnumLimit
        let speakers = Array(evidence.speakers.keys)
        var chunks: [[MeetingNotesEvidence.Unit]] = []
        var start = 0
        while start < evidence.units.count {
            try Task.checkCancellation()
            var end = evidence.units.count
            while true {
                let units = Array(evidence.units[start..<end])
                let size = try await promptSize(fixed + prompt(units: units, roster: evidence.roster), engine: engine)
                let enums = enumLimit == nil ? 0 : MeetingNotesEvidence.enumValueCount(in: MeetingNotesEvidence.schema(
                    units: units, speakers: speakers, template: template, maximumNotes: 1, maximumActions: 1))
                if size.upperBound <= contextCeiling, size.planningEstimate <= planningCeiling,
                   enumLimit.map({ enums <= $0 }) ?? true {
                    chunks.append(units); break
                }
                guard end > start + 1 else {
                    throw TextEngineError.badResponse("meeting context cannot fit the model's input allowance")
                }
                var ratio = min(Double(max(1, contextCeiling)) / Double(size.upperBound),
                                Double(max(1, planningCeiling)) / Double(size.planningEstimate))
                if let enumLimit { ratio = min(ratio, Double(enumLimit) / Double(max(1, enums))) }
                let fraction = max(0.1, min(0.9, ratio * 0.9))
                end = start + max(1, Int(Double(end - start) * fraction))
            }
            if end == evidence.units.count { break }
            start = max(start + 1, end - 2)
        }
        return chunks
    }

    static func generate(transcript: Transcript, engine: TextEngine, template: NoteTemplate,
                         language: SummaryLanguage, context: [String], contextTokens: Int,
                         meetingID: UUID, folder: URL, retryingStoppedParts: Bool = false,
                         budget: MeetingGenerationBudget = MeetingGenerationBudget()) async throws -> Result {
        if MeetingGenerationBudget.current == nil {
            do {
                let result = try await budget.run {
                    try await generate(transcript: transcript, engine: engine, template: template,
                        language: language, context: context, contextTokens: contextTokens,
                        meetingID: meetingID, folder: folder, retryingStoppedParts: retryingStoppedParts,
                        budget: budget)
                }
                await budget.saveMetrics(in: folder, outcome: "complete")
                return result
            } catch {
                await budget.saveMetrics(in: folder, outcome: "incomplete")
                throw error
            }
        }
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let system = systemPrompt(template: template, language: language)
        let chunks = try await makeChunks(evidence: evidence, engine: engine, system: system,
                                          context: context, contextTokens: contextTokens, template: template)
        let fixed = ([system] + context).joined(separator: "\n\n") + "\n\n"
        var outputScales: [Double] = []
        for chunk in chunks {
            let estimate = try await promptSize(fixed + prompt(units: chunk, roster: evidence.roster), engine: engine)
                .planningEstimate
            outputScales.append(max(1, Double(estimate) / Double(MeetingSummaryGenerator.standardNotesPartTokens)))
        }
        await budget.recordPlan(model: engine.displayName, transcriptRevision: transcript.evidenceRevision,
                                parts: chunks.count, standardParts: outputScales.reduce(0, +),
                                mayReason: engine.reasoningAllowance(for: .init(maxTokens: 4_096)) > 0)
        let fingerprintText = (["notes-v1", MeetingNotesEvidence.ownershipPolicyVersion,
                                transcript.evidenceRevision, engine.checkpointIdentity, system,
                                PromptTemplates.meetingNotesRepairSystem(language: language)]
            + context + chunks.map { prompt(units: $0, roster: evidence.roster) }).joined(separator: "\n\n")
        let fingerprint = SHA256.hash(data: Data(fingerprintText.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = checkpointURL(in: folder)
        var checkpoint = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Checkpoint.self, from: $0) }
            .flatMap { $0.version == 2 && $0.fingerprint == fingerprint ? $0 : nil }
            ?? Checkpoint(fingerprint: fingerprint)

        func save() throws {
            let encoder = JSONEncoder()
            try encoder.encode(checkpoint).write(to: url, options: .atomic)
            let result = merged(checkpoint, transcript: transcript, template: template)
            try SummaryClaimEvidence.savePartial(result.claims, transcript: transcript, in: folder)
            let complete = checkpoint.parts.values.filter(\.complete).count
            let partial = "# Partial notes — \(complete)/\(chunks.count) parts source-linked\n\n" + result.body
            try Data(partial.utf8).write(to: folder.appendingPathComponent("summary.partial.md"), options: .atomic)
            try encoder.encode(result.outcomes).write(to: folder.appendingPathComponent("outcomes.partial.json"), options: .atomic)
            try MeetingNotesPartial(transcriptRevision: transcript.evidenceRevision,
                summary: result.body, outcomes: result.outcomes, completedParts: complete,
                totalParts: chunks.count, template: template).write(in: folder)
        }

        for index in chunks.indices {
            try Task.checkCancellation()
            let key = String(index)
            if checkpoint.parts[key]?.complete == true { continue }
            let job = PartJob(evidence: evidence, units: chunks[index], engine: engine, template: template,
                language: language, context: context, contextTokens: contextTokens, meetingID: meetingID,
                number: index + 1, remainingParts: chunks.count - index, budget: budget,
                outputScale: outputScales[index], retryingStopped: retryingStoppedParts)
            try await generatePart(checkpoint.parts[key] ?? Part(), job: job) { part in
                checkpoint.parts[key] = part
                try save()
            }
        }
        let completed = checkpoint.parts.values.filter(\.complete).count
        guard completed == chunks.count else { throw Incomplete(completed: completed, total: chunks.count) }
        let scanned = merged(checkpoint, transcript: transcript, template: template)
        if let stated = evidence.statedDecisions(after: scanned.claims, template: template, meetingID: meetingID) {
            checkpoint.parts[String(chunks.count)] = Part(claims: stated.claims, outcomes: stated.outcomes, complete: true)
        }
        let result = merged(checkpoint, transcript: transcript, template: template)
        try SummaryClaimEvidence.savePartial(result.claims, transcript: transcript, in: folder)
        return result
    }

    static func request(engine: TextEngine, system: String, prompt: String, context: [String],
                        schema: [String: Any], tokens: Int, stage: String,
                        contextTokens: Int, budget: MeetingGenerationBudget, attempt: Int = 0,
                        truncationRetry: Int = 0,
                        reasoning: TaskReasoning = .modelDefault) async throws -> (content: String, truncated: Bool) {
        let input = try await tokenCount(([system] + context + [prompt]).joined(separator: "\n\n"), engine: engine) + 1_536
        guard input + tokens <= contextTokens else {
            throw TextEngineError.badResponse(
                "Notes request cannot fit the model's input allowance. Source-linked progress was saved.")
        }
        var options = TextGenerationOptions(maxTokens: tokens, reasoning: reasoning, temperature: 0,
                                            keepsTruncatedReply: true)
        if input + tokens + engine.reasoningAllowance(for: options) > contextTokens { options.reasoning = .off }
        let thinking = engine.reasoningAllowance(for: options)
        return try await MeetingGenerationBudget.$stage.withValue(stage) {
            try await MeetingGenerationBudget.$promptTokens.withValue(input) {
                let reservation = engine.accountsForGenerationRequests
                    ? nil : try await budget.reserve(input: input, output: tokens + thinking)
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    let text = try await engine.generate(system: system, prompt: prompt, context: context,
                        schema: schema, options: options)
                    if let reservation {
                        await budget.finish(reservation, metric: .init(stage: stage, outcome: "complete",
                            wallSeconds: ProcessInfo.processInfo.systemUptime - started))
                    }
                    return (text, false)
                } catch {
                    if let reservation {
                        await budget.finish(reservation, metric: .init(stage: stage,
                            outcome: error is TruncatedStructuredResponse ? "truncated" : "failed",
                            wallSeconds: ProcessInfo.processInfo.systemUptime - started))
                    }
                    if let partial = error as? TruncatedStructuredResponse {
                        if !stage.localizedCaseInsensitiveContains("repair"),
                           truncationRetry == 0,
                           let expanded = expandedStructuredOutputTokens(
                            from: tokens, input: input, contextTokens: contextTokens),
                           expanded > tokens {
                            let expandedResult: (content: String, truncated: Bool)
                            do {
                                expandedResult = try await request(
                                    engine: engine, system: system, prompt: prompt, context: context,
                                    schema: schema, tokens: expanded, stage: "expanded-" + stage,
                                    contextTokens: contextTokens, budget: budget,
                                    attempt: attempt, truncationRetry: 1, reasoning: .off)
                            } catch {
                                if Task.isCancelled || error is CancellationError { throw error }
                                return (partial.content, true)
                            }
                            if expandedResult.truncated,
                               prefersRecoverablePrefix(
                                partial.content,
                                over: expandedResult.content) {
                                return (partial.content, true)
                            }
                            return expandedResult
                        }
                        return (partial.content, true)
                    }
                    if case TextEngineError.outputTruncated = error {
                        if !stage.localizedCaseInsensitiveContains("repair"),
                           truncationRetry == 0,
                           let expanded = expandedStructuredOutputTokens(
                            from: tokens, input: input, contextTokens: contextTokens),
                           expanded > tokens {
                            do {
                                return try await request(
                                    engine: engine, system: system, prompt: prompt, context: context,
                                    schema: schema, tokens: expanded, stage: "expanded-" + stage,
                                    contextTokens: contextTokens, budget: budget,
                                    attempt: attempt, truncationRetry: 1, reasoning: .off)
                            } catch is MeetingGenerationBudget.Exhausted {
                                return ("", true)
                            }
                        }
                        return ("", true)
                    }
                    if !engine.handlesTransientRetries,
                       let delay = TextEngineRetryPolicy.delay(for: error, attempt: attempt) {
                        let waiting = ProcessInfo.processInfo.systemUptime
                        try await Task.sleep(for: .seconds(delay))
                        await budget.recordPhase("retryBackoff", seconds: ProcessInfo.processInfo.systemUptime - waiting)
                        return try await request(engine: engine, system: system, prompt: prompt, context: context,
                            schema: schema, tokens: tokens, stage: "retry-" + stage,
                            contextTokens: contextTokens, budget: budget, attempt: attempt + 1,
                            reasoning: options.reasoning)
                    }
                    throw error
                }
            }
        }
    }

    static func expandedStructuredOutputTokens(
        from tokens: Int,
        input: Int,
        contextTokens: Int
    ) -> Int? {
        guard tokens > 0 else { return nil }
        let available = contextTokens - input
        guard available > tokens else { return nil }
        return min(available, min(16_384, max(tokens * 2, 8_192)))
    }

    static func prefersRecoverablePrefix(_ first: String, over second: String) -> Bool {
        guard !first.isEmpty else { return false }
        guard !second.isEmpty else { return true }
        let keys: Set<String> = ["notes", "actions"]
        let firstRecords = CompleteJSONRecords.parse(first, keys: keys)
            .arrays.values.reduce(0) { $0 + $1.count }
        let secondRecords = CompleteJSONRecords.parse(second, keys: keys)
            .arrays.values.reduce(0) { $0 + $1.count }
        return firstRecords >= secondRecords
    }

    static func distinctClaims(_ claims: [SummaryClaimEvidence.Claim]) -> [SummaryClaimEvidence.Claim] {
        var seen = Set<String>()
        return claims.filter { seen.insert("\($0.section)|\($0.speakerID)|\(OutcomeTextSimilarity.normalized($0.text))").inserted }
    }

    static func recordValidation(_ value: MeetingNotesEvidence.Validated, stage: String,
                                 truncated: Bool, budget: MeetingGenerationBudget) async {
        let reasons = Dictionary(grouping: value.rejected, by: \.reason).mapValues(\.count)
        await budget.recordValidation(.init(stage: stage, completeEnvelope: value.complete,
            hasMore: value.hasMore, truncated: truncated, notes: value.claims.count,
            actions: value.outcomes.actionItems.count, rejections: reasons))
    }

    static func interleavingTLDR(_ parts: [[SummaryClaimEvidence.Claim]]) -> [SummaryClaimEvidence.Claim] {
        let takeaways = parts.map { part in part.filter { $0.section == "TL;DR" } }
        var ordered: [SummaryClaimEvidence.Claim] = []
        let rounds = takeaways.map(\.count).max() ?? 0
        for round in 0..<rounds {
            for part in takeaways where round < part.count { ordered.append(part[round]) }
        }
        for part in parts { ordered += part.filter { $0.section != "TL;DR" } }
        return ordered
    }

    private static func merged(_ checkpoint: Checkpoint, transcript: Transcript, template: NoteTemplate) -> Result {
        let parts = checkpoint.parts.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { checkpoint.parts[$0] }
        let claims = distinctClaims(interleavingTLDR(parts.map(\.claims)))
        var outcomes = MeetingOutcomesGenerator.merge(parts.map(\.outcomes)).prioritizingActionItems()
        outcomes.transcriptRevision = transcript.evidenceRevision
        var renderedClaims = claims
        if !claims.contains(where: { $0.section == "TL;DR" }) {
            let overview = overviewClaims(claims, outcomes: outcomes)
                .map { claim in var value = claim; value.section = "TL;DR"; return value }
            renderedClaims = overview + claims
        }
        let body = MeetingSummaryOutcomeSynchronizer.synchronize(
            SummaryClaimEvidence.render(renderedClaims, transcript: transcript, template: template), outcomes: outcomes, template: template)
        return Result(claims: claims, outcomes: outcomes, body: body)
    }

    static func overviewClaims(_ claims: [SummaryClaimEvidence.Claim], outcomes: MeetingOutcomes) -> [SummaryClaimEvidence.Claim] {
        let userSources = Set(outcomes.userActionItems.flatMap { $0.citations.map(\.segmentID) })
        let actionSources = Set(outcomes.actionItems.flatMap { $0.citations.map(\.segmentID) })
        let facts = claims.filter { !["TL;DR", "Open questions"].contains($0.section) }
        var candidates = facts.filter { userSources.contains($0.segmentID) }
        candidates += facts.filter { $0.section == "Decisions" }
        candidates += facts.filter { actionSources.contains($0.segmentID) }
        if !facts.isEmpty { candidates += [facts[0], facts[facts.count / 2], facts[facts.count - 1]] }
        candidates += facts
        var sources = Set<String>()
        var texts = Set<String>()
        return Array(candidates.filter { claim in
            let text = OutcomeTextSimilarity.normalized(claim.text)
            guard !sources.contains(claim.segmentID), !texts.contains(text) else { return false }
            sources.insert(claim.segmentID)
            texts.insert(text)
            return true
        }.prefix(3))
    }
}
