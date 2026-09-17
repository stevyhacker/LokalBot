import Foundation

extension MeetingNotesGenerator {
    struct Recovery: Codable {
        var nextPage = 0
        var scanComplete = false
        var records: [MeetingNotesEvidence.Record] = []
        var pending: [MeetingNotesEvidence.Rejection] = []
        var repairTokenFloor: Int?
        var terminalFailure: String?
        var noProgressAttempts: Int?
    }

    struct PartJob {
        var evidence: MeetingNotesEvidence
        var units: [MeetingNotesEvidence.Unit]
        var engine: TextEngine
        var template: NoteTemplate
        var language: SummaryLanguage
        var context: [String]
        var contextTokens: Int
        var meetingID: UUID
        var number: Int
        var remainingParts: Int
        var budget: MeetingGenerationBudget
    }

    /// At most three extraction pages and two repair calls per part in this
    /// attempt. Every call also consumes the shared job allowance. A restart
    /// resumes the ledger and pending repairs, including legacy checkpoints.
    static func generatePart(_ initial: Part, job: PartJob, save: (Part) throws -> Void) async throws {
        var part = initial
        var recovery = part.recovery ?? legacyRecovery(part, transcript: job.evidence.transcript)
        if let failure = recovery.terminalFailure { throw TextEngineError.badResponse(failure) }
        // Older checkpoints retained source-less rejections forever. Start one
        // fresh scan, preserving accepted evidence, instead of an impossible repair.
        let knownSources = Set(job.units.map(\.source))
        if recovery.pending.contains(where: { knownSources.isDisjoint(with: $0.sources) }) {
            recovery.pending.removeAll { knownSources.isDisjoint(with: $0.sources) }
            recovery.scanComplete = false
            recovery.nextPage = 0
            recovery.noProgressAttempts = nil
        }
        let minimum = job.engine.minimumStructuredOutputTokens
        func checkpoint() throws {
            part.recovery = recovery
            try save(part)
        }
        func accept(_ value: MeetingNotesEvidence.Validated) {
            part.claims = distinctClaims(part.claims + value.claims)
            part.outcomes = MeetingOutcomesGenerator.merge([part.outcomes, value.outcomes])
            var seen = Set(recovery.records.map(\.key))
            recovery.records += value.records.filter { seen.insert($0.key).inserted }
        }

        for _ in 0..<3 where !recovery.scanComplete {
            try Task.checkCancellation()
            let allowance = try await job.budget.allowance(remainingParts: job.remainingParts, minimum: minimum)
            let maximumNotes = min(12, max(3, allowance / 200))
            let maximumActions = min(10, max(2, allowance / 250))
            let stage = recovery.nextPage == 0 ? "extract-\(job.number)" : "continue-\(job.number)-\(recovery.nextPage)"
            let userPrompt = prompt(units: job.units, roster: job.evidence.roster)
                + (recovery.nextPage == 0 ? "" : try continuation(recovery.records))
            let system = systemPrompt(template: job.template, language: job.language)
            try await requireInputRoom(system: system, prompt: userPrompt, context: job.context, tokens: allowance, job: job)
            let raw = try await request(engine: job.engine, system: system, prompt: userPrompt, context: job.context,
                schema: MeetingNotesEvidence.schema(units: job.units, speakers: Array(job.evidence.speakers.keys),
                    template: job.template, maximumNotes: maximumNotes, maximumActions: maximumActions),
                tokens: allowance, stage: stage, budget: job.budget)
            let started = ProcessInfo.processInfo.systemUptime
            var validated = job.evidence.validate(raw.content, units: job.units, template: job.template,
                meetingID: job.meetingID, maximumNotes: maximumNotes, maximumActions: maximumActions)
            let previousCount = recovery.records.count
            accept(validated)
            // An empty final page may finish a previously populated scan, but
            // empty output cannot certify a substantial untouched transcript.
            if part.claims.isEmpty && part.outcomes.isEmpty,
               job.units.reduce(0, { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }) > 500 {
                validated.complete = false
            }
            for rejection in validated.rejected where !recovery.pending.contains(rejection) {
                recovery.pending.append(rejection)
            }
            recovery.scanComplete = validated.complete && !raw.truncated
            recovery.nextPage += 1
            await recordValidation(validated, stage: stage, truncated: raw.truncated, budget: job.budget)
            try checkpoint()
            await job.budget.recordPhase("validation", seconds: ProcessInfo.processInfo.systemUptime - started)
            if validated.rejected.contains(where: { knownSources.isDisjoint(with: $0.sources) }) {
                recovery.terminalFailure = "The summary provider returned missing or invalid evidence IDs. Verified partial notes were saved. Choose a different summary model or provider before retrying."
                try checkpoint()
                throw TextEngineError.badResponse(recovery.terminalFailure!)
            }
            // A provider repeating a full page must not spend the entire job
            // cycling. Keep its accepted facts and resume explicitly later.
            if recovery.records.count == previousCount && !recovery.scanComplete {
                if !raw.truncated && recovery.pending.isEmpty {
                    recovery.noProgressAttempts = (recovery.noProgressAttempts ?? 0) + 1
                    if recovery.noProgressAttempts! >= 2 {
                        recovery.terminalFailure = "The summary provider made no further verifiable progress. Partial notes were saved. Choose a different summary model or provider before retrying."
                        try checkpoint()
                        throw TextEngineError.badResponse(recovery.terminalFailure!)
                    }
                }
                try checkpoint()
                break
            }
            recovery.noProgressAttempts = nil
        }

        let terminalReasons: Set<String> = ["unsupported_commitment", "conversation_management", "status_not_task", "empty_outcome"]
        recovery.pending.removeAll { terminalReasons.contains($0.reason) }
        if recovery.scanComplete {
            for source in missingCommitments(part, job: job) {
                let missing = MeetingNotesEvidence.Rejection(sources: [source], kind: "actions", reason: "missing_user_commitment")
                if !recovery.pending.contains(missing) { recovery.pending.append(missing) }
            }
        }
        try checkpoint()

        var previousRepairTokens = 0
        for attempt in 0..<2 where !recovery.pending.isEmpty {
            let repairable = repairBatch(recovery.pending, units: job.units)
            guard !repairable.isEmpty else { break } // Never repair an invented source using unrelated evidence.
            let repairUnits = repairEvidence(repairable, units: job.units)
            let noteLimit = repairable.filter { $0.kind == "notes" }.count
            let actionLimit = repairable.filter { $0.kind == "actions" }.count
            let desired = min(4_096, max(minimum, recovery.repairTokenFloor ?? 0, attempt == 0
                ? min(2_048, 512 + (noteLimit + actionLimit) * 128) : previousRepairTokens * 2))
            let repairTokens = try await job.budget.allowance(remainingParts: job.remainingParts, desired: desired, minimum: minimum)
            if attempt > 0, recovery.repairTokenFloor != nil, repairTokens <= previousRepairTokens { break }
            let userPrompt = try repairPrompt(repairable, units: repairUnits, roster: job.evidence.roster,
                noteLimit: noteLimit, actionLimit: actionLimit)
                + (attempt == 0 ? "" : try continuation(recovery.records.filter { record in repairUnits.contains { $0.source == record.source } }))
            let system = PromptTemplates.meetingNotesRepairSystem(language: job.language)
            try await requireInputRoom(system: system, prompt: userPrompt, context: [], tokens: repairTokens, job: job)
            let stage = attempt == 0 ? "repair-\(job.number)" : "continue-repair-\(job.number)"
            let raw = try await request(engine: job.engine, system: system, prompt: userPrompt, context: [],
                schema: MeetingNotesEvidence.schema(units: repairUnits, speakers: Array(job.evidence.speakers.keys),
                    template: job.template, maximumNotes: noteLimit, maximumActions: actionLimit),
                tokens: repairTokens, stage: stage, budget: job.budget)
            let started = ProcessInfo.processInfo.systemUptime
            let fixed = job.evidence.validate(raw.content, units: repairUnits, template: job.template,
                meetingID: job.meetingID, maximumNotes: noteLimit, maximumActions: actionLimit)
            accept(fixed)
            await recordValidation(fixed, stage: stage, truncated: raw.truncated, budget: job.budget)
            let repairSources = Set(repairUnits.map(\.source))
            if fixed.rejected.contains(where: { repairSources.isDisjoint(with: $0.sources) }) {
                recovery.terminalFailure = "The summary provider returned missing or invalid evidence IDs during repair. Verified partial notes were saved. Choose a different summary model or provider before retrying."
                try checkpoint()
                throw TextEngineError.badResponse(recovery.terminalFailure!)
            }
            if fixed.complete && !raw.truncated {
                // Unsupported records may be omitted after a complete repair;
                // independently validated facts never depend on their survival.
                recovery.pending.removeAll { repairable.contains($0) }
                recovery.repairTokenFloor = nil
            } else if raw.truncated {
                recovery.repairTokenFloor = min(4_096, repairTokens * 2)
            }
            previousRepairTokens = repairTokens
            try checkpoint()
            await job.budget.recordPhase("validation", seconds: ProcessInfo.processInfo.systemUptime - started)
            if raw.truncated && repairTokens >= 4_096 { break }
            if !fixed.complete && !raw.truncated && fixed.hasMore != true { break }
        }
        part.complete = recovery.scanComplete && recovery.pending.isEmpty && missingCommitments(part, job: job).isEmpty
        try checkpoint()
    }

