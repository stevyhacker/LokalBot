import Foundation

/// `LokalBot --radar-replay <fixture.json> [--model <id>] [--interval <s>] [--delay <s>]
///   [--base-url <url> [--reasoning-line <level>]] [--audio <folder>] [--screens <folder>]`
///
/// Replays a timed transcript through Live Radar's request, grounding checks,
/// and Meta Model API client, and prints one JSON line per pass and a summary.
/// `--base-url` sends the same requests to another OpenAI-compatible server,
/// such as llama-server running Meta's open-weight Muse Glimmer, which needs
/// no key; `--reasoning-line` then adds the "Reasoning effort: <level>" line
/// that Glimmer's chat template reads from the system prompt.
/// A line becomes visible `delay` seconds after it starts (the live preview's
/// chunking), and a pass runs every `interval` seconds of meeting time, as in
/// the app. Earlier-meeting passages come from the fixture instead of the
/// library, so a run is reproducible. For public or synthetic transcripts
/// only: the key is read from `META_API_KEY`, never from the Keychain, and
/// nothing is read from or written to a library.
///
/// `--audio` replays the meeting as fast live text does, in real time: the
/// folder's `me.wav` and `them.wav` (from `Benchmarks/MuseRadar/voice_fixture.py`)
/// stream to Muse Voice Transcribe through the app's client, each finished
/// turn becomes a line, and a pass follows each turn (`--interval` defaults
/// to the app's 3 s turn interval). Times are measured on the wall clock.
///
/// `--screens` adds screen answers: the folder's `screens.json` lists
/// synthetic captures (`file`, `capturedAt`, `app`, `windowTitle`), and each
/// question the radar catches is answered from them as the app does from
/// screen memory, with the crops made by Vision on this Mac.
enum MeetingRadarReplay {
    struct Fixture: Decodable {
        struct Line: Decodable {
            let time: Double
            let speaker: String
            let text: String
        }

        struct Passage: Decodable {
            let title: String
            let date: Date
            let time: Double?
            let speaker: String?
            let text: String
        }

        let id: String?
        let title: String
        let date: Date
        let attendees: [String]?
        let lines: [Line]
        let earlier: [Passage]?
    }

    struct Options {
        var input: URL
        var model: String
        var interval: Double
        var delay: Double
        var baseURL: URL?
        var reasoningLine: String?
        var audio: URL?
        var screens: URL?
    }

    /// Captures from a fixture folder instead of screen memory.
    @MainActor
    final class FixtureScreens: RadarScreenSource {
        struct Entry: Decodable {
            let file: String
            let capturedAt: Date
            let app: String
            let windowTitle: String
        }

        let captures: [RadarScreenCapture]

        init(folder: URL) throws {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entries = try decoder.decode([Entry].self, from: Data(contentsOf: folder.appendingPathComponent("screens.json")))
            captures = entries.enumerated().map { index, entry in
                let url = folder.appendingPathComponent(entry.file)
                return RadarScreenCapture(snapshotID: Int64(index + 1), capturedAt: entry.capturedAt, app: entry.app,
                                          windowTitle: entry.windowTitle, imageData: { try? Data(contentsOf: url) })
            }
        }

        func captures(for question: String, before: Date, limit: Int) async -> [RadarScreenCapture] {
            Array(captures.filter { $0.capturedAt < before }.prefix(limit))
        }
    }

