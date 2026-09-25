import Foundation

/// Shared "yyyy-MM-dd" day keys for dreaming artifacts — local calendar days,
/// matching the journal and daily-export file naming, and lexicographically
/// sortable so "newest report" is a filename sort.
enum DreamDay {
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromKey key: String, calendar: Calendar = .current) -> Date? {
        let pieces = key.split(separator: "-")
        guard pieces.count == 3,
              let year = Int(pieces[0]), let month = Int(pieces[1]),
              let day = Int(pieces[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }
}

/// Where the configured Main LLM processed a dream. Reports retain this
/// alongside the engine name so the morning surface can describe the actual
/// privacy boundary instead of assuming every successful engine was local.
struct DreamInferenceProvenance: Codable, Equatable, Sendable {
    enum Location: String, Codable, Equatable, Sendable {
        case local
        case remote
    }

    var location: Location
    /// Canonical scheme/host/port for approved remote inference. Paths, query
    /// strings, credentials, and API keys are deliberately never persisted.
    var origin: String?

    init(location: Location, origin: String? = nil) {
        self.location = location
        self.origin = location == .remote ? origin : nil
    }

    init(settings: AppSettings) {
        let rawURL: String?
        switch settings.summarizerBackend {
        case .builtIn, .appleIntelligence:
            self.init(location: .local)
            return
        case .ollama:
            rawURL = settings.ollamaBaseURL
        case .openAICompatible:
            rawURL = settings.openAIBaseURL
        }

        guard let rawURL, let url = URL(string: rawURL),
              InferenceEndpointPolicy.requiresApproval(url) else {
            self.init(location: .local)
            return
        }
        self.init(location: .remote, origin: InferenceEndpointPolicy.origin(for: url))
    }
}

/// Why an evidence-only brief was written. This is separate from engine
/// availability: a reachable model can still return an unreadable payload.
enum DreamFallbackReason: String, Codable, Equatable, Sendable {
    case engineUnavailable
    case unparseableResponse
    case emptyDay
}

/// App-owned dependencies of generated memory. Model-written citation text is
/// never used to decide whether deleted or corrected evidence may be retained.
struct DreamEvidenceSource: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case meeting
        case screenDay
        case digest
    }

    var kind: Kind
    /// Full meeting UUID, or the local day key for day-level derived evidence.
    var id: String
    var dayKey: String
}

struct DreamEvidenceProvenance: Codable, Equatable, Sendable {
    var sources: [DreamEvidenceSource]
    /// The durable store revision captured before gathering these sources.
    var revision: UInt64
    /// Legacy memory cannot be assigned invented source links. Any output
    /// which consumed it must also be retracted on the next evidence change.
    var includesUnattributedContext: Bool = false

    func isInvalidated(by revisions: [String: UInt64], currentRevision: UInt64,
                       meetingRevisions: [String: UInt64] = [:]) -> Bool {
        if includesUnattributedContext || sources.isEmpty {
            return revision < currentRevision
        }
        return sources.contains {
            (revisions[$0.dayKey] ?? 0) > revision
                || ($0.kind == .meeting && (meetingRevisions[$0.id.uppercased()] ?? 0) > revision)
        }
    }
}

/// One overnight retrospective of a single local calendar day. Persisted as
/// `dreams/<day>.json` (+ a rendered `.md` sibling) and shown on Today the
/// next morning. `engineName == nil` marks a deterministic evidence-only
/// fallback; `fallbackReason` records whether the engine was unavailable or
/// returned an unreadable response.
struct DreamReport: Codable, Equatable, Sendable {
    static let currentVersion = 3

    var version: Int = DreamReport.currentVersion
    /// The analyzed local calendar day ("yyyy-MM-dd"), i.e. yesterday at
    /// generation time — not the day the report is shown.
    var day: String
    var generatedAt: Date
    var engineName: String?
    /// Nil only for version-1 reports written before provenance was tracked.
    var inferenceProvenance: DreamInferenceProvenance?
    /// Nil for model-generated reports and legacy evidence-only reports.
    var fallbackReason: DreamFallbackReason?
    var evidenceProvenance: DreamEvidenceProvenance?
    var narrative: String
    /// Critical items and regressions that deserve attention first.
    var attention: [String] = []
    /// Repeated manual work that could be automated further.
    var repeatedWork: [String] = []
    /// Proposed recurring review/check tasks, each with a suggested cadence.
    var suggestedChecks: [String] = []
    /// Quality and UX friction observed in the day's work.
    var frictions: [String] = []
    /// Top actions for today, ranked by expected leverage (at most three).
    var topActions: [String] = []

