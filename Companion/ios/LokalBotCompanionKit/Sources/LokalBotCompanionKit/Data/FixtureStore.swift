import Foundation

/// An in-memory store over record envelopes. It serves the bundled sample
/// library ("Try it without a Mac"), previews and tests, and follows the same
/// rules as the Rust store: upsert by (kind, key) keeping the higher version,
/// tombstones remove, merged meetings are hidden.
public actor FixtureStore: CompanionStore {
    public struct Configuration: Sendable {
        /// "Today" for overdue actions and the Ask demo.
        public var now: @Sendable () -> Date
        /// Status changes stay "waiting for your Mac" instead of applying at once.
        public var keepsChangesPending: Bool
        /// Present a paired Mac (previews and screenshots); otherwise the
        /// store reports itself as the sample library.
        public var pairedStatus: SyncStatus?
        /// Whether Ask reaches the (pretend) Mac.
        public var macReachable: Bool

        public init(now: @escaping @Sendable () -> Date = { Date() }, keepsChangesPending: Bool = false,
                    pairedStatus: SyncStatus? = nil, macReachable: Bool = true) {
            self.now = now
            self.keepsChangesPending = keepsChangesPending
            self.pairedStatus = pairedStatus
            self.macReachable = macReachable
        }
    }

    private var configuration: Configuration
    private var records: [String: [String: (version: Int, body: RecordBody)]] = [:]
    private var pendingActions: Set<String> = []
    private var queue: [AskRequest] = []
    private var history: [AskExchange] = []
    private var syncStatus: SyncStatus

    public init(envelopes: [RecordEnvelope], configuration: Configuration = .init()) {
        self.configuration = configuration
        self.syncStatus = configuration.pairedStatus ?? .unpaired
        Self.ingest(envelopes, into: &records)
    }

    /// The bundled sample library: Companion/protocol/fixtures/sample-library.json.
    public static func sampleLibrary(configuration: Configuration = .init()) throws -> FixtureStore {
        FixtureStore(envelopes: try SampleLibrary.envelopes(), configuration: configuration)
    }

    /// Adds envelopes as a sync batch would.
    public func importRecords(_ envelopes: [RecordEnvelope]) {
        Self.ingest(envelopes, into: &records)
    }

    private static func ingest(_ envelopes: [RecordEnvelope], into records: inout [String: [String: (version: Int, body: RecordBody)]]) {
        for envelope in envelopes {
            if let existing = records[envelope.kind]?[envelope.key], existing.version > envelope.version { continue }
            if envelope.deleted {
                records[envelope.kind]?[envelope.key] = nil
            } else {
                records[envelope.kind, default: [:]][envelope.key] = (envelope.version, envelope.body)
            }
        }
    }

    private func bodies(_ kind: RecordKind) -> [RecordBody] {
        records[kind.rawValue].map { Array($0.values.map(\.body)) } ?? []
    }

    private var allMeetings: [Meeting] {
        bodies(.meeting).compactMap { if case .meeting(let meeting) = $0, meeting.mergedInto == nil { meeting } else { nil } }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var today: DayKey { DayKey(configuration.now()) }

    // MARK: Reads

    public func manifest() -> Manifest? {
        if case .manifest(let manifest)? = records[RecordKind.manifest.rawValue]?["library"]?.body { return manifest }
        return nil
    }

    public func meetings(fromDay: String?, toDay: String?, limit: Int) -> [Meeting] {
        Array(allMeetings.filter { meeting in
            (fromDay.map { meeting.day >= $0 } ?? true) && (toDay.map { meeting.day <= $0 } ?? true)
        }.prefix(limit))
    }

    public func meeting(id: String) -> Meeting? {
        if case .meeting(let meeting)? = records[RecordKind.meeting.rawValue]?[id]?.body { return meeting }
        return nil
    }

    public func transcript(meetingID: String) -> Transcript? {
        if case .transcript(let transcript)? = records[RecordKind.transcript.rawValue]?[meetingID]?.body { return transcript }
        return nil
    }

    public func days(limit: Int) -> [String] {
        Array((records[RecordKind.day.rawValue]?.keys.sorted(by: >) ?? []).prefix(limit))
    }

    public func day(_ date: String) -> DayRecord? {
        if case .day(let day)? = records[RecordKind.day.rawValue]?[date]?.body { return day }
        return nil
    }

    public func actions(_ filter: ActionFilter) -> [ActionRow] {
        let rows = allMeetings.flatMap { meeting in
            meeting.actions.filter(filter.matches).map { action in
                ActionRow(meetingId: meeting.id, meetingTitle: meeting.title, meetingStartedAt: meeting.startedAt,
                          action: action, pending: pendingActions.contains(Self.actionKey(meeting.id, action.id)))
            }
        }
        return ActionOrdering.sorted(rows, today: today)
    }

    public func people() -> [Person] {
        bodies(.person).compactMap { if case .person(let person) = $0 { currentOpenWork(person) } else { nil } }
            .sorted { ($0.lastMetAt ?? .distantPast, $1.displayName) > ($1.lastMetAt ?? .distantPast, $0.displayName) }
    }

    public func person(id: String) -> Person? {
        if case .person(let person)? = records[RecordKind.person.rawValue]?[id]?.body { return currentOpenWork(person) }
        return nil
    }

    public func projects() -> [Project] {
        bodies(.project).compactMap { if case .project(let project) = $0 { currentStatus(project) } else { nil } }
            .sorted { ($0.timeThisWeekSeconds, $1.name) > ($1.timeThisWeekSeconds, $0.name) }
    }

    public func project(id: String) -> Project? {
        if case .project(let project)? = records[RecordKind.project.rawValue]?[id]?.body { return currentStatus(project) }
        return nil
    }

    /// People and projects are rebuilt on the Mac; until then, reflect status
    /// changes made here.
    private func currentOpenWork(_ person: Person) -> Person {
        var person = person
        person.openWork = person.openWork.filter { actionStatus($0.meetingId, $0.actionId) ?? .open == .open }
        return person
    }

    private func currentStatus(_ project: Project) -> Project {
        var project = project
        for index in project.yourActions.indices {
            let item = project.yourActions[index]
            if let status = actionStatus(item.meetingId, item.actionId) { project.yourActions[index].status = status }
        }
        project.waitingOnOthers = project.waitingOnOthers.filter { actionStatus($0.meetingId, $0.actionId) ?? .open == .open }
        return project
    }

    private func actionStatus(_ meetingID: String, _ actionID: String) -> ActionStatus? {
        meeting(id: meetingID)?.actions.first { $0.id == actionID }?.status
    }

    public func search(_ query: String, limit: Int) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let terms = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        func matches(_ text: String) -> Bool {
            terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var hits: [SearchHit] = []
        for meeting in allMeetings {
            if matches(meeting.title) {
                hits.append(SearchHit(kind: "meeting", key: meeting.id, meetingId: meeting.id, title: meeting.title,
                                      snippet: [meeting.appName, LBFormat.meetingDuration(meeting.durationSeconds)].compactMap { $0 }.joined(separator: " · ")))
            }
            for action in meeting.actions where matches(action.text) {
                hits.append(SearchHit(kind: "action", key: meeting.id, meetingId: meeting.id, title: meeting.title,
                                      snippet: action.text, at: action.citations.first?.start))
            }
            for decision in meeting.decisions + meeting.openQuestions where matches(decision.text) {
                hits.append(SearchHit(kind: "decision", key: meeting.id, meetingId: meeting.id, title: meeting.title,
                                      snippet: decision.text, at: decision.citations.first?.start))
            }
            for text in [meeting.summaryMarkdown, meeting.notesMarkdown].compactMap({ $0 }) where matches(text) {
                hits.append(SearchHit(kind: "meeting", key: meeting.id, meetingId: meeting.id, title: meeting.title,
                                      snippet: Self.snippet(text, around: terms[0])))
            }
            for segment in transcript(meetingID: meeting.id)?.segments ?? [] where matches(segment.text) {
                hits.append(SearchHit(kind: "transcript", key: meeting.id, meetingId: meeting.id, title: meeting.title,
                                      snippet: segment.text, at: segment.start))
            }
        }
        for key in days(limit: .max) {
            guard let digest = day(key)?.digest, matches(digest.markdown) else { continue }
            hits.append(SearchHit(kind: "day", key: key, title: "Day Digest", snippet: Self.snippet(digest.markdown, around: terms[0]), date: key))
        }
        var seen = Set<String>()
        return Array(hits.filter { seen.insert("\($0.kind)|\($0.key)|\($0.snippet)").inserted }.prefix(limit))
    }

    static func snippet(_ markdown: String, around term: String, radius: Int = 70) -> String {
        let text = markdown.replacingOccurrences(of: #"[#*_>`]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(text.prefix(radius * 2))
        }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end].trimmingCharacters(in: .whitespaces)
            + (end < text.endIndex ? "…" : "")
    }

    // MARK: Changes

    public func setActionStatus(meetingID: String, actionID: String, status: ActionStatus) throws {
        guard case .meeting(var meeting)? = records[RecordKind.meeting.rawValue]?[meetingID]?.body,
              let index = meeting.actions.firstIndex(where: { $0.id == actionID }),
              let version = records[RecordKind.meeting.rawValue]?[meetingID]?.version else {
            throw CompanionStoreError.failed("That action is no longer in this meeting.")
        }
        meeting.actions[index].status = status
        records[RecordKind.meeting.rawValue]?[meetingID] = (version, .meeting(meeting))
        if configuration.keepsChangesPending { pendingActions.insert(Self.actionKey(meetingID, actionID)) }
    }

    private static func actionKey(_ meetingID: String, _ actionID: String) -> String { "\(meetingID)/\(actionID)" }

    // MARK: Questions

    public func ask(_ request: AskRequest, extraAddresses: [String],
                    onDelta: @escaping @Sendable (String) -> Void) async throws -> AskResult {
        guard configuration.macReachable else { throw CompanionStoreError.unreachable }
        let (answer, citations) = sampleAnswer(to: request.question)
        var streamed = ""
        for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
            let piece = (streamed.isEmpty ? "" : " ") + word
            streamed += piece
            onDelta(piece)
            try await Task.sleep(for: .milliseconds(18))
        }
        let result = AskResult(requestId: request.requestId, answer: answer, citations: citations,
                               engineLabel: configuration.pairedStatus == nil ? "Sample library" : "Qwen3.6 35B",
                               location: .mac, answeredAt: configuration.now())
        history.insert(AskExchange(request: request, result: result), at: 0)
        queue.removeAll { $0.requestId == request.requestId }
        return result
    }

    /// A short answer built from the library's own decisions and actions, so
    /// the sample shows cited answers without a Mac.
    private func sampleAnswer(to question: String) -> (String, [AskCitation]) {
        let stopWords: Set<String> = ["what", "when", "where", "which", "about", "this", "that", "with", "week",
                                      "have", "does", "did", "from", "were", "will", "there", "they", "their"]
        let terms = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
        var lines: [String] = []
        var citations: [AskCitation] = []
        let format = LBFormat.current
        for meeting in allMeetings {
            let items: [(String, Citation?)] = meeting.decisions.map { ($0.text, $0.citations.first) }
                + meeting.actions.map { ("\($0.ownerIsUser ? "You" : $0.owner ?? "Someone") will \($0.text.prefix(1).lowercased() + $0.text.dropFirst())", $0.citations.first) }
            for (text, citation) in items where terms.contains(where: { text.lowercased().contains($0) || meeting.title.lowercased().contains($0) }) {
                guard citations.count < 4 else { break }
                let index = citations.count + 1
                let at = citation?.start
                citations.append(AskCitation(index: index, meetingId: meeting.id, at: at,
                                             label: "\(meeting.title) · \(at.map { format.time(in: meeting, at: $0) } ?? format.time(meeting.startedAt, in: meeting.timeZone))"))
                lines.append("- \(text.hasSuffix(".") ? String(text.dropLast()) : text) [\(index)]")
            }
        }
        guard !lines.isEmpty else {
            return ("The sample library doesn't cover that. Try asking about onboarding, pricing or the Northwind call.", [])
        }
        return ("Here is what the sample library has on that:\n\n" + lines.joined(separator: "\n"), citations)
    }

    public func queueQuestion(_ request: AskRequest) {
        queue.removeAll { $0.requestId == request.requestId }
        queue.append(request)
    }

    public func queuedQuestions() -> [AskRequest] { queue }

    public func askHistory(limit: Int) -> [AskExchange] { Array(history.prefix(limit)) }

    // MARK: Pairing and sync

    public func pair(payload: String) throws -> PairedMac {
        _ = try PairingPayload.parse(payload)
        throw CompanionStoreError.pairingUnavailable
    }

    public func pairedMac() -> PairedMac? {
        guard let paired = configuration.pairedStatus, paired.paired else { return nil }
        return PairedMac(macName: paired.macName ?? "Mac", macKeyB64: "", addresses: paired.lastAddress.map { [$0] } ?? [],
                         port: 17890, pairedAt: configuration.now().addingTimeInterval(-86_400 * 9))
    }

    public func sync(extraAddresses: [String]) async throws -> SyncReport {
        guard syncStatus.paired else {
            if configuration.pairedStatus == nil { return SyncReport(finishedAt: configuration.now()) }
            throw CompanionStoreError.notPaired
        }
        guard configuration.macReachable else { throw CompanionStoreError.unreachable }
        try await Task.sleep(for: .milliseconds(400))
        let applied = pendingActions.count
        pendingActions.removeAll()
        syncStatus.lastSyncAt = configuration.now()
        syncStatus.pendingOps = 0
        return SyncReport(opsApplied: applied, cursor: syncStatus.cursor, address: syncStatus.lastAddress, finishedAt: configuration.now())
    }

    public func unpair() {
        records = [:]
        pendingActions = []
        queue = []
        history = []
        syncStatus = .unpaired
        configuration.pairedStatus = nil
    }

    public func status() -> SyncStatus {
        var status = syncStatus
        status.pendingOps = pendingActions.count
        return status
    }

    public func loadSampleLibrary() throws {
        records = [:]
        Self.ingest(try SampleLibrary.envelopes(), into: &records)
    }

    public func isSample() -> Bool { configuration.pairedStatus == nil && !records.isEmpty }
}

/// The bundled sample library.
public enum SampleLibrary {
    public static var url: URL? { Bundle.module.url(forResource: "sample-library", withExtension: "json") }

    public static func json() throws -> String {
        guard let url else { throw CompanionStoreError.failed("The sample library is missing from this build.") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func envelopes() throws -> [RecordEnvelope] {
        try CompanionJSON.decode([RecordEnvelope].self, from: json())
    }

    /// When the sample library was made (its manifest's `generatedAt`): the
    /// sample's "today", so it reads the same whenever it is opened.
    public static let referenceDate: Date = {
        let manifest = (try? envelopes())?.lazy.compactMap { envelope -> Manifest? in
            if case .manifest(let manifest) = envelope.body { manifest } else { nil }
        }.first
        return manifest?.generatedAt ?? Date()
    }()
}
