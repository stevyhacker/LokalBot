import Combine
import Foundation

/// A source-backed note shown while preparing for an upcoming meeting. Every
/// decision and commitment retains its meeting id so Today can jump back to
/// the exact source instead of presenting an uncited AI assertion.
struct UpcomingMeetingReference: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case decision
        case commitment
    }

    let id: String
    let kind: Kind
    let text: String
    let meetingID: Meeting.ID
    let meetingTitle: String
    let meetingDate: Date
    let owner: String?
    let isForUser: Bool
    let due: String?
    let sourceMeetingCount: Int

    init(kind: Kind, text: String, meeting: Meeting, index: Int,
         owner: String? = nil, isForUser: Bool = false,
         due: String? = nil, sourceMeetingCount: Int = 1) {
        id = "\(meeting.id.uuidString)-\(kind.rawValue)-\(index)"
        self.kind = kind
        self.text = text
        meetingID = meeting.id
        meetingTitle = meeting.title
        meetingDate = meeting.startedAt
        self.owner = owner
        self.isForUser = isForUser
        self.due = due
        self.sourceMeetingCount = sourceMeetingCount
    }

    init(thread: ActionThread) {
        let source = thread.latestReference
        id = thread.id
        kind = .commitment
        text = thread.text
        meetingID = source.meetingID
        meetingTitle = source.meetingTitle
        meetingDate = source.meetingStartedAt
        owner = thread.owner
        isForUser = thread.isForUser
        due = thread.due
        sourceMeetingCount = thread.meetingCount
    }
}

struct UpcomingMeetingProjectContext: Identifiable, Equatable, Sendable {
    var id: String { name.lowercased() }
    let name: String
    let status: String
    let lastActiveDay: String
}

struct UpcomingMeetingRelatedMeeting: Equatable, Sendable {
    let meeting: Meeting
    let summary: String
    let participantMatches: Int
    let relevanceScore: Int
}

/// The complete, bounded evidence packet behind one pre-meeting card. The LLM
/// only rewrites this packet; code selects the event, source meetings, project
/// context, decisions, and commitments.
struct UpcomingMeetingEvidence: Equatable, Sendable {
    let event: CalendarMeetingCandidate
    let relatedMeetings: [UpcomingMeetingRelatedMeeting]
    let decisions: [UpcomingMeetingReference]
    let commitments: [UpcomingMeetingReference]
    let projects: [UpcomingMeetingProjectContext]

    var hasPreparationContext: Bool {
        !relatedMeetings.isEmpty || !decisions.isEmpty || !commitments.isEmpty || !projects.isEmpty
    }

    /// Stable within one process and deliberately includes extracted content,
    /// so a newly-written summary/outcomes file invalidates the in-memory brief.
    var signature: String {
        let meetingParts = relatedMeetings.map { $0.meeting.id.uuidString + $0.summary }
        let commitmentParts: [String] = commitments.map { commitment in
            let fields = [commitment.text, commitment.owner ?? "", String(commitment.isForUser),
                          commitment.due ?? "",
                          String(commitment.sourceMeetingCount)]
            return ContentFingerprint.fields(fields)
        }
        let projectParts = projects.map { $0.name + $0.status + $0.lastActiveDay }
        let parts: [String] = [
            event.externalID,
            event.title,
            String(event.startDate.timeIntervalSinceReferenceDate),
            String(event.endDate.timeIntervalSinceReferenceDate),
            event.participantNames.joined(separator: "|"),
            meetingParts.joined(separator: "|"),
            decisions.map(\.text).joined(separator: "|"),
            commitmentParts.joined(separator: "|"),
            projectParts.joined(separator: "|"),
        ]
        return parts.joined(separator: "\u{1f}")
    }