    var isFallback: Bool { engineName == nil }

    /// Shared by Today and the Markdown rendering so both surfaces tell the
    /// same truth about local/remote inference and fallback cause.
    var provenanceDescription: String {
        if let engineName {
            switch inferenceProvenance?.location {
            case .local:
                return "Dreamed by \(engineName) on this Mac."
            case .remote:
                let destination = inferenceProvenance?.origin.map { " at \($0)" } ?? ""
                return "Dreamed by \(engineName) using approved remote inference\(destination). "
                    + "The report was saved in your local library."
            case nil:
                return "Dreamed by \(engineName) using your configured Think model. "
                    + "The report was saved in your local library."
            }
        }
        switch fallbackReason {
        case .engineUnavailable:
            return "No model was reachable overnight; this evidence-only brief was saved locally."
        case .unparseableResponse:
            return "The model replied, but its response could not be read; "
                + "this evidence-only brief was saved locally."
        case .emptyDay:
            return "Nothing substantive was recorded that day, so no model ran; "
                + "this placeholder just keeps the record complete."
        case nil:
            return "Written as an evidence-only fallback and saved locally."
        }
    }

    func markdown() -> String {
        var lines = ["# Morning brief — \(day)", ""]
        lines.append("_\(provenanceDescription)_")
        if !narrative.isEmpty { lines += ["", narrative] }
        appendSection("Needs attention first", attention, to: &lines)
        appendSection("Top actions today", topActions, to: &lines, numbered: true)
        appendSection("Repeated work worth automating", repeatedWork, to: &lines)
        appendSection("Suggested recurring checks", suggestedChecks, to: &lines)
        appendSection("Friction to smooth out", frictions, to: &lines)
        return lines.joined(separator: "\n")
    }

    /// Reports derive from screen text and transcripts, so the same
    /// deterministic credential scrubbing applied to exports runs before
    /// anything is persisted.
    func redacted() -> DreamReport {
        var report = self
        report.narrative = ScreenContextPrivacy.redact(narrative).text
        report.attention = attention.map { ScreenContextPrivacy.redact($0).text }
        report.repeatedWork = repeatedWork.map { ScreenContextPrivacy.redact($0).text }
        report.suggestedChecks = suggestedChecks.map { ScreenContextPrivacy.redact($0).text }
        report.frictions = frictions.map { ScreenContextPrivacy.redact($0).text }
        report.topActions = topActions.map { ScreenContextPrivacy.redact($0).text }
        return report
    }

    private func appendSection(_ title: String, _ items: [String],
                               to lines: inout [String], numbered: Bool = false) {
        guard !items.isEmpty else { return }
        lines += ["", "## \(title)", ""]
        if numbered {
            lines += items.enumerated().map { "\($0.offset + 1). \($0.element)" }
        } else {
            lines += items.map { "- \($0)" }
        }
    }
}

/// The memory changes one dream proposes: full updated lists, merged into the
/// durable `DreamMemory` by `DreamMemory.merging` so day-stamping, retention,
/// and caps stay deterministic app code rather than model behavior.
struct DreamMemoryUpdate: Equatable, Sendable {
    struct Project: Equatable, Sendable {
        var name: String
        var status: String
        var evidence: [String]
    }

    struct Goal: Equatable, Sendable {
        var text: String
        var horizon: String
        /// True only when evidence from the analyzed day, rather than the
        /// existing memory echoed in the prompt, reinforced this goal.
        var reinforcedToday: Bool
        /// True when the day's evidence shows the goal was completed or
        /// abandoned; the merge removes it instead of carrying it forward.
        var expired: Bool = false
    }

    var activeProjects: [Project] = []
    var workGoals: [Goal] = []
    var recurringPatterns: [String] = []

    var isEmpty: Bool {
        activeProjects.isEmpty && workGoals.isEmpty && recurringPatterns.isEmpty
    }
}

