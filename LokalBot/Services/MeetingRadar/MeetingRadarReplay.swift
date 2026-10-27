import Foundation

/// `LokalBot --radar-replay <fixture.json> [--model <id>] [--interval <s>] [--delay <s>]`
///
/// Replays a timed transcript through Live Radar's request, grounding checks,
/// and Meta Model API client, and prints one JSON line per pass and a summary.
/// A line becomes visible `delay` seconds after it starts (the live preview's
/// chunking), and a pass runs every `interval` seconds of meeting time, as in
/// the app. Earlier-meeting passages come from the fixture instead of the
/// library, so a run is reproducible. For public or synthetic transcripts
/// only: the key is read from `META_API_KEY`, never from the Keychain, and
/// nothing is read from or written to a library.
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

    static func parse(_ args: [String]) -> (input: URL, model: String, interval: Double, delay: Double)? {
        guard let flag = args.firstIndex(of: "--radar-replay"), args.count > flag + 1 else { return nil }
        func value(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        }
        return (URL(fileURLWithPath: args[flag + 1]),
                value("--model") ?? MetaModelAPI.museSpark.id,
                value("--interval").flatMap(Double.init).map { max(1, $0) } ?? 20,
                value("--delay").flatMap(Double.init).map { max(0, $0) } ?? 12)
    }

    @MainActor
    static func run(input: URL, model: String, interval: Double, delay: Double) async -> Int32 {
        let key = ProcessInfo.processInfo.environment["META_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            FileHandle.standardError.write(Data("radar-replay: set META_API_KEY\n".utf8))
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
        let client = MuseChatClient(apiKey: key, model: model, reasoningEffort: "minimal", maxTokens: 4_000,
                                    priority: .interactive, purpose: "radar replay")
        let meetingID = UUID()
        let lines = fixture.lines.enumerated().map { index, line in
            MeetingRadarAnalyzer.Line(label: "L\(index + 1)", time: line.time, speaker: line.speaker, text: line.text)
        }
        let excerpts = (fixture.earlier ?? []).enumerated().map { index, passage in
            MeetingRadarAnalyzer.Excerpt(label: "E\(index + 1)", evidence: RadarEvidence(
                meetingID: UUID(), meetingTitle: passage.title, meetingDate: passage.date,
                time: passage.time, speaker: passage.speaker, text: passage.text))
        }

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
                    messages: [["role": "system", "content": MeetingRadarAnalyzer.system],
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
            ] as [String: Any],
        ]
        print(json(summary))
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

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