    /// An immediate, model-free brief keeps the card useful while the local
    /// model starts (or when none is available). It only restates selected
    /// evidence and never infers completion or ownership.
    var fallbackBrief: String {
        var sentences: [String] = []
        if let decision = decisions.first {
            sentences.append("Last decision: \(sentence(decision.text))")
        }
        if let commitment = commitments.first {
            var detail = sentence(commitment.text)
            if let owner = nonEmpty(commitment.owner) {
                let displayOwner = SpeakerDisplayName.label(
                    owner,
                    identity: commitment.isForUser ? .user : .unresolved)
                detail += " Owner: \(displayOwner)."
            }
            if let due = nonEmpty(commitment.due) { detail += " Due: \(due)." }
            sentences.append("Commitment to revisit: \(detail)")
        }
        if let project = projects.first {
            sentences.append("\(project.name): \(sentence(project.status))")
        }
        if sentences.isEmpty, let prior = relatedMeetings.first {
            sentences.append("The closest prior context is \(prior.meeting.title) from "
                + prior.meeting.startedAt.formatted(date: .abbreviated, time: .omitted) + ".")
        }
        if sentences.isEmpty {
            return "No related decisions or commitments were found in LokalBot yet."
        }
        return PromptContextSanitizer.sanitize(
            sentences.prefix(3).joined(separator: " "), maxCharacters: 520)
    }

    var promptContext: String {
        var sections = [
            "Upcoming meeting: \(event.title)",
            "Scheduled: \(event.startDate.formatted(date: .complete, time: .shortened))–"
                + event.endDate.formatted(date: .omitted, time: .shortened),
        ]
        if !event.participantNames.isEmpty {
            sections.append("Participants: \(event.participantNames.joined(separator: ", "))")
        }
        if !relatedMeetings.isEmpty {
            let rows = relatedMeetings.map { related in
                var row = "- \(related.meeting.startedAt.formatted(date: .abbreviated, time: .omitted)) · "
                    + related.meeting.title
                if !related.summary.isEmpty { row += "\n  \(related.summary)" }
                return row
            }
            sections.append("Prior related meetings:\n" + rows.joined(separator: "\n"))
        }
        if !decisions.isEmpty {
            sections.append("Prior decisions:\n" + decisions.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        if !commitments.isEmpty {
            sections.append("Commitments from prior notes (using saved corrections and status):\n"
                + commitments.map { reference in
                    var metadata: [String] = []
                    if let owner = nonEmpty(reference.owner) { metadata.append("owner: \(owner)") }
                    if let due = nonEmpty(reference.due) { metadata.append("due: \(due)") }
                    if reference.sourceMeetingCount > 1 {
                        metadata.append("sources: \(reference.sourceMeetingCount) meetings")
                    }
                    return "- \(reference.text)"
                        + (metadata.isEmpty ? "" : " (\(metadata.joined(separator: ", ")))")
                }.joined(separator: "\n"))
        }
        if !projects.isEmpty {
            sections.append("Recent project context:\n" + projects.map {
                "- \($0.name): \($0.status) (last active \($0.lastActiveDay))"
            }.joined(separator: "\n"))
        }
        return PromptContextSanitizer.sanitize(
            sections.joined(separator: "\n\n"), maxCharacters: 12_000)
    }

    private func sentence(_ value: String) -> String {
        let clean = PromptContextSanitizer.sanitize(value, maxCharacters: 220)
        guard let last = clean.last, !".!?".contains(last) else { return clean }
        return clean + "."
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clean.isEmpty else { return nil }
        return clean
    }
}

enum UpcomingMeetingSelector {
    /// Keep every event overlapping the requested local day, including
    /// meetings which have ended and meetings many hours away.
    static func schedule(
        from candidates: [CalendarMeetingCandidate],
        on date: Date,
        calendar: Calendar = .current
    ) -> [CalendarMeetingCandidate] {
        guard let interval = calendar.dateInterval(of: .day, for: date) else { return [] }
        return candidates
            .filter { $0.endDate > interval.start && $0.startDate < interval.end }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                return lhs.endDate < rhs.endDate
            }
    }

    /// Pick the meeting whose preparation deserves emphasis: an in-progress
    /// event first, otherwise the next event at any later time today. The event
    /// already being recorded is skipped because Today has a dedicated live card.
    static func primary(
        from schedule: [CalendarMeetingCandidate],
        now: Date,
        excludingEventID: String? = nil
    ) -> CalendarMeetingCandidate? {
        schedule
            .filter { candidate in
                candidate.externalID != excludingEventID
                    && candidate.endDate >= now
            }
            .sorted { lhs, rhs in
                let lhsActive = lhs.startDate <= now
                let rhsActive = rhs.startDate <= now
                if lhsActive != rhsActive { return lhsActive }
                if lhsActive { return lhs.startDate > rhs.startDate }
                return lhs.startDate < rhs.startDate
            }
            .first
    }
}

/// Deterministic local retrieval for pre-meeting evidence. Participant matches
/// dominate recurring-title matches; recency breaks ties. This avoids asking an
/// LLM to search the entire private library or decide which sources are relevant.
enum UpcomingMeetingPreparationCompiler {
    static let lookbackDays = 180
    static let maximumRelatedMeetings = 6
    static let maximumReferencesPerKind = 5
    static let maximumProjects = 3

