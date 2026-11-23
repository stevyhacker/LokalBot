import Foundation

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

struct DreamInferenceProvenance: Codable, Equatable, Sendable {
    enum Location: String, Codable, Equatable, Sendable {
        case local
        case remote
    }

    var location: Location
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
        case .chatGPTPlan, .claudePlan, .antigravityPlan, .geminiPlan:
            self.init(location: .remote,
                      origin: SubscriptionPlan(backend: settings.summarizerBackend)?.consentKey)
            return
        }

        guard let rawURL, let url = URL(string: rawURL),
              InferenceEndpointPolicy.requiresApproval(url) else {
            self.init(location: .local)
            return
        }
        self.init(location: .remote, origin: InferenceEndpointPolicy.origin(for: url))
    }
}

enum DreamFallbackReason: String, Codable, Equatable, Sendable {
    case engineUnavailable
    case unparseableResponse
    case emptyDay
}

struct DreamEvidenceSource: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case meeting
        case screenDay
        case digest
    }

    var kind: Kind
    var id: String
    var dayKey: String
}

struct DreamEvidenceProvenance: Codable, Equatable, Sendable {
    var sources: [DreamEvidenceSource]
    var revision: UInt64
    var includesUnattributedContext: Bool = false

    func isInvalidated(by revisions: [String: UInt64], currentRevision: UInt64,
                       meetingRevisions: [String: UInt64] = [:],
                       activityRevisions: [String: UInt64] = [:]) -> Bool {
        if includesUnattributedContext || sources.isEmpty {
            return revision < currentRevision
        }
        return sources.contains { source in
            var dayRevision = revisions[source.dayKey] ?? 0
            if source.kind != .meeting {
                dayRevision = max(dayRevision, activityRevisions[source.dayKey] ?? 0)
            }
            return dayRevision > revision
                || (source.kind == .meeting && (meetingRevisions[source.id.uppercased()] ?? 0) > revision)
        }
    }
}

struct DreamReport: Codable, Equatable, Sendable {
    static let currentVersion = 3

    var version: Int = DreamReport.currentVersion
    var day: String
    var generatedAt: Date
    var engineName: String?
    var inferenceProvenance: DreamInferenceProvenance?
    var fallbackReason: DreamFallbackReason?
    var evidenceProvenance: DreamEvidenceProvenance?
    var narrative: String
    var attention: [String] = []
    var repeatedWork: [String] = []
    var suggestedChecks: [String] = []
    var frictions: [String] = []
    var topActions: [String] = []
    var topActionThreadIDs: [String?]?

    func topActionThreadID(at index: Int) -> String? {
        guard let ids = topActionThreadIDs, ids.indices.contains(index) else { return nil }
        return ids[index]
    }

    var isFallback: Bool { engineName == nil }

    var provenanceDescription: String { provenanceDescription(localized: { $0 }) }

    func provenanceDescription(localized: (String) -> String) -> String {
        if let engineName {
            switch inferenceProvenance?.location {
            case .local:
                return String(format: localized("Dreamed by %@ on this Mac."), engineName)
            case .remote:
                if let origin = inferenceProvenance?.origin {
                    return String(format: localized(
                        "Dreamed by %1$@ using approved remote inference at %2$@. "
                            + "The report was saved in your local library."), engineName, origin)
                }
                return String(format: localized(
                    "Dreamed by %@ using approved remote inference. The report was saved in your local library."),
                    engineName)
            case nil:
                return String(format: localized(
                    "Dreamed by %@ using your configured Think model. The report was saved in your local library."),
                    engineName)
            }
        }
        switch fallbackReason {
        case .engineUnavailable:
            return localized("No model was reachable overnight; this evidence-only brief was saved locally.")
        case .unparseableResponse:
            return localized("The model replied, but its response could not be read; "
                + "this evidence-only brief was saved locally.")
        case .emptyDay:
            return localized("Nothing substantive was recorded that day, so no model ran; "
                + "this placeholder just keeps the record complete.")
        case nil:
            return localized("Written as an evidence-only fallback and saved locally.")
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

struct DreamMemoryUpdate: Equatable, Sendable {
    struct Project: Equatable, Sendable {
        var name: String
        var status: String
        var evidence: [String]
        var activeToday: Bool?
    }

    struct Goal: Equatable, Sendable {
        var text: String
        var horizon: String
        var reinforcedToday: Bool
        var expired: Bool = false
    }

    var activeProjects: [Project] = []
    var workGoals: [Goal] = []
    var recurringPatterns: [String] = []

    var isEmpty: Bool {
        activeProjects.isEmpty && workGoals.isEmpty && recurringPatterns.isEmpty
    }
}

struct DreamMemory: Codable, Equatable, Sendable {
    static let currentVersion = 2
    static let maxProjects = 12
    static let maxGoals = 10
    static let maxPatterns = 12
    static let maxEvidencePerProject = 4
    static let projectRetentionDays = 30
    static let goalRetentionDays = 45

    struct Project: Codable, Equatable, Sendable {
        var name: String
        var status: String
        var lastActiveDay: String
        var evidence: [String] = []
        var pinned: Bool = false
        var provenance: DreamEvidenceProvenance?
    }

    struct Goal: Codable, Equatable, Sendable {
        var text: String
        var horizon: String
        var lastReinforcedDay: String
        var pinned: Bool = false
        var provenance: DreamEvidenceProvenance?
    }

    var version: Int = DreamMemory.currentVersion
    var updatedAt: Date
    var lastDreamDay: String?
    var activeProjects: [Project] = []
    var workGoals: [Goal] = []
    var recurringPatterns: [String] = []
    var patternProvenance: [String: DreamEvidenceProvenance] = [:]

    var isEmpty: Bool {
        activeProjects.isEmpty && workGoals.isEmpty && recurringPatterns.isEmpty
    }

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
                let active = proposed.activeToday ?? changed
                if active { projects[index].lastActiveDay = dreamDay }
                if active || changed { projects[index].provenance = provenance }
            } else if proposed.activeToday != false {
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
            if recurringPatterns.contains(pattern) {
                merged.patternProvenance[pattern] = patternProvenance[pattern]
            } else {
                merged.patternProvenance[pattern] = provenance
            }
        }
        return merged
    }

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

    func retractingEvidence(invalidations: [String: UInt64], revision: UInt64,
                            meetingInvalidations: [String: UInt64] = [:],
                            activityInvalidations: [String: UInt64] = [:]) -> DreamMemory {
        guard revision > 0 else { return self }
        func keep(_ provenance: DreamEvidenceProvenance?) -> Bool {
            guard let provenance else { return false }
            return !provenance.isInvalidated(by: invalidations, currentRevision: revision,
                                            meetingRevisions: meetingInvalidations,
                                            activityRevisions: activityInvalidations)
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
