import Combine
import Foundation

/// Where the radar's lines come from: the live transcript preview in the
/// app, a scripted feed in tests.
@MainActor
protocol RadarLineFeed: AnyObject {
    var linesPublisher: AnyPublisher<[LiveMeetingTranscriber.Line], Never> { get }
    var currentLines: [LiveMeetingTranscriber.Line] { get }
    var isRunning: Bool { get }
    /// Lines arrive turn by turn, within a second of being said, rather than
    /// in 12-second chunks, so passes can follow each turn.
    var deliversTurns: Bool { get }
    func activatePreview()
}

extension LiveMeetingTranscriber: RadarLineFeed {
    var linesPublisher: AnyPublisher<[Line], Never> { $lines.eraseToAnyPublisher() }
    var currentLines: [Line] { lines }
    var deliversTurns: Bool { engine == .muse }
    func activatePreview() { activate() }
}

/// Live Radar for the meeting being recorded. It reads the live transcript
/// preview, and every pass sends only the lines that arrived since the last
/// one (plus a little context, what is already on the radar, and passages
/// local search found in earlier meetings) to Muse on the Meta Model API.
/// Passes run about every 20 s, or after each turn when fast live text
/// streams the transcript from Muse Voice Transcribe. Speaker separation
/// stays on this Mac, and audio does too unless fast live text is on.
///
/// Radar starts only when the person presses Start Radar during a recording,
/// and only with a key and the api.meta.ai origin approved. It stops with the
/// recording, after one last pass over lines it hasn't read yet, and saves
/// what it found to `radar.json` in the meeting folder.
@MainActor
final class MeetingRadar: ObservableObject {
    enum State: Equatable {
        case off, running, finishing
        case failed(String)
    }

    struct Timing {
        /// Shortest gap between the starts of two passes.
        var minimumInterval: Duration = .seconds(20)
        /// The same gap when the feed delivers turns (fast live text): a
        /// pass follows each finished turn, batching turns that end close together.
        var turnInterval: Duration = .seconds(3)
        /// A burst of speech this long doesn't wait for the interval.
        var burstLines = 10
        var idlePoll: Duration = .seconds(1)
        var retryBase: Duration = .seconds(5)
    }

    struct Totals: Equatable {
        var passes = 0
        var cost = 0.0
        var lastPassSeconds: Double?
    }

    typealias ModelCall = @MainActor (_ messages: [[String: Any]], _ schema: [String: Any], _ model: String)
        async throws -> MuseChatClient.Reply

    @Published private(set) var items: [RadarItem] = []
    @Published private(set) var state: State = .off
    @Published private(set) var isAnalyzing = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var totals = Totals()
    @Published private(set) var meetingID: Meeting.ID?
    @Published private(set) var model = MetaModelAPI.museSpark.id

    var isActive: Bool { state == .running || state == .finishing }

    static let maximumNewLinesPerPass = 40
    static let contextLines = 24
    static let evidenceLimit = 6
    static let maximumConsecutiveFailures = 3

    private let transcriber: RadarLineFeed
    private let evidenceSource: RadarEvidenceSource
    private let settings: () -> AppSettings
    private let call: ModelCall
    private let availability: (AppSettings) -> String?
    private let timing: Timing
    private let now: () -> Date

    private var meeting: Meeting?
    private var folder: URL?
    private var record: MeetingRadarRecord?
    /// Every live line seen this recording, by id. The preview keeps only its
    /// latest 400 and clears them when recording stops; the radar keeps its own.
    private var lines: [UUID: MeetingRadarAnalyzer.Line] = [:]
    private var order: [UUID] = []
    private var pending: [UUID] = []
    private var analyzed: [UUID] = []
    private var nextLineNumber = 0
    private var nextItemNumber = 0
    private var lastPassStart: ContinuousClock.Instant?
    private var failures = 0
    private var retryAfter: ContinuousClock.Instant?
    private var linesSubscription: AnyCancellable?
    private var loop: Task<Void, Never>?
    private var generation = 0