    private static let genericTerms: Set<String> = [
        "and", "call", "daily", "for", "meeting", "monthly", "planning", "review",
        "standup", "sync", "team", "the", "weekly", "with",
    ]

    static func compile(
        event: CalendarMeetingCandidate,
        meetings: [Meeting],
        storageRoot: URL,
        memory: DreamMemory?,
        now: Date
    ) -> UpcomingMeetingEvidence {
        let cutoff = now.addingTimeInterval(-TimeInterval(lookbackDays) * 86_400)
        let eventTitleTerms = terms(event.title)
        let eventParticipantNames = Set(event.participantNames.map(normalizedPhrase).filter { !$0.isEmpty })

        let scored = meetings.compactMap { meeting -> UpcomingMeetingRelatedMeeting? in
            guard meeting.endedAt != nil, meeting.startedAt < now, meeting.startedAt >= cutoff else {
                return nil
            }
            let folder = storageRoot.appendingPathComponent(meeting.relativePath, isDirectory: true)
            let summary = PromptContextSanitizer.sanitize(
                (try? String(contentsOf: folder.appendingPathComponent("summary.md"),
                             encoding: .utf8)) ?? "",
                maxCharacters: 1_600)
            let priorNames = Set(meeting.resolvedCalendarParticipantIdentities.compactMap(\.name)
                .map(normalizedPhrase).filter { !$0.isEmpty })
            let directParticipantMatches = eventParticipantNames.intersection(priorNames).count
            let corpusTerms = terms(meeting.title + "\n" + summary)
            let mentionedParticipantMatches = event.participantNames.filter { name in
                let nameTerms = terms(name, droppingGenericTerms: false)
                return !nameTerms.isEmpty && nameTerms.isSubset(of: corpusTerms)
            }.count
            let participantMatches = max(directParticipantMatches, mentionedParticipantMatches)

            let exactTitle = normalizedPhrase(event.title) == normalizedPhrase(
                meeting.calendarTitle ?? meeting.title)
            let titleOverlap = eventTitleTerms.intersection(
                terms(meeting.calendarTitle ?? meeting.title)).count
            var score = participantMatches * 120 + titleOverlap * 24
            if exactTitle { score += 100 }
            guard score > 0 else { return nil }
            if meeting.startedAt >= now.addingTimeInterval(-30 * 86_400) { score += 12 }
            return UpcomingMeetingRelatedMeeting(
                meeting: meeting,
                summary: summary,
                participantMatches: participantMatches,
                relevanceScore: score)
        }
        .sorted { lhs, rhs in
            if lhs.relevanceScore != rhs.relevanceScore {
                return lhs.relevanceScore > rhs.relevanceScore
            }
            return lhs.meeting.startedAt > rhs.meeting.startedAt
        }

        let related = Array(scored.prefix(maximumRelatedMeetings))
        var decisions: [UpcomingMeetingReference] = []
        var actionReferences: [OutcomeActionReference] = []
        for relatedMeeting in related {
            let meeting = relatedMeeting.meeting
            guard let projection = MeetingOutcomeProjection.load(
                for: meeting,
                root: storageRoot) else { continue }
            let outcomes = projection.outcomes
            for (index, decision) in outcomes.decisions.enumerated() {
                decisions.append(UpcomingMeetingReference(
                    kind: .decision, text: decision, meeting: meeting, index: index))
            }
            actionReferences += projection.actionReferences
        }
        let commitments = ActionThreadClusterer.cluster(actionReferences)
            .filter { $0.status != .done }
            .map { UpcomingMeetingReference(thread: $0) }

        let projects = projectContext(
            memory: memory,
            eventTerms: eventTitleTerms,
            related: related)
        return UpcomingMeetingEvidence(
            event: event,
            relatedMeetings: related,
            decisions: Array(decisions.prefix(maximumReferencesPerKind)),
            commitments: Array(commitments.prefix(maximumReferencesPerKind)),
            projects: projects)
    }