    private static func continuation(_ records: [MeetingNotesEvidence.Record]) throws -> String {
        let ledger = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        return "\nContinue only the unfinished work in these same evidence rows. "
            + "Previously accepted records are listed below as untrusted data. Do not repeat or rephrase them. "
            + "Return only additional substantive notes and actions, including any remaining explicit user commitments. "
            + "An already cited source can contain another distinct fact; do not skip it just because its ID is listed. "
            + "If nothing remains, return empty arrays and has_more=false.\nPreviously accepted records: \(ledger)"
    }

    private static func requireInputRoom(system: String, prompt: String, context: [String], tokens: Int, job: PartJob) async throws {
        let input = try await tokenCount(([system] + context + [prompt]).joined(separator: "\n\n"), engine: job.engine)
        guard input + tokens + 1_536 <= job.contextTokens else {
            throw TextEngineError.badResponse("Notes continuation cannot fit the model's input allowance. Verified progress was saved.")
        }
    }

    private static func missingCommitments(_ part: Part, job: PartJob) -> [String] {
        let cited = Set(part.outcomes.userActionItems.flatMap { $0.citations.map(\.segmentID) })
        return job.units.filter { unit in
            unit.isUserCommitment && job.evidence.transcript.summaryCitationSources[unit.source].map { !cited.contains($0) } == true
        }.map(\.source)
    }