/// The durable structured work memory dreaming maintains: active projects,
/// current goals, and recurring patterns. Persisted as `memory/memory.json`
/// (+ a rendered `.md` sibling) under the storage root and fed back into the
/// next night's dream as context.
struct DreamMemory: Codable, Equatable, Sendable {
    static let currentVersion = 2
    static let maxProjects = 12
    static let maxGoals = 10
    static let maxPatterns = 12
    static let maxEvidencePerProject = 4
    /// A project untouched for this many days is considered dormant and drops
    /// out; goals persist longer because they are reinforced less often.
    static let projectRetentionDays = 30
    static let goalRetentionDays = 45

    struct Project: Codable, Equatable, Sendable {
        var name: String
        /// One-line current state ("waiting on review", "launch blocked on…").
        var status: String
        /// Last day ("yyyy-MM-dd") a dream saw evidence of this project.
        var lastActiveDay: String
        var evidence: [String] = []
        /// User-pinned entries are exempt from retention age-out and cap
        /// eviction; a dream can update them but never remove them.
        var pinned: Bool = false
        var provenance: DreamEvidenceProvenance?
    }

    struct Goal: Codable, Equatable, Sendable {
        var text: String
        /// Timeframe as stated or inferred ("this week", "Q3") — never a
        /// normalized date.
        var horizon: String
        var lastReinforcedDay: String
        /// User-pinned entries are exempt from retention age-out, cap
        /// eviction, and model-proposed expiry.
        var pinned: Bool = false
        var provenance: DreamEvidenceProvenance?
    }

    var version: Int = DreamMemory.currentVersion
    var updatedAt: Date
    var lastDreamDay: String?
    var activeProjects: [Project] = []
    var workGoals: [Goal] = []
    var recurringPatterns: [String] = []
    /// Parallel metadata keeps the public string list compatible with older
    /// views and exports. Missing entries represent unattributed legacy data.
    var patternProvenance: [String: DreamEvidenceProvenance] = [:]

    var isEmpty: Bool {
        activeProjects.isEmpty && workGoals.isEmpty && recurringPatterns.isEmpty
    }

    /// Deterministic merge of one night's proposed update:
    /// - proposed projects update or insert by case-insensitive name,
    ///   refreshing the day stamp only when new or actually changed;
    /// - goals refresh (and new goals insert) only when the model explicitly
    ///   ties them to evidence from the analyzed day;
    /// - a goal marked expired is removed (never inserted) — the one sanctioned
    ///   removal besides age-out, because it requires day evidence, not absence;
    /// - entries the model did not mention are kept (a small model forgetting
    ///   a project must not erase it) but age out after the retention window;
    /// - pinned entries sort first and skip the freshness filter, so neither
    ///   retention, cap eviction, nor expiry can remove them;
    /// - patterns are a full replacement list, including an explicit empty list;
    /// - everything is capped so memory can never grow unbounded.
    func merging(_ update: DreamMemoryUpdate, dreamDay: String, at date: Date,
                 calendar: Calendar = .current,
                 provenance: DreamEvidenceProvenance? = nil) -> DreamMemory {
        var merged = self
        merged.version = Self.currentVersion
        merged.updatedAt = date
        merged.lastDreamDay = dreamDay

        var projects = activeProjects
        for proposed in update.activeProjects.prefix(Self.maxProjects) {
            let evidence = Array(proposed.evidence.prefix(Self.maxEvidencePerProject))
            if let index = projects.firstIndex(where: {
                $0.name.caseInsensitiveCompare(proposed.name) == .orderedSame
            }) {
                let changed = projects[index].status != proposed.status
                    || projects[index].evidence != evidence
                projects[index].status = proposed.status
                projects[index].evidence = evidence
                if changed {
                    projects[index].lastActiveDay = dreamDay
                    projects[index].provenance = provenance
                }
            } else {
                projects.append(Project(name: proposed.name, status: proposed.status,
                                        lastActiveDay: dreamDay, evidence: evidence,
                                        provenance: provenance))
            }
        }
        merged.activeProjects = Array(
            projects
                .filter {
                    $0.pinned || Self.isFresh($0.lastActiveDay, asOf: dreamDay,
                                              retentionDays: Self.projectRetentionDays,
                                              calendar: calendar)
                }
                .sorted {
                    if $0.pinned != $1.pinned { return $0.pinned }
                    return $0.lastActiveDay == $1.lastActiveDay
                        ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                        : $0.lastActiveDay > $1.lastActiveDay
                }
                .prefix(Self.maxProjects))

        var goals = workGoals
        for proposed in update.workGoals where proposed.expired {
            if let index = goals.firstIndex(where: {
                $0.text.caseInsensitiveCompare(proposed.text) == .orderedSame
            }), !goals[index].pinned {
                goals.remove(at: index)
            }
        }
        for proposed in update.workGoals.filter({ !$0.expired }).prefix(Self.maxGoals) {
            if let index = goals.firstIndex(where: {
                $0.text.caseInsensitiveCompare(proposed.text) == .orderedSame
            }) {
                if proposed.reinforcedToday {
                    goals[index].horizon = proposed.horizon
                    goals[index].lastReinforcedDay = dreamDay
                    goals[index].provenance = provenance
                }
            } else if proposed.reinforcedToday {
                goals.append(Goal(text: proposed.text, horizon: proposed.horizon,
                                  lastReinforcedDay: dreamDay, provenance: provenance))
            }
        }
        merged.workGoals = Array(
            goals
                .filter {
                    $0.pinned || Self.isFresh($0.lastReinforcedDay, asOf: dreamDay,
                                              retentionDays: Self.goalRetentionDays,
                                              calendar: calendar)
                }
                .sorted {
                    if $0.pinned != $1.pinned { return $0.pinned }
                    return $0.lastReinforcedDay == $1.lastReinforcedDay
                        ? $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending
                        : $0.lastReinforcedDay > $1.lastReinforcedDay
                }
                .prefix(Self.maxGoals))

        merged.recurringPatterns = Array(update.recurringPatterns.prefix(Self.maxPatterns))
        merged.patternProvenance = [:]
        for pattern in merged.recurringPatterns {
            // An unchanged pattern keeps its original dependencies. Reworded
            // or new patterns depend on everything the synthesis could read.
            if recurringPatterns.contains(pattern) {
                merged.patternProvenance[pattern] = patternProvenance[pattern]
            } else {
                merged.patternProvenance[pattern] = provenance
            }
        }
        return merged
    }