    private static func projectContext(
        memory: DreamMemory?,
        eventTerms: Set<String>,
        related: [UpcomingMeetingRelatedMeeting]
    ) -> [UpcomingMeetingProjectContext] {
        guard let memory else { return [] }
        let relatedTerms = related.reduce(into: Set<String>()) { result, item in
            result.formUnion(terms(item.meeting.title + "\n" + item.summary))
        }
        return memory.activeProjects.compactMap { project -> (Int, DreamMemory.Project)? in
            let projectTerms = terms(project.name)
            guard !projectTerms.isEmpty else { return nil }
            let direct = projectTerms.intersection(eventTerms).count
            let contextual = projectTerms.intersection(relatedTerms).count
            guard direct > 0 || contextual > 0 else { return nil }
            return (direct * 100 + contextual * 20 + (project.pinned ? 5 : 0), project)
        }
        .sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            return lhs.1.lastActiveDay > rhs.1.lastActiveDay
        }
        .prefix(maximumProjects)
        .map { _, project in
            UpcomingMeetingProjectContext(
                name: project.name,
                status: project.status,
                lastActiveDay: project.lastActiveDay)
        }
    }

    private static func normalizedPhrase(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private static func terms(_ value: String,
                              droppingGenericTerms: Bool = true) -> Set<String> {
        let values = normalizedPhrase(value).split(separator: " ").map(String.init)
        return Set(values.filter { term in
            term.count >= 3 && (!droppingGenericTerms || !genericTerms.contains(term))
        })
    }
}

enum UpcomingMeetingBriefGenerator {
    private struct Draft: Decodable {
        let brief: String
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "brief": ["type": "string"],
        ],
        "required": ["brief"],
        "additionalProperties": false,
    ]

    enum GenerationError: LocalizedError {
        case emptyEvidence
        case unreadableResponse

        var errorDescription: String? {
            switch self {
            case .emptyEvidence: "No related local context was found."
            case .unreadableResponse: "The local model returned an unreadable brief."
            }
        }
    }

    static func generate(evidence: UpcomingMeetingEvidence,
                         engine: TextEngine) async throws -> String {
        guard evidence.hasPreparationContext else { throw GenerationError.emptyEvidence }
        let output = try await engine.generate(
            system: """
                You write a concise pre-meeting brief from private evidence already selected by LokalBot.
                Use only supplied evidence. Do not invent history, completion, ownership, dates, or attendee intent.
                Write two or three direct sentences: what matters now, a prior decision, and a commitment or risk to revisit.
                Avoid headings, bullets, greetings, and meta commentary. Return only the requested JSON object.
                """,
            prompt: "Prepare me for \(evidence.event.title).",
            context: [evidence.promptContext],
            schema: schema,
            options: TextGenerationOptions(
                maxTokens: 420,
                reasoningBudgetTokens: 256,
                temperature: 0.2))
        guard let json = ChatPrompt.extractJSONObject(strippingReasoning(output)),
              let data = json.data(using: .utf8),
              let draft = try? JSONDecoder().decode(Draft.self, from: data) else {
            throw GenerationError.unreadableResponse
        }
        let clean = PromptContextSanitizer.sanitize(draft.brief, maxCharacters: 700)
        guard !clean.isEmpty else { throw GenerationError.unreadableResponse }
        return clean
    }
}