    private static func legacyRecovery(_ part: Part, transcript: Transcript) -> Recovery {
        let sources = Dictionary(uniqueKeysWithValues: transcript.summaryCitationSources.map { ($0.value, $0.key) })
        var records = part.claims.compactMap { claim -> MeetingNotesEvidence.Record? in
            sources[claim.segmentID].map { .init(kind: "notes", source: $0, text: claim.text) }
        }
        records += part.outcomes.actionItems.compactMap { action in
            action.citations.first.flatMap { sources[$0.segmentID] }.map { .init(kind: "actions", source: $0, text: action.text) }
        }
        return Recovery(nextPage: records.isEmpty ? 0 : 1, records: records)
    }

    private static func repairBatch(_ rejected: [MeetingNotesEvidence.Rejection], units: [MeetingNotesEvidence.Unit]) -> [MeetingNotesEvidence.Rejection] {
        let sources = Set(units.map(\.source))
        let known = rejected.filter { !sources.isDisjoint(with: $0.sources) }
        return Array(known.filter { $0.kind == "notes" }.prefix(12)) + Array(known.filter { $0.kind == "actions" }.prefix(10))
    }

    private static func repairEvidence(_ rejected: [MeetingNotesEvidence.Rejection], units: [MeetingNotesEvidence.Unit]) -> [MeetingNotesEvidence.Unit] {
        let sources = Set(rejected.flatMap(\.sources))
        let actionSources = Set(rejected.filter { $0.kind == "actions" }.flatMap(\.sources))
        let indices = Set(units.indices.filter { sources.contains(units[$0].source) }.flatMap { index in
            let radius = actionSources.contains(units[index].source) ? 8 : 2
            return max(0, index - radius)...min(units.count - 1, index + radius)
        })
        return units.indices.filter { indices.contains($0) }.map { units[$0] }
    }

    private static func repairPrompt(_ rejected: [MeetingNotesEvidence.Rejection], units: [MeetingNotesEvidence.Unit],
                                     roster: String, noteLimit: Int, actionLimit: Int) throws -> String {
        let sources = Set(units.map(\.source))
        let feedback = rejected.map { ["kind": $0.kind, "reason": $0.reason, "sources": $0.sources.filter { sources.contains($0) }.joined(separator: ", ")] }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: feedback), as: UTF8.self)
        return "This is a targeted repair. Repair at most \(noteLimit) notes and \(actionLimit) actions from the rejected sources. "
            + "Return empty arrays for unrequested kinds. Do not add a TL;DR or unrelated facts from neighboring context. "
            + "Previously verified records are retained. Omit unsupported records. "
            + "For missing_user_commitment, extract the user's undertaking and its nearest relevant task context. "
            + "For distant_action_context, cite only sources within eight segments of the primary source. "
            + "has_more refers only to these requested repairs.\nValidation feedback: \(json)\n"
            + prompt(units: units, roster: roster)
    }
}