    static func parse(_ args: [String]) -> Options? {
        guard let flag = args.firstIndex(of: "--radar-replay"), args.count > flag + 1 else { return nil }
        func value(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        }
        let audio = value("--audio").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let turnInterval = Double(MeetingRadar.Timing().turnInterval.components.seconds)
        return Options(input: URL(fileURLWithPath: args[flag + 1]),
                       model: value("--model") ?? MetaModelAPI.museSpark.id,
                       interval: value("--interval").flatMap(Double.init).map { max(1, $0) }
                           ?? (audio == nil ? 20 : turnInterval),
                       delay: value("--delay").flatMap(Double.init).map { max(0, $0) } ?? 12,
                       baseURL: value("--base-url").flatMap(URL.init(string:)),
                       reasoningLine: value("--reasoning-line"),
                       audio: audio,
                       screens: value("--screens").map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    @MainActor
    static func run(_ options: Options) async -> Int32 {
        let (input, model, interval, delay) = (options.input, options.model, options.interval, options.delay)
        let key = ProcessInfo.processInfo.environment["META_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty || (options.baseURL != nil && options.audio == nil) else {
            FileHandle.standardError.write(Data("radar-replay: set META_API_KEY (needed for --audio), or pass --base-url\n".utf8))
            return 2
        }
        let fixture: Fixture
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            fixture = try decoder.decode(Fixture.self, from: Data(contentsOf: input))
        } catch {
            FileHandle.standardError.write(Data("radar-replay: \(error.localizedDescription)\n".utf8))
            return 2
        }
        var client = MuseChatClient(apiKey: key.isEmpty ? "local" : key, model: model, reasoningEffort: "minimal",
                                    maxTokens: 4_000, priority: .interactive, purpose: "radar replay")
        if let baseURL = options.baseURL {
            client.baseURL = baseURL
            client.gate = nil
            client.transport = { request in try await sendInferenceRequest(request, base: baseURL) }
        }
        let system = options.reasoningLine.map { "Reasoning effort: \($0)\n\n" + MeetingRadarAnalyzer.system }
            ?? MeetingRadarAnalyzer.system
        let meetingID = UUID()
        var screens: FixtureScreens?
        if let folder = options.screens {
            do {
                screens = try FixtureScreens(folder: folder)
            } catch {
                FileHandle.standardError.write(Data("radar-replay: \(folder.path): \(error.localizedDescription)\n".utf8))
                return 2
            }
        }
        let answers = ScreenAnswerRuns(screens: screens, client: client, fixture: fixture)
        if let audio = options.audio {
            return await runLive(options, audio: audio, fixture: fixture, client: client, system: system,
                                 meetingID: meetingID, excerpts: excerpts(fixture), key: key, answers: answers)
        }
        let lines = fixture.lines.enumerated().map { index, line in
            MeetingRadarAnalyzer.Line(label: "L\(index + 1)", time: line.time, speaker: line.speaker, text: line.text)
        }
        let excerpts = excerpts(fixture)

        var items: [RadarItem] = []
        var analyzed: [MeetingRadarAnalyzer.Line] = []
        var nextID = 0
        var passes: [[String: Any]] = []
        var failures = 0
        let end = (lines.map(\.time).max() ?? 0) + delay
        var clock = interval
        while analyzed.count < lines.count {
            let cutoff = clock >= end ? .infinity : clock
            let analyzedLabels = Set(analyzed.map(\.label))
            let fresh = Array(lines.filter { !analyzedLabels.contains($0.label) && $0.time + delay <= cutoff }
                .prefix(MeetingRadar.maximumNewLinesPerPass))
            defer { clock += interval }
            guard !fresh.isEmpty else { continue }
            let request = MeetingRadarAnalyzer.Request(
                meetingID: meetingID, meetingTitle: fixture.title, meetingDate: fixture.date,
                attendees: fixture.attendees ?? [], existing: items,
                earlierLines: Array(analyzed.suffix(MeetingRadar.contextLines)), newLines: fresh, excerpts: excerpts)
            let started = ContinuousClock.now
            do {
                let reply = try await client.send(
                    messages: [["role": "system", "content": system],
                               ["role": "user", "content": MeetingRadarAnalyzer.prompt(request)]],
                    schema: (name: "radar", schema: MeetingRadarAnalyzer.schema))
                let elapsed = (ContinuousClock.now - started).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let outcome = MeetingRadarAnalyzer.apply(reply: reply.content, to: request, nextID: &nextID, model: model)
                for id in outcome.answeredIDs {
                    if let index = items.firstIndex(where: { $0.id == id }) { items[index].answered = true }
                }
                // Simulated meeting time at which the person would see each item.
                let shownAt = min(clock, end) + seconds
                items += outcome.added
                for question in outcome.added where question.kind == .question {
                    await answers.answer(question)?.value
                }
                analyzed += fresh
                let pass: [String: Any] = [
                    "pass": passes.count + 1, "at": min(clock, end), "newLines": fresh.count,
                    "seconds": seconds, "inputTokens": reply.usage.inputTokens,
                    "cachedInputTokens": reply.usage.cachedInputTokens,
                    "outputTokens": reply.usage.outputTokens, "reasoningTokens": reply.usage.reasoningTokens,
                    "cost": MetaModelAPI.cost(of: reply.usage, model: model), "rejected": outcome.rejected,
                    "answered": outcome.answeredIDs,
                    "added": outcome.added.map { describe($0, shownAt: shownAt) },
                ]
                passes.append(pass)
                print(json(pass))
            } catch {
                failures += 1
                FileHandle.standardError.write(Data("radar-replay pass failed: \(error.localizedDescription)\n".utf8))
                if failures >= 3 { return 1 }
                clock -= interval // retry the same window
            }
        }
        let seconds = passes.compactMap { $0["seconds"] as? Double }.sorted()
        let delays = passes.flatMap { ($0["added"] as? [[String: Any]]) ?? [] }.compactMap { $0["shownAfter"] as? Double }
        var byKind: [String: Int] = [:]
        for item in items { byKind[item.kind.rawValue, default: 0] += 1 }
        let summary: [String: Any] = [
            "summary": [
                "id": fixture.id ?? input.deletingPathExtension().lastPathComponent,
                "model": model, "interval": interval, "delay": delay, "lines": lines.count,
                "passes": passes.count, "failedRequests": failures,
                "items": items.map { describe($0, shownAt: nil) }, "byKind": byKind,
                "rejected": passes.reduce(0) { $0 + ($1["rejected"] as? Int ?? 0) },
                "cost": passes.reduce(0.0) { $0 + ($1["cost"] as? Double ?? 0) },
                "passSecondsMedian": seconds.isEmpty ? 0 : seconds[seconds.count / 2],
                "passSecondsMax": seconds.last ?? 0,
                "shownAfterMedian": delays.isEmpty ? 0 : delays.sorted()[delays.count / 2],
                "screenAnswers": answers.results,
            ] as [String: Any],
        ]
        print(json(summary))
        return 0
    }

    /// Screen answers for a replay: the app's search-and-crop step and
    /// grounding check, run against fixture captures. Each result is printed
    /// as a `screenAnswer` line and kept for the summary.
    @MainActor
    final class ScreenAnswerRuns {
        let screens: FixtureScreens?
        let client: MuseChatClient
        let fixture: Fixture
        private(set) var results: [[String: Any]] = []
        private var tasks: [Task<Void, Never>] = []

        init(screens: FixtureScreens?, client: MuseChatClient, fixture: Fixture) {
            self.screens = screens
            self.client = client
            self.fixture = fixture
        }

        /// Nil without `--screens`. `elapsed` gives the wall-clock delay from
        /// the question to the answer; without it the request time is used.
        @discardableResult
        func answer(_ question: RadarItem, elapsed: (@MainActor () -> Double)? = nil) -> Task<Void, Never>? {
            guard let screens else { return nil }
            let task = Task { @MainActor in
                let asked = RadarScreenAnswers.question(question)
                let started = ContinuousClock.now
                let crops = await RadarScreenAnswers.crops(for: asked, from: screens, before: fixture.date)
                let cropping = (ContinuousClock.now - started).components
                var result: [String: Any] = ["question": question.text, "crops": crops.count,
                                             "cropSeconds": Double(cropping.seconds) + Double(cropping.attoseconds) / 1e18]
                if !crops.isEmpty {
                    do {
                        var request = client
                        request.purpose = "radar replay screen answer"
                        let reply = try await request.send(
                            messages: RadarScreenAnswers.messages(question: asked, meetingTitle: fixture.title,
                                                                  meetingDate: fixture.date, crops: crops),
                            schema: (name: "screen_answer", schema: RadarScreenAnswers.schema))
                        result["reply"] = reply.content
                        result["cost"] = MetaModelAPI.cost(of: reply.usage, model: client.model)
                        if let found = RadarScreenAnswers.answer(from: reply.content, crops: crops.map(\.crop)) {
                            result["answer"] = found.text
                            result["quote"] = found.quote
                            result["app"] = crops[found.index].capture.app
                        }
                    } catch {
                        result["error"] = error.localizedDescription
                    }
                }
                let duration = (ContinuousClock.now - started).components
                result["seconds"] = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                if let elapsed { result["answeredAfter"] = elapsed() }
                results.append(result)
                print(MeetingRadarReplay.json(["screenAnswer": result]))
            }
            tasks.append(task)
            return task
        }

        func waitForAll() async {
            for task in tasks { await task.value }
        }
    }

    private static func excerpts(_ fixture: Fixture) -> [MeetingRadarAnalyzer.Excerpt] {
        (fixture.earlier ?? []).enumerated().map { index, passage in
            MeetingRadarAnalyzer.Excerpt(label: "E\(index + 1)", evidence: RadarEvidence(
                meetingID: UUID(), meetingTitle: passage.title, meetingDate: passage.date,
                time: passage.time, speaker: passage.speaker, text: passage.text))
        }
    }

    /// Lines from the realtime sessions, kept on the main actor.
    @MainActor
    private final class LiveLines {
        var started: ContinuousClock.Instant?
        var pending: [MeetingRadarAnalyzer.Line] = []
        var arrivals: [[String: Any]] = []
        var count = 0
        var finishedTracks = 0

        var seconds: Double {
            guard let started else { return 0 }
            let elapsed = (ContinuousClock.now - started).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }

        func add(time: Double, speaker: String, text: String) {
            count += 1
            pending.append(.init(label: "L\(count)", time: time, speaker: speaker, text: text))
            arrivals.append(["line": "L\(count)", "speaker": speaker, "time": time, "arrivedAt": seconds, "text": text])
        }
    }

    @MainActor
    private static func runLive(_ options: Options, audio: URL, fixture: Fixture, client: MuseChatClient,
                                system: String, meetingID: UUID, excerpts: [MeetingRadarAnalyzer.Excerpt],
                                key: String, answers: ScreenAnswerRuns) async -> Int32 {
        let tracks = [("local", audio.appendingPathComponent("me.wav")), ("them", audio.appendingPathComponent("them.wav"))]
        let duration = tracks.compactMap { try? MuseLiveTextTrack.length(of: $0.1) }.max().map { Double($0) / MuseLiveText.sampleRate }
        guard let duration else {
            FileHandle.standardError.write(Data("radar-replay: \(audio.path) needs me.wav and them.wav at 16 kHz mono\n".utf8))
            return 2
        }
        let live = LiveLines()
        let streams = tracks.map { speaker, url in
            Task { @MainActor in
                // About one frame of lead, as from a live microphone.
                let track = MuseLiveTextTrack(source: url, startFrame: 0, leadSeconds: 0.1)
                do {
                    try await track.run(key: key, keywords: [], resumeFrom: nil) { output in
                        switch output {
                        case .connected: if live.started == nil { live.started = .now }
                        case .line(let time, let text): live.add(time: time, speaker: speaker, text: text)
                        default: break
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        FileHandle.standardError.write(Data("radar-replay: \(speaker) audio: \(error.localizedDescription)\n".utf8))
                    }
                }
                live.finishedTracks += 1
            }
        }
        var items: [RadarItem] = []
        var analyzed: [MeetingRadarAnalyzer.Line] = []
        var nextID = 0
        var passes: [[String: Any]] = []
        var failures = 0
        var lastPass: Double?
        var stopped = false
        while true {
            let now = live.seconds
            if !stopped, live.started != nil, now > duration + 6 {
                streams.forEach { $0.cancel() }
                stopped = true
            }
            let due = lastPass.map { now - $0 >= options.interval } ?? true
            guard !live.pending.isEmpty, due else {
                if (stopped || live.finishedTracks == tracks.count) && live.pending.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let fresh = Array(live.pending.prefix(MeetingRadar.maximumNewLinesPerPass)).sorted { $0.time < $1.time }
            lastPass = now
            let request = MeetingRadarAnalyzer.Request(
                meetingID: meetingID, meetingTitle: fixture.title, meetingDate: fixture.date,
                attendees: fixture.attendees ?? [], existing: items,
                earlierLines: Array(analyzed.suffix(MeetingRadar.contextLines)), newLines: fresh, excerpts: excerpts)
            let started = ContinuousClock.now
            do {
                let reply = try await client.send(
                    messages: [["role": "system", "content": system],
                               ["role": "user", "content": MeetingRadarAnalyzer.prompt(request)]],
                    schema: (name: "radar", schema: MeetingRadarAnalyzer.schema))
                let elapsed = (ContinuousClock.now - started).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let outcome = MeetingRadarAnalyzer.apply(reply: reply.content, to: request, nextID: &nextID, model: options.model)
                for id in outcome.answeredIDs {
                    if let index = items.firstIndex(where: { $0.id == id }) { items[index].answered = true }
                }
                items += outcome.added
                for question in outcome.added where question.kind == .question {
                    // Beside the passes, as in the app, timed on the wall clock.
                    answers.answer(question) { live.seconds - question.time }
                }
                analyzed += fresh
                let consumed = Set(fresh.map(\.label))
                live.pending.removeAll { consumed.contains($0.label) }
                failures = 0
                let pass: [String: Any] = [
                    "pass": passes.count + 1, "at": now, "newLines": fresh.count, "seconds": seconds,
                    "inputTokens": reply.usage.inputTokens, "cachedInputTokens": reply.usage.cachedInputTokens,
                    "outputTokens": reply.usage.outputTokens, "reasoningTokens": reply.usage.reasoningTokens,
                    "cost": MetaModelAPI.cost(of: reply.usage, model: options.model), "rejected": outcome.rejected,
                    "answered": outcome.answeredIDs,
                    "added": outcome.added.map { describe($0, shownAt: live.seconds) },
                ]
                passes.append(pass)
                print(json(pass))
            } catch {
                failures += 1
                FileHandle.standardError.write(Data("radar-replay pass failed: \(error.localizedDescription)\n".utf8))
                if failures >= 3 {
                    streams.forEach { $0.cancel() }
                    return 1
                }
            }
        }
        await answers.waitForAll()
        let seconds = passes.compactMap { $0["seconds"] as? Double }.sorted()
        let delays = passes.flatMap { ($0["added"] as? [[String: Any]]) ?? [] }.compactMap { $0["shownAfter"] as? Double }.sorted()
        var byKind: [String: Int] = [:]
        for item in items { byKind[item.kind.rawValue, default: 0] += 1 }
        print(json(["summary": [
            "screenAnswers": answers.results,
            "id": fixture.id ?? options.input.deletingPathExtension().lastPathComponent,
            "model": options.model, "mode": "audio", "transcription": MuseLiveText.model,
            "interval": options.interval, "audioSeconds": duration, "lines": live.count,
            "passes": passes.count, "failedRequests": failures,
            "items": items.map { describe($0, shownAt: nil) }, "byKind": byKind,
            "rejected": passes.reduce(0) { $0 + ($1["rejected"] as? Int ?? 0) },
            "cost": passes.reduce(0.0) { $0 + ($1["cost"] as? Double ?? 0) },
            "passSecondsMedian": seconds.isEmpty ? 0 : seconds[seconds.count / 2],
            "passSecondsMax": seconds.last ?? 0,
            "shownAfterMedian": delays.isEmpty ? 0 : delays[delays.count / 2],
            "arrivals": live.arrivals,
        ] as [String: Any]]))
        return 0
    }

    private static func describe(_ item: RadarItem, shownAt: Double?) -> [String: Any] {
        var result: [String: Any] = ["id": item.id, "kind": item.kind.rawValue, "text": item.text,
                                     "quote": item.quote, "time": item.time, "answered": item.answered]
        if let owner = item.owner { result["owner"] = owner }
        if let due = item.due { result["due"] = due }
        if let earlier = item.earlier { result["earlier"] = earlier.isCurrentMeeting ? "this meeting" : earlier.meetingTitle }
        if let shownAt { result["shownAfter"] = max(0, shownAt - item.time) }
        return result
    }

    fileprivate static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