enum UpcomingMeetingLocalGenerationPolicy {
    static func permitsLocalGeneration(settings: AppSettings) -> Bool {
        DreamInferenceProvenance(settings: settings).location == .local
    }

    /// Automatic preparation must never trigger a surprise multi-gigabyte
    /// download. A user can still explicitly request generation from the card.
    static func shouldGenerateAutomatically(settings: AppSettings,
                                            storage: StorageManager) -> Bool {
        guard permitsLocalGeneration(settings: settings) else { return false }
        switch settings.summarizerBackend {
        case .builtIn:
            guard let entry = ModelCatalog.entry(
                id: settings.builtInModelID,
                custom: settings.customBuiltInModels)
                    ?? ModelCatalog.entry(id: settings.builtInModelID) else { return false }
            return ModelCatalog.localURL(for: entry, storage: storage) != nil
        case .appleIntelligence, .ollama, .openAICompatible:
            return true
        }
    }
}

/// Today-owned state for the full calendar day. Every meeting is retained for
/// the schedule, but only the active/next meeting gets the heavier history
/// lookup and optional local-LLM brief. Generated briefs stay cached across
/// 30-second refreshes.
@MainActor
final class UpcomingMeetingPreparationModel: ObservableObject {
    enum Status: Equatable {
        case loading
        case disabled
        case permissionRequired
        case permissionDenied
        case noMeetingsToday
        case ready
    }

    @Published private(set) var status: Status = .loading
    @Published private(set) var meetingsToday: [CalendarMeetingCandidate] = []
    @Published private(set) var evidence: UpcomingMeetingEvidence?
    @Published private(set) var primaryEventID: String?
    @Published private(set) var generatingSignature: String?
    @Published private var generatedBriefs: [String: String] = [:]
    @Published private var generationErrors: [String: String] = [:]

    private var refreshToken = UUID()
    private var failedSignatures: Set<String> = []

    func brief(for evidence: UpcomingMeetingEvidence) -> String {
        generatedBriefs[evidence.signature] ?? evidence.fallbackBrief
    }

    func generatedByModel(for evidence: UpcomingMeetingEvidence) -> Bool {
        generatedBriefs[evidence.signature] != nil
    }

    func isGenerating(_ evidence: UpcomingMeetingEvidence) -> Bool {
        generatingSignature == evidence.signature
    }

    func generationError(for evidence: UpcomingMeetingEvidence) -> String? {
        generationErrors[evidence.signature]
    }

    func refresh(app: AppState, now: Date = Date()) async {
        let token = UUID()
        refreshToken = token
        var candidateSchedule: [CalendarMeetingCandidate]?
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_CALENDAR_DEMO"] == "1" {
            candidateSchedule = Self.demoSchedule(now: now)
        }
#endif
        if candidateSchedule == nil {
            app.calendar.refreshAuthorizationStatus()

            guard app.settings.calendarDetectionEnabled else {
                clear(status: .disabled)
                return
            }
            switch app.calendar.authorizationStatus {
            case .notDetermined:
                clear(status: .permissionRequired)
                return
            case .fullAccess:
                break
            case .restricted, .denied, .writeOnly:
                clear(status: .permissionDenied)
                return
            }
            candidateSchedule = app.calendar.meetingCandidates(on: now)
        }

        let schedule = UpcomingMeetingSelector.schedule(
            from: candidateSchedule ?? [],
            on: now)
        guard !schedule.isEmpty else {
            clear(status: .noMeetingsToday)
            return
        }
        let primary = UpcomingMeetingSelector.primary(
            from: schedule,
            now: now,
            excludingEventID: app.currentMeeting?.calendarEventID)