    init(transcriber: RadarLineFeed,
         evidenceSource: RadarEvidenceSource,
         settings: @escaping () -> AppSettings,
         call: ModelCall? = nil,
         availability: @escaping (AppSettings) -> String? = MeetingRadar.unavailableReason,
         timing: Timing = Timing(),
         now: @escaping () -> Date = Date.init) {
        self.transcriber = transcriber
        self.evidenceSource = evidenceSource
        self.settings = settings
        self.availability = availability
        self.timing = timing
        self.now = now
        self.call = call ?? { messages, schema, model in
            let client = try MetaModelAPI.client(
                settings: settings(), model: model, reasoningEffort: "minimal",
                maxTokens: 4_000, priority: .interactive, purpose: "live radar")
            return try await client.send(messages: messages, schema: (name: "radar", schema: schema))
        }
    }

    /// Why Start Radar can't run, or nil when it can.
    static func unavailableReason(_ settings: AppSettings) -> String? {
        if !settings.metaModelAPIApproved { return MetaModelAPI.ConnectionError.notApproved.errorDescription }
        if settings.effectiveMetaModelAPIKey.isEmpty { return MetaModelAPI.ConnectionError.missingKey.errorDescription }
        return nil
    }

    func start(meeting: Meeting, folder: URL) {
        if let reason = availability(settings()) {
            state = .failed(reason)
            statusMessage = reason
            return
        }
        if meetingID != meeting.id { reset(for: meeting, folder: folder) }
        guard state != .running else { return }
        failures = 0
        retryAfter = nil
        statusMessage = nil
        state = .running
        if !transcriber.isRunning { transcriber.activatePreview() }
        linesSubscription = transcriber.linesPublisher.sink { [weak self] lines in
            Task { @MainActor in self?.ingest(lines) }
        }
        ingest(transcriber.currentLines)
        generation += 1
        let session = generation
        loop = Task { [weak self] in await self?.run(session: session) }
    }

    /// The person pressed Stop Radar. Lines not yet read stay unread.
    func stop() {
        cancelLoop()
        linesSubscription = nil
        if state != .off { state = .off }
        statusMessage = nil
        save()
    }

    /// The recording ended or moved to another meeting: read what is left,
    /// save, and turn off.
    func finish() async {
        guard isActive else {
            if case .failed = state { reset(for: nil, folder: nil) }
            return
        }
        cancelLoop()
        linesSubscription = nil
        state = .finishing
        let session = generation
        while !pending.isEmpty, failures < Self.maximumConsecutiveFailures, generation == session {
            await pass(session: session)
        }
        save()
        if generation == session { state = .off }
        statusMessage = nil
    }

    // MARK: - Lines

    private func reset(for meeting: Meeting?, folder: URL?) {
        cancelLoop()
        linesSubscription = nil
        self.meeting = meeting
        self.folder = folder
        meetingID = meeting?.id
        lines = [:]
        order = []
        pending = []
        analyzed = []
        nextLineNumber = 0
        lastPassStart = nil
        failures = 0
        retryAfter = nil
        model = settings().museRadarModel
        let saved = folder.flatMap(MeetingRadarRecord.load(from:))
        record = saved ?? MeetingRadarRecord(model: model)
        items = record?.items ?? []
        nextItemNumber = items.compactMap { Int($0.id.dropFirst()) }.max() ?? 0
        totals = Totals(passes: record?.passes.count ?? 0, cost: record?.cost ?? 0,
                        lastPassSeconds: record?.passes.last?.seconds)
        state = .off
        statusMessage = nil
    }

    private func ingest(_ incoming: [LiveMeetingTranscriber.Line]) {
        guard isActive else { return }
        for line in incoming where lines[line.id] == nil {
            nextLineNumber += 1
            lines[line.id] = MeetingRadarAnalyzer.Line(
                label: "L\(nextLineNumber)", time: line.time, speaker: line.speaker, text: line.text)
            order.append(line.id)
            pending.append(line.id)
        }
    }

    // MARK: - Passes

    private func cancelLoop() {
        loop?.cancel()
        loop = nil
        generation += 1
        isAnalyzing = false
    }

    private func run(session: Int) async {
        while !Task.isCancelled, generation == session, state == .running {
            if shouldPass() {
                await pass(session: session)
                if failures >= Self.maximumConsecutiveFailures, generation == session {
                    let message = "Radar stopped after \(failures) failed requests. \(statusMessage ?? "") "
                        + "Recording continues; press Retry Radar to try again."
                    state = .failed(message)
                    statusMessage = message
                    linesSubscription = nil
                    return
                }
            } else {
                try? await Task.sleep(for: timing.idlePoll)
            }
        }
    }