    /// A synthesis can use any memory item in its context. Track that complete
    /// dependency closure conservatively; model citations cannot prove that a
    /// different item had no influence on its output.
    func provenance(adding sources: [DreamEvidenceSource], revision: UInt64) -> DreamEvidenceProvenance {
        let dependencies = activeProjects.map(\.provenance)
            + workGoals.map(\.provenance)
            + recurringPatterns.map { patternProvenance[$0] }
        let inherited = dependencies.compactMap { $0 }
        let allSources = Set(sources + inherited.flatMap(\.sources))
        return DreamEvidenceProvenance(
            sources: allSources.sorted {
                if $0.dayKey != $1.dayKey { return $0.dayKey < $1.dayKey }
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.id < $1.id
            },
            revision: revision,
            includesUnattributedContext: dependencies.contains { $0 == nil }
                || inherited.contains(where: \.includesUnattributedContext))
    }

    /// Source revocation overrides pinning. Without provenance an older entry
    /// cannot safely be attributed to an unaffected source, so the first
    /// evidence mutation removes it instead of guessing from its display text.
    func retractingEvidence(invalidations: [String: UInt64], revision: UInt64,
                            meetingInvalidations: [String: UInt64] = [:]) -> DreamMemory {
        guard revision > 0 else { return self }
        func keep(_ provenance: DreamEvidenceProvenance?) -> Bool {
            guard let provenance else { return false }
            return !provenance.isInvalidated(by: invalidations, currentRevision: revision,
                                            meetingRevisions: meetingInvalidations)
        }
        var memory = self
        memory.activeProjects.removeAll { !keep($0.provenance) }
        memory.workGoals.removeAll { !keep($0.provenance) }
        memory.recurringPatterns.removeAll { !keep(patternProvenance[$0]) }
        memory.patternProvenance = patternProvenance.filter { memory.recurringPatterns.contains($0.key) }
        return memory
    }

    func markdown() -> String {
        var lines = ["# Work memory", ""]
        lines.append("_Maintained overnight by dreaming. Updated \(DreamDay.key(for: updatedAt))._")
        lines += ["", "## Active projects", ""]
        if activeProjects.isEmpty {
            lines.append("_None observed yet._")
        } else {
            for project in activeProjects {
                let stamp = (project.pinned ? "pinned, " : "") + "last active \(project.lastActiveDay)"
                lines.append("- **\(project.name)** — \(project.status) _(\(stamp))_")
                lines += project.evidence.map { "  - \($0)" }
            }
        }
        lines += ["", "## Current goals", ""]
        if workGoals.isEmpty {
            lines.append("_None observed yet._")
        } else {
            lines += workGoals.map {
                "- \($0.text) _(\($0.horizon), \($0.pinned ? "pinned, " : "")reinforced \($0.lastReinforcedDay))_"
            }
        }
        lines += ["", "## Recurring patterns", ""]
        lines += recurringPatterns.isEmpty
            ? ["_None observed yet._"]
            : recurringPatterns.map { "- \($0)" }
        return lines.joined(separator: "\n")
    }

