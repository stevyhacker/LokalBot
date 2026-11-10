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
/// preview, and every pass gives only the lines that arrived since the last
/// one (plus a little context, what is already on the radar, and passages
/// local search found in earlier meetings) to the Think model chosen in
/// Settings → Models, under that model's own local or remote setting.
/// Passes run about every 20 s, or after each turn when fast live text
/// streams the transcript from Muse Voice Transcribe. Speaker separation
/// stays on this Mac, and audio does too unless fast live text is on.
///
/// Radar starts only when the person presses Start Radar during a recording,
/// and only once Live Radar is turned on in Settings. It stops with the
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
    /// The Think engine for one request, as Settings → Models has it now.
    typealias EngineSource = @MainActor (_ purpose: String) async throws -> TextEngine

    /// A pass lists what it caught as short items and doesn't reason first.
    static let passOptions = TextGenerationOptions(maxTokens: 2_000, reasoningBudgetTokens: 0, temperature: 0)
    /// A live answer is one tool call per turn, with a little room to choose it.
    static let answerOptions = TextGenerationOptions(maxTokens: 1_500, reasoningBudgetTokens: 256, temperature: 0.1)

    @Published private(set) var items: [RadarItem] = []
    @Published private(set) var state: State = .off
    @Published private(set) var isAnalyzing = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var totals = Totals()
    @Published private(set) var meetingID: Meeting.ID?
    /// The name of the model reading this meeting, for the panel and `radar.json`.
    @Published private(set) var model = ""
    /// The item that changed last: the newest one a pass added, or the
    /// question that just got an answer. The floating panel shows it.
    @Published private(set) var spotlightID: String?
    /// What live answers is doing for each question it is looking up.
    @Published private(set) var answerSteps: [String: String] = [:]

    var isActive: Bool { state == .running || state == .finishing }

    static let maximumNewLinesPerPass = 40
    static let contextLines = 24
    static let evidenceLimit = 6
    static let maximumConsecutiveFailures = 3
    /// How long a question that just got an answer keeps the spotlight
    /// before a newer item takes it, so the answer can be read during the
    /// call. A contradiction still takes it at once.
    static let answerSpotlightHold: TimeInterval = 12

    private let transcriber: RadarLineFeed
    private let evidenceSource: RadarEvidenceSource
    private let screenSource: RadarScreenSource?
    private let answerEnvironment: LiveAnswerEnvironment?
    private let answerCall: LiveAnswerSession.Call
    private let settings: () -> AppSettings
    private let call: ModelCall
    private let modelName: (AppSettings) -> String
    /// Whether a screen answer's request carries the crops as pictures. The
    /// Think model reads the text of each crop instead.
    private let sendsScreenCrops: Bool
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
    /// Screen answers in flight, by question item id.
    private var answerTasks: [String: Task<Void, Never>] = [:]
    /// Changes when answers are cancelled, so a late reply can't land in the
    /// next meeting. `finish()` keeps it, so answers still arriving are saved.
    private var answerEpoch = 0
    private var spotlightHeldUntil: Date?

    /// Passes and live answers run on `engine`, the Think model, unless a
    /// caller supplies `call` or `answerCall` itself (tests, and the hosted
    /// film of the feature).
    init(transcriber: RadarLineFeed,
         evidenceSource: RadarEvidenceSource,
         screenSource: RadarScreenSource? = nil,
         answerEnvironment: LiveAnswerEnvironment? = nil,
         answerCall: LiveAnswerSession.Call? = nil,
         settings: @escaping () -> AppSettings,
         engine: EngineSource? = nil,
         call: ModelCall? = nil,
         modelName: @escaping (AppSettings) -> String = { $0.thinkModelDisplayName },
         sendsScreenCrops: Bool = false,
         availability: @escaping (AppSettings) -> String? = MeetingRadar.unavailableReason,
         timing: Timing = Timing(),
         now: @escaping () -> Date = Date.init) {
        self.transcriber = transcriber
        self.evidenceSource = evidenceSource
        self.screenSource = screenSource
        self.answerEnvironment = answerEnvironment
        self.answerCall = answerCall ?? { messages, tools, _ in
            guard let engine else { throw TextEngineError.unavailable("Live Radar has no Think model to ask.") }
            return try await ThinkChat.toolCall(from: try await engine("live answer"), messages: messages,
                                                tools: tools, options: Self.answerOptions)
        }
        self.settings = settings
        self.modelName = modelName
        self.sendsScreenCrops = sendsScreenCrops
        self.availability = availability
        self.timing = timing
        self.now = now
        self.call = call ?? { messages, schema, _ in
            guard let engine else { throw TextEngineError.unavailable("Live Radar has no Think model to ask.") }
            return try await ThinkChat.structuredReply(from: try await engine("live radar"), messages: messages,
                                                       schema: schema, options: Self.passOptions)
        }
    }

    /// Why Start Radar can't run, or nil when it can. Live Radar is offered
    /// only once it is turned on in Settings; after that the Think model's
    /// own setup decides, and a request it refuses shows as the radar's error.
    static func unavailableReason(_ settings: AppSettings) -> String? {
        settings.liveRadarEnabled ? nil : String(localized: "Turn on Live Radar in Settings → Meetings.")
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
        if screenSource != nil, settings().museScreenAnswersEnabled {
            Task.detached(priority: .utility) { RadarScreenAnswers.warmUp() }
        }
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
        cancelAnswers()
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
        for task in answerTasks.values { await task.value }
        save()
        if generation == session { state = .off }
        statusMessage = nil
    }

    // MARK: - Lines

    private func reset(for meeting: Meeting?, folder: URL?) {
        cancelLoop()
        cancelAnswers()
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
        model = modelName(settings())
        let saved = folder.flatMap(MeetingRadarRecord.load(from:))
        record = saved ?? MeetingRadarRecord(model: model)
        items = record?.items ?? []
        spotlightID = nil
        spotlightHeldUntil = nil
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
            if let newest = outcome.added.first(where: { $0.kind == .contradiction }) ?? outcome.added.last,
               newest.kind == .contradiction || spotlightHeldUntil.map({ now() >= $0 }) ?? true {
                spotlightID = newest.id
            }
            if screenSource != nil, settings().museScreenAnswersEnabled {
                for question in outcome.added where question.kind == .question { answerFromScreen(question) }
            }
            if answerEnvironment != nil, settings().liveAnswersEnabled {
                for question in outcome.added where question.kind == .question { answerLive(question) }
            }
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

    // MARK: - Screen answers

    private func cancelAnswers() {
        answerTasks.values.forEach { $0.cancel() }
        answerTasks = [:]
        answerSteps = [:]
        answerEpoch += 1
    }

    /// Looks for the answer to a question the radar just caught in earlier
    /// screen captures: local search and cropping on this Mac, then one
    /// request with the text of up to three crops. Runs beside the passes.
    private func answerFromScreen(_ question: RadarItem) {
        guard let screenSource, let meeting, let folder, answerTasks[question.id] == nil else { return }
        let model = model, call = call, epoch = answerEpoch, sendsScreenCrops = sendsScreenCrops
        let asked = RadarScreenAnswers.question(question)
        answerTasks[question.id] = Task { [weak self] in
            let crops = await RadarScreenAnswers.crops(for: asked, from: screenSource)
            guard !crops.isEmpty, !Task.isCancelled else { return }
            let started = ContinuousClock.now
            do {
                let messages = sendsScreenCrops
                    ? RadarScreenAnswers.messages(question: asked, meetingTitle: meeting.displayTitle,
                                                  meetingDate: meeting.startedAt, crops: crops)
                    : RadarScreenAnswers.textMessages(question: asked, meetingTitle: meeting.displayTitle,
                                                      meetingDate: meeting.startedAt, crops: crops)
                let reply = try await call(messages, RadarScreenAnswers.schema, model)
                guard let self, self.answerEpoch == epoch else { return }
                self.recordScreenAnswer(reply, crops: crops, question: question.id, folder: folder,
                                        model: model, started: started)
            } catch {
                lokalbotLog("live radar screen answer failed error=\(error.localizedDescription)")
            }
        }
    }

    private func recordScreenAnswer(_ reply: MuseChatClient.Reply,
                                    crops: [(capture: RadarScreenCapture, crop: RadarScreenCrop)],
                                    question id: String, folder: URL, model: String, started: ContinuousClock.Instant) {
        let elapsed = (ContinuousClock.now - started).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let found = RadarScreenAnswers.answer(from: reply.content, crops: crops.map(\.crop))
        var stored: RadarScreenAnswer?
        if let found, let index = items.firstIndex(where: { $0.id == id }) {
            let capture = crops[found.index].capture
            let name = "\(RadarScreenAnswers.folderName)/\(id).jpg"
            do {
                let directory = folder.appendingPathComponent(RadarScreenAnswers.folderName, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try crops[found.index].crop.jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)
                stored = RadarScreenAnswer(text: found.text, quote: found.quote, snapshotID: capture.snapshotID,
                                           capturedAt: capture.capturedAt, app: capture.app,
                                           windowTitle: capture.windowTitle, image: name, model: model)
                items[index].screenAnswer = stored
                spotlight(answered: id)
            } catch {
                lokalbotLog("live radar screen answer save failed error=\(error.localizedDescription)")
            }
        }
        let request = RadarPass(
            at: now(), seconds: seconds, newLines: 0, evidence: crops.count,
            inputTokens: reply.usage.inputTokens, outputTokens: reply.usage.outputTokens,
            reasoningTokens: reply.usage.reasoningTokens, cost: MetaModelAPI.cost(of: reply.usage, model: model),
            added: stored == nil ? 0 : 1, rejected: found == nil ? 1 : 0)
        let earlier = record?.screenAnswerRequests ?? []
        record?.screenAnswerRequests = earlier + [request]
        totals.cost += request.cost
        answerTasks[id] = nil
        lokalbotLog("live radar screen answer crops=\(crops.count) found=\(stored != nil) "
            + "seconds=\(String(format: "%.2f", seconds))")
        save()
    }

    // MARK: - Live answers

    /// Looks for the answer to a question or problem in the person's work:
    /// what LokalBot remembers first, then a few read-only lookups. Runs
    /// beside the passes; the card shows each step while it works.
    private func answerLive(_ question: RadarItem) {
        let key = "live-" + question.id
        guard let answerEnvironment, let meeting, answerTasks[key] == nil else { return }
        let model = model, call = answerCall, epoch = answerEpoch, id = question.id
        let recent = order.suffix(10).compactMap { lines[$0] }.sorted { $0.time < $1.time }
            .map { "\($0.speakerName): \($0.text)" }
        let context = LiveAnswerMeeting(title: meeting.displayTitle, date: meeting.startedAt, recentLines: recent)
        answerSteps[id] = String(localized: "Checking what LokalBot remembers…")
        answerTasks[key] = Task { [weak self] in
            do {
                let outcome = try await LiveAnswerSession.run(
                    question: question.text, quote: question.quote, meeting: context,
                    environment: answerEnvironment, model: model, call: call) { step in
                        guard let self, self.answerEpoch == epoch else { return }
                        self.answerSteps[id] = step
                    }
                guard let self, self.answerEpoch == epoch else { return }
                self.recordLiveAnswer(outcome, question: id, model: model)
            } catch {
                guard let self, self.answerEpoch == epoch else { return }
                self.answerSteps[id] = nil
                self.answerTasks[key] = nil
                if !(error is CancellationError) {
                    lokalbotLog("live answer failed error=\(error.localizedDescription)")
                }
            }
        }
    }

    private func recordLiveAnswer(_ outcome: LiveAnswerSession.Outcome, question id: String, model: String) {
        answerSteps[id] = nil
        answerTasks["live-" + id] = nil
        if let answer = outcome.answer, let index = items.firstIndex(where: { $0.id == id }) {
            items[index].answer = answer
            spotlight(answered: id)
        }
        let request = RadarPass(
            at: now(), seconds: outcome.seconds, newLines: 0, evidence: outcome.turns,
            inputTokens: outcome.usage.inputTokens, outputTokens: outcome.usage.outputTokens,
            reasoningTokens: outcome.usage.reasoningTokens, cost: MetaModelAPI.cost(of: outcome.usage, model: model),
            added: outcome.answer == nil ? 0 : 1, rejected: 0)
        let earlier = record?.answerRequests ?? []
        record?.answerRequests = earlier + [request]
        totals.cost += request.cost
        lokalbotLog("live answer turns=\(outcome.turns) found=\(outcome.answer != nil) "
            + "seconds=\(String(format: "%.2f", outcome.seconds)) reason=\(outcome.reason ?? "-")")
        save()
    }

    private func spotlight(answered id: String) {
        spotlightID = id
        spotlightHeldUntil = now().addingTimeInterval(Self.answerSpotlightHold)
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