    private func shouldPass() -> Bool {
        guard !pending.isEmpty else { return false }
        if let retryAfter, ContinuousClock.now < retryAfter { return false }
        guard let lastPassStart else { return true }
        let interval = transcriber.deliversTurns ? timing.turnInterval : timing.minimumInterval
        return pending.count >= timing.burstLines || ContinuousClock.now - lastPassStart >= interval
    }

    private func pass(session: Int) async {
        guard let meeting else { return }
        let batch = Array(pending.prefix(Self.maximumNewLinesPerPass))
        let newLines = batch.compactMap { lines[$0] }.sorted { $0.time < $1.time }
        let earlierLines = analyzed.suffix(Self.contextLines).compactMap { lines[$0] }.sorted { $0.time < $1.time }
        lastPassStart = .now
        isAnalyzing = true
        defer { if generation == session { isAnalyzing = false } }

        let started = ContinuousClock.now
        let evidence = await evidenceSource.evidence(
            for: newLines.map(\.text).joined(separator: " "), meeting: meeting, limit: Self.evidenceLimit)
        guard generation == session else { return }
        var request = MeetingRadarAnalyzer.Request(
            meetingID: meeting.id, meetingTitle: meeting.displayTitle, meetingDate: meeting.startedAt,
            attendees: meeting.resolvedCalendarParticipantIdentities.compactMap(\.suggestedSpeakerName),
            existing: items, earlierLines: earlierLines, newLines: newLines)
        request.excerpts = evidence.enumerated().map { .init(label: "E\($0.offset + 1)", evidence: $0.element) }
        let messages: [[String: Any]] = [
            ["role": "system", "content": MeetingRadarAnalyzer.system],
            ["role": "user", "content": MeetingRadarAnalyzer.prompt(request)],
        ]
        let model = model
        do {
            let reply = try await call(messages, MeetingRadarAnalyzer.schema, model)
            guard generation == session else { return }
            var next = nextItemNumber
            let outcome = MeetingRadarAnalyzer.apply(reply: reply.content, to: request, nextID: &next,
                                                     model: model, now: now())
            nextItemNumber = next
            for id in outcome.answeredIDs {
                if let index = items.firstIndex(where: { $0.id == id }) { items[index].answered = true }
            }
            items.append(contentsOf: outcome.added)
            let consumed = Set(batch)
            pending.removeAll { consumed.contains($0) }
            analyzed.append(contentsOf: batch)
            failures = 0
            retryAfter = nil
            statusMessage = nil
            let elapsed = (ContinuousClock.now - started).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let pass = RadarPass(
                at: now(), seconds: seconds, newLines: newLines.count, evidence: evidence.count,
                inputTokens: reply.usage.inputTokens, outputTokens: reply.usage.outputTokens,
                reasoningTokens: reply.usage.reasoningTokens,
                cost: MetaModelAPI.cost(of: reply.usage, model: model),
                added: outcome.added.count, rejected: outcome.rejected)
            record?.passes.append(pass)
            totals = Totals(passes: totals.passes + 1, cost: totals.cost + pass.cost, lastPassSeconds: seconds)
            lokalbotLog("live radar pass lines=\(newLines.count) evidence=\(evidence.count) "
                + "added=\(outcome.added.count) rejected=\(outcome.rejected) seconds=\(String(format: "%.2f", seconds))")
            save()
        } catch is CancellationError {
            return
        } catch {
            guard generation == session else { return }
            failures += 1
            let delay = timing.retryBase * (1 << min(failures - 1, 4))
            retryAfter = .now + delay
            statusMessage = "Radar request failed: \(error.localizedDescription)"
            lokalbotLog("live radar pass failed attempt=\(failures) error=\(error.localizedDescription)")
        }
    }

    private func save() {
        guard let folder, var record else { return }
        record.items = items
        record.model = model
        self.record = record
        do {
            try record.write(to: folder)
        } catch {
            lokalbotLog("live radar save failed error=\(error.localizedDescription)")
        }
    }
}