    func redacted() -> DreamMemory {
        var memory = self
        memory.activeProjects = activeProjects.map { project in
            var scrubbed = project
            scrubbed.name = ScreenContextPrivacy.redact(project.name).text
            scrubbed.status = ScreenContextPrivacy.redact(project.status).text
            scrubbed.evidence = project.evidence.map { ScreenContextPrivacy.redact($0).text }
            return scrubbed
        }
        memory.workGoals = workGoals.map { goal in
            var scrubbed = goal
            scrubbed.text = ScreenContextPrivacy.redact(goal.text).text
            scrubbed.horizon = ScreenContextPrivacy.redact(goal.horizon).text
            return scrubbed
        }
        memory.patternProvenance = [:]
        var unattributedPatterns: Set<String> = []
        memory.recurringPatterns = recurringPatterns.map { pattern in
            let redacted = ScreenContextPrivacy.redact(pattern).text
            if let provenance = patternProvenance[pattern] {
                // Redaction can collapse two strings; retain both dependencies.
                if let prior = memory.patternProvenance[redacted] {
                    memory.patternProvenance[redacted] = DreamEvidenceProvenance(
                        sources: Array(Set(prior.sources + provenance.sources)),
                        revision: min(prior.revision, provenance.revision),
                        includesUnattributedContext: prior.includesUnattributedContext
                            || provenance.includesUnattributedContext)
                } else {
                    memory.patternProvenance[redacted] = provenance
                }
            } else {
                unattributedPatterns.insert(redacted)
            }
            return redacted
        }
        for pattern in unattributedPatterns { memory.patternProvenance.removeValue(forKey: pattern) }
        return memory
    }

    /// Day-key freshness: parse both keys and compare against the retention
    /// window. Unparseable stamps count as stale — a corrupted entry ages out
    /// instead of living forever.
    private static func isFresh(_ dayKey: String, asOf referenceKey: String,
                                retentionDays: Int, calendar: Calendar) -> Bool {
        guard let day = DreamDay.date(fromKey: dayKey, calendar: calendar),
              let reference = DreamDay.date(fromKey: referenceKey, calendar: calendar) else {
            return false
        }
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays,
                                         to: reference) else { return true }
        return day >= cutoff
    }
}

// `pinned` postdates the first memory files. Custom decoding (in extensions,
// so the memberwise initializers keep their defaults) treats a missing key as
// false. Missing provenance stays unknown and is never guessed from model text.
extension DreamMemory.Project {
    private enum DecodingKeys: String, CodingKey {
        case name, status, lastActiveDay, evidence, pinned, provenance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        lastActiveDay = try container.decode(String.self, forKey: .lastActiveDay)
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        provenance = try container.decodeIfPresent(DreamEvidenceProvenance.self, forKey: .provenance)
    }
}

extension DreamMemory.Goal {
    private enum DecodingKeys: String, CodingKey {
        case text, horizon, lastReinforcedDay, pinned, provenance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        horizon = try container.decode(String.self, forKey: .horizon)
        lastReinforcedDay = try container.decode(String.self, forKey: .lastReinforcedDay)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        provenance = try container.decodeIfPresent(DreamEvidenceProvenance.self, forKey: .provenance)
    }
}

extension DreamMemory {
    private enum DecodingKeys: String, CodingKey {
        case version, updatedAt, lastDreamDay, activeProjects, workGoals, recurringPatterns, patternProvenance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastDreamDay = try container.decodeIfPresent(String.self, forKey: .lastDreamDay)
        activeProjects = try container.decode([Project].self, forKey: .activeProjects)
        workGoals = try container.decode([Goal].self, forKey: .workGoals)
        recurringPatterns = try container.decode([String].self, forKey: .recurringPatterns)
        patternProvenance = try container.decodeIfPresent(
            [String: DreamEvidenceProvenance].self, forKey: .patternProvenance) ?? [:]
    }
}
