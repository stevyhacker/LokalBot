import Foundation

/// What one night's synthesis proposed: the retrospective sections plus the
/// full updated memory lists. Pure data — `DreamService` turns it into a
/// `DreamReport` and merges the memory update deterministically.
struct DreamSynthesis: Equatable {
    var narrative: String
    var attention: [String]
    var repeatedWork: [String]
    var suggestedChecks: [String]
    var frictions: [String]
    var topActions: [String]
    var memory: DreamMemoryUpdate

    var isEmpty: Bool {
        narrative.isEmpty && attention.isEmpty && repeatedWork.isEmpty
            && suggestedChecks.isEmpty && frictions.isEmpty && topActions.isEmpty
            && memory.isEmpty
    }

    func report(dayKey: String, generatedAt: Date, engineName: String,
                inferenceProvenance: DreamInferenceProvenance,
                actionThreadIDs: [String] = []) -> DreamReport {
        let linked = DreamPrompts.linkTopActions(topActions, threadIDs: actionThreadIDs)
        return DreamReport(
            day: dayKey,
            generatedAt: generatedAt,
            engineName: engineName,
            inferenceProvenance: inferenceProvenance,
            narrative: narrative,
            attention: attention,
            repeatedWork: repeatedWork,
            suggestedChecks: suggestedChecks,
            frictions: frictions,
            topActions: linked.texts,
            topActionThreadIDs: linked.ids.contains { $0 != nil } ? linked.ids : nil)
    }
}

/// Prompt, JSON schema, and tolerant parsing for the overnight dream pass.
/// Same split as `OutcomesExtractor`: grammar-constrained backends get the
/// schema, unconstrained ones rely on the prompt's shape plus the tolerant
/// parse, and everything here is pure so it tests without an engine.
enum DreamPrompts {
    static let maxListItems = 8
    static let maxTopActions = 3
    static let maxLineCharacters = 400

    static let system = """
    You are LokalBot's overnight "dreaming" pass: a read-only retrospective of \
    the user's previous local calendar day, computed entirely on their Mac. You \
    receive that day's evidence (meetings with extracted outcomes, the day \
    digest, app-time totals, saved moments), up to 14 preceding days as a \
    comparison window only, and the current structured work memory. Reply with \
    ONLY a JSON object of this exact shape:
    {"narrative": "...", "attention": ["..."], "repeated_work": ["..."], \
    "suggested_checks": ["..."], "frictions": ["..."], "top_actions": ["..."], \
    "active_projects": [{"name": "...", "status": "...", "evidence": ["..."]}], \
    "work_goals": [{"text": "...", "horizon": "...", "reinforced_today": true, \
    "expired": false}], \
    "recurring_patterns": ["..."]}

    Rules:
    - Analysis and recommendations only. You changed nothing and must never claim otherwise.
    - Distinguish verified facts from inference: prefix inferred items with "Likely:".
    - Cite meeting IDs in backticks exactly as given in the evidence. Never invent \
    activity, names, numbers, or meetings.
    - The app displays each cited ID as a clickable meeting title. Do not repeat \
    the meeting title immediately before its ID. Use natural ownership wording \
    such as "your actions" or "actions assigned to you"; never copy internal \
    metadata labels such as owner:me, owner:, due:, or sources: into the prose.
    - narrative: 1-2 natural sentences on how yesterday actually went. Use \
    "yesterday", never a raw ISO date. Write directly; never say "the user" or use \
    the person's name as the subject. Do not mention whether goals, evidence, or \
    metadata were recorded. If little happened, keep the narrative short.
    - attention: critical issues or regressions deserving attention first, most \
    severe first, each with its evidence.
    - repeated_work: manual work that recurred and could be automated further.
    - suggested_checks: recurring review tasks worth adopting where the evidence \
    shows regressions, each with a suggested cadence.
    - frictions: quality or UX improvements suggested by rework, confusion, weak \
    validation, or friction in the day's work.
    - top_actions: the top three actions to consider today, ranked by expected \
    leverage. At most three. Every action must follow from explicit unresolved work, \
    a blocker, or a concrete friction in the evidence; never invent generic productivity advice. \
    When a top action is one of the action candidates, begin it with that candidate's \
    handle exactly as shown, such as "[A2] ", so the app can link it to the recorded action.
    - active_projects, work_goals, recurring_patterns: return the FULL updated \
    memory. Update statuses from the day's evidence, add new entries only with \
    clear evidence, keep entries you still believe active even if untouched \
    today, and drop an entry only when the evidence shows it finished.
    - Every work goal must include reinforced_today. Set it to true only when \
    evidence from the analyzed day directly reinforces that goal. Set it to \
    false when carrying a goal forward solely from current memory. Never infer \
    reinforcement from the goal's presence in current memory or the comparison window.
    - Set "expired": true on a work goal only when the analyzed day's evidence \
    shows it was completed or abandoned; it is then removed from memory. A goal \
    merely absent from the day is not expired — omit the field or set false.
    - recurring_patterns is always the complete current list. Return [] when no \
    recurring patterns remain; an empty list intentionally clears stored patterns.
    - Keep every string to one short sentence. Use empty arrays when nothing \
    qualifies — generic advice is worse than an empty list.
    """