        meetingsToday = schedule
        primaryEventID = primary?.externalID
        status = .ready
        guard let primary else {
            evidence = nil
            generationErrors = [:]
            return
        }
        if evidence?.event.externalID != primary.externalID {
            evidence = nil
        }

        let meetings = app.meetings
        let root = app.storage.rootURL
        let memory = try? app.dreamStore.loadMemory()
        let compiled = await Task.detached(priority: .utility) {
            UpcomingMeetingPreparationCompiler.compile(
                event: primary,
                meetings: meetings,
                storageRoot: root,
                memory: memory,
                now: now)
        }.value
        guard refreshToken == token, !Task.isCancelled else { return }

        evidence = compiled
        generationErrors = generationErrors.filter { $0.key == compiled.signature }

        if generatedBriefs[compiled.signature] == nil,
           compiled.hasPreparationContext,
           !failedSignatures.contains(compiled.signature),
           UpcomingMeetingLocalGenerationPolicy.shouldGenerateAutomatically(
                settings: app.settings, storage: app.storage) {
            await generate(app: app, evidence: compiled)
        }
    }

#if LOKALBOT_UI_TEST_HOST
    /// A deterministic, non-EventKit seam for screenshots and XCUITest. It
    /// exercises the real schedule, evidence compiler, Join/Record actions,
    /// and accessibility tree without reading the developer's calendar.
    private static func demoSchedule(now: Date) -> [CalendarMeetingCandidate] {
        [
            CalendarMeetingCandidate(
                provider: "demo",
                externalID: "demo-design-review-follow-up",
                title: "Design review follow-up",
                startDate: now.addingTimeInterval(55 * 60),
                endDate: now.addingTimeInterval(115 * 60),
                meetingURL: URL(string: "https://zoom.us/j/123456789"),
                sourceCalendarTitle: "Work",
                participantNames: ["Maya", "Hernan"]),
            CalendarMeetingCandidate(
                provider: "demo",
                externalID: "demo-customer-check-in",
                title: "Customer check-in",
                startDate: now.addingTimeInterval(3 * 60 * 60),
                endDate: now.addingTimeInterval(3.5 * 60 * 60),
                meetingURL: nil,
                sourceCalendarTitle: "Work",
                participantNames: ["Jordan Lee"]),
        ]
    }
#endif

    /// Explicit generation may prepare/download the user's selected local
    /// model; unlike automatic refresh, that potentially expensive action is
    /// always initiated by the Generate brief button.
    func generate(app: AppState, evidence: UpcomingMeetingEvidence) async {
        guard generatingSignature == nil, evidence.hasPreparationContext else { return }
        guard UpcomingMeetingLocalGenerationPolicy.permitsLocalGeneration(
            settings: app.settings) else {
            generationErrors[evidence.signature] =
                "Choose an on-device Think model to generate this brief."
            return
        }

        let signature = evidence.signature
        generatingSignature = signature
        generationErrors.removeValue(forKey: signature)
        defer {
            if generatingSignature == signature { generatingSignature = nil }
        }
        do {
            let engine = try await app.thinkExecution.makeTextEngine(
                app.settings,
                priority: .background,
                purpose: "pre-meeting brief")
            let generated = try await UpcomingMeetingBriefGenerator.generate(
                evidence: evidence, engine: engine)
            try Task.checkCancellation()
            guard self.evidence?.signature == signature else { return }
            generatedBriefs[signature] = generated
            failedSignatures.remove(signature)
            if generatedBriefs.count > 24, let oldest = generatedBriefs.keys.first {
                generatedBriefs.removeValue(forKey: oldest)
            }
        } catch is CancellationError {
            return
        } catch {
            guard self.evidence?.signature == signature else { return }
            failedSignatures.insert(signature)
            generationErrors[signature] = "AI brief unavailable; showing saved context."
            lokalbotLog("pre-meeting brief fallback error=\(error.localizedDescription)")
        }
    }

    private func clear(status: Status) {
        self.status = status
        meetingsToday = []
        evidence = nil
        primaryEventID = nil
        generationErrors = [:]
    }
}