    /// JSON schema matching `system`'s shape for grammar-constrained backends.
    static var schema: [String: Any] {
        let stringList: [String: Any] = ["type": "array", "items": ["type": "string"]]
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "narrative": ["type": "string"],
                "attention": stringList,
                "repeated_work": stringList,
                "suggested_checks": stringList,
                "frictions": stringList,
                "top_actions": stringList,
                "active_projects": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "name": ["type": "string"],
                            "status": ["type": "string"],
                            "evidence": stringList,
                        ],
                        "required": ["name", "status", "evidence"],
                    ],
                ],
                "work_goals": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "text": ["type": "string"],
                            "horizon": ["type": "string"],
                            "reinforced_today": ["type": "boolean"],
                            "expired": ["type": "boolean"],
                        ],
                        // Strict structured outputs require every declared
                        // property. The prompt tells the model to return false
                        // when the goal is still active.
                        "required": ["text", "horizon", "reinforced_today", "expired"],
                    ],
                ],
                "recurring_patterns": stringList,
            ],
            "required": ["narrative", "attention", "repeated_work", "suggested_checks",
                         "frictions", "top_actions", "active_projects", "work_goals",
                         "recurring_patterns"],
        ]
    }

    static func prompt(evidence: DreamEvidence) -> String {
        "Conduct the retrospective of \(evidence.dayKey) from this evidence:\n\n"
            + DreamCompiler.evidencePack(evidence)
    }

    static func context(evidence: DreamEvidence, memory: DreamMemory) -> [String] {
        var context = [
            "Analyzed local day: \(evidence.dayKey)",
        ]
        if memory.isEmpty {
            context.append("Current structured work memory: empty — this is the first dream.")
        } else {
            context.append("Current structured work memory:\n"
                + PromptContextSanitizer.sanitize(memory.markdown(), maxCharacters: 6_000))
        }
        return context
    }

    /// Tolerant extraction of the model's JSON object followed by strict typed
    /// decoding. Every declared field must be present with the right type and
    /// every supplied string must remain meaningful after cleanup. Hard caps
    /// keep a rambling but otherwise valid model from oversizing artifacts.
    /// Nil sends the service down the deterministic fallback path.
    static func parse(_ output: String) -> DreamSynthesis? {
        guard let json = ChatPrompt.extractJSONObject(strippingReasoning(output)),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let narrative = cleaned(payload.narrative, cap: 1_200),
              let attention = cleanedList(payload.attention),
              let repeatedWork = cleanedList(payload.repeatedWork),
              let suggestedChecks = cleanedList(payload.suggestedChecks),
              let frictions = cleanedList(payload.frictions),
              let topActions = cleanedList(payload.topActions),
              let recurringPatterns = cleanedList(payload.recurringPatterns) else {
            return nil
        }

        var projects: [DreamMemoryUpdate.Project] = []
        for project in payload.activeProjects {
            guard let name = cleaned(project.name),
                  let status = cleaned(project.status),
                  let evidence = cleanedList(project.evidence) else { return nil }
            projects.append(DreamMemoryUpdate.Project(
                name: name,
                status: status,
                evidence: Array(evidence.prefix(DreamMemory.maxEvidencePerProject))))
        }

        var goals: [DreamMemoryUpdate.Goal] = []
        for goal in payload.workGoals {
            guard let text = cleaned(goal.text),
                  let horizon = cleaned(goal.horizon) else { return nil }
            goals.append(DreamMemoryUpdate.Goal(
                text: text,
                horizon: horizon,
                reinforcedToday: goal.reinforcedToday,
                expired: goal.expired ?? false))
        }

        let synthesis = DreamSynthesis(
            narrative: narrative,
            attention: Array(attention.prefix(maxListItems)),
            repeatedWork: Array(repeatedWork.prefix(maxListItems)),
            suggestedChecks: Array(suggestedChecks.prefix(maxListItems)),
            frictions: Array(frictions.prefix(maxListItems)),
            topActions: Array(topActions.prefix(maxTopActions)),
            memory: DreamMemoryUpdate(
                activeProjects: Array(projects.prefix(DreamMemory.maxProjects)),
                workGoals: Array(goals.prefix(DreamMemory.maxGoals)),
                recurringPatterns: Array(
                    recurringPatterns.prefix(DreamMemory.maxPatterns))))
        return synthesis.isEmpty ? nil : synthesis
    }

    private struct Payload: Decodable {
        struct Project: Decodable {
            let name: String
            let status: String
            let evidence: [String]
        }

        struct Goal: Decodable {
            let text: String
            let horizon: String
            let reinforcedToday: Bool
            let expired: Bool?

            enum CodingKeys: String, CodingKey {
                case text
                case horizon
                case reinforcedToday = "reinforced_today"
                case expired
            }
        }

        let narrative: String
        let attention: [String]
        let repeatedWork: [String]
        let suggestedChecks: [String]
        let frictions: [String]
        let topActions: [String]
        let activeProjects: [Project]
        let workGoals: [Goal]
        let recurringPatterns: [String]

        enum CodingKeys: String, CodingKey {
            case narrative
            case attention
            case repeatedWork = "repeated_work"
            case suggestedChecks = "suggested_checks"
            case frictions
            case topActions = "top_actions"
            case activeProjects = "active_projects"
            case workGoals = "work_goals"
            case recurringPatterns = "recurring_patterns"
        }
    }

    /// Strips candidate handles ("[A2] …") from top actions and maps each to
    /// its action thread. Unknown or out-of-range handles are removed without
    /// inventing a link; duplicates keep only their first link.
    static func linkTopActions(_ actions: [String], threadIDs: [String]) -> (texts: [String], ids: [String?]) {
        var texts: [String] = []
        var ids: [String?] = []
        var used = Set<String>()
        let pattern = #"^\s*\[A(\d{1,3})\]\s*[:\-–—]?\s*"#
        for action in actions {
            var text = action
            var id: String?
            if let range = action.range(of: pattern, options: .regularExpression) {
                let digits = action[range].filter(\.isNumber)
                text = String(action[range.upperBound...])
                if let handle = Int(digits), threadIDs.indices.contains(handle - 1),
                   used.insert(threadIDs[handle - 1]).inserted {
                    id = threadIDs[handle - 1]
                }
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            texts.append(trimmed.isEmpty ? action : trimmed)
            ids.append(id)
        }
        return (texts, ids)
    }

    private static func cleanedList(_ values: [String]) -> [String]? {
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let cleaned = cleaned(value) else { return nil }
            result.append(cleaned)
        }
        return result
    }

    private static func cleaned(_ raw: String, cap: Int = maxLineCharacters) -> String? {
        let collapsed = raw.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > cap ? String(collapsed.prefix(cap)) + "…" : collapsed
    }
}
