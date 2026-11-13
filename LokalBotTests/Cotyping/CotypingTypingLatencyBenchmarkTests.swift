import XCTest
@testable import LokalBot

/// Opt-in: replays typing one keystroke at a time through the in-process model
/// and reports how long each suggestion takes and how many prompt tokens had to
/// be decoded again. Skipped unless a model is named:
///
///     TEST_RUNNER_LOKALBOT_COTYPING_LATENCY_MODEL=/path/to/model.gguf \
///     xcodebuild test-without-building ... \
///       -only-testing:LokalBotTests/CotypingTypingLatencyBenchmarkTests
@MainActor
final class CotypingTypingLatencyBenchmarkTests: XCTestCase {
    private static let reply = "Hi Marko, thanks for sending the quarterly numbers over. I looked through the revenue section and I think we should move the launch review to Thursday so the design team has time to finish the onboarding flow before we"

    private static let longDraft = String(repeating: "We reviewed the onboarding funnel again this week and found that most people who stop early never reach the second screen, so the design team is testing a shorter welcome flow with fewer questions. ", count: 14)
        + "The next step is to share the results with the sales team and"

    func testTypingLatency() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["LOKALBOT_COTYPING_LATENCY_MODEL"],
              FileManager.default.fileExists(atPath: modelPath) else {
            throw XCTSkip("Set LOKALBOT_COTYPING_LATENCY_MODEL to a GGUF to run this benchmark.")
        }
        let runtime = LlamaCotypingRuntime()
        let engine = LocalLlamaCotypingEngine(runtime: runtime, modelPath: modelPath)
        let loadStart = ContinuousClock.now
        try await engine.prewarm()
        print("cotyping-latency load \(Self.milliseconds(since: loadStart)) ms")

        let visible = "Marko: Here are the Q3 numbers for the review | Marko: Revenue is up 14% but churn in the onboarding cohort is still high | Ana: Can we talk about the launch timeline on Thursday?"
        let facts = [
            "Launch review: moved to Thursday 3pm",
            "Onboarding flow redesign: Ana owns it, due Oct 10",
            "Q3 revenue: up 14% quarter over quarter",
        ]
        let learned = [
            "let me know if that works for everyone",
            "thanks for pulling this together",
            "I'll follow up with the design team",
        ]

        // A comma-separated subset, e.g. "bare,long", runs only those cases.
        let only = environment["LOKALBOT_COTYPING_LATENCY_CASES"].map { Set($0.split(separator: ",").map(String.init)) }
        func wanted(_ key: String) -> Bool { only?.contains(key) ?? true }
        var report: [String] = []
        if wanted("bare") {
            report.append(try await run("bare", text: Self.reply, engine: engine, runtime: runtime) { _ in (nil, nil, []) })
        }
        if wanted("stable") {
            report.append(try await run("stable context", text: Self.reply, engine: engine, runtime: runtime) { _ in
                (visible, facts[0], [learned[0]])
            })
        }
        if wanted("changing") {
            report.append(try await run("context changes per word", text: Self.reply, engine: engine, runtime: runtime) { prefix in
                let words = prefix.split(separator: " ").count
                return (visible, facts[(words / 3) % facts.count], [learned[(words / 4) % learned.count]])
            })
        }
        if wanted("long") {
            report.append(try await run("long draft", text: Self.longDraft, from: Self.longDraft.count - 120,
                                        engine: engine, runtime: runtime) { _ in (nil, nil, []) })
        }
        await engine.unload()
        if let library = environment["LOKALBOT_COTYPING_LATENCY_LIBRARY"] {
            report.append(memoryLookupReport(root: URL(fileURLWithPath: library)))
        }
        print(report.joined(separator: "\n"))
        if let output = environment["LOKALBOT_COTYPING_LATENCY_OUT"] {
            try report.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
        }
    }

    private func run(
        _ name: String,
        text: String,
        from start: Int = 12,
        engine: LocalLlamaCotypingEngine,
        runtime: LlamaCotypingRuntime,
        context: (String) -> (visible: String?, memory: String?, learned: [String])
    ) async throws -> String {
        var latencies: [Double] = []
        var prefills: [Int] = []
        var config = CotypingConfiguration.standard
        config.maxResponseWords = 4
        config.maxResponseTokens = AppSettings().cotypingMaxResponseTokens
        let personalization = CotypingPersonalization(
            userName: nil, styleNote: nil, languageHint: nil, isMultiLine: false,
            appContextEnabled: true, extendedContext: nil)
        let characters = Array(text)
        for end in start...characters.count {
            let prefix = String(characters[..<end])
            let parts = context(prefix)
            let field = CotypingField(
                appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", processID: 0, role: "AXTextArea",
                precedingText: prefix, trailingText: "", selectionLength: 0, caretRect: .zero,
                isSecure: false, caretIsExact: true, windowTitle: "launch-planning")
            guard let request = CotypingRequestBuilder.build(
                field: field, config: config, personalization: personalization, generation: UInt64(end),
                memoryContext: parts.memory, visibleContext: parts.visible, learnedExamples: parts.learned)
            else { continue }
            let started = ContinuousClock.now
            _ = try await engine.generate(request)
            latencies.append(Self.milliseconds(since: started))
            prefills.append(await runtime.lastPrefillTokenCount)
        }
        let sorted = latencies.sorted()
        func percentile(_ p: Double) -> Int { Int(sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]) }
        let heavy = prefills.filter { $0 > 32 }.count
        return "cotyping-latency \(name): n \(sorted.count) median \(percentile(0.5)) p90 \(percentile(0.9)) "
            + "p99 \(percentile(0.99)) max \(Int(sorted.last ?? 0)) ms; "
            + "re-decoded >32 tokens on \(heavy) keystrokes, median \(prefills.sorted()[prefills.count / 2]) tokens"
    }

    /// Saved-memory lookups against a real library, read only, as each
    /// keystroke ran them.
    private func memoryLookupReport(root: URL) -> String {
        let meetings = StorageManager(rootURL: root).loadMeetings()
        var settings = AppSettings()
        settings.cotypingUseMeetingMemory = true
        settings.cotypingUseScreenMemory = true
        settings.cotypingUseAppContext = true
        var timings: [Double] = []
        let characters = Array(Self.reply)
        for end in stride(from: 12, through: characters.count, by: 3) {
            let field = CotypingField(
                appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", processID: 0, role: "AXTextArea",
                precedingText: String(characters[..<end]), trailingText: "", selectionLength: 0, caretRect: .zero,
                isSecure: false, caretIsExact: true, windowTitle: "launch-planning")
            let started = ContinuousClock.now
            _ = CotypingMemoryContextProvider.load(root: root, meetings: meetings, field: field, settings: settings)
            timings.append(Self.milliseconds(since: started))
        }
        let sorted = timings.sorted()
        return "cotyping-latency memory lookup (\(meetings.count) meetings): median \(Int(sorted[sorted.count / 2])) "
            + "p90 \(Int(sorted[sorted.count * 9 / 10])) max \(Int(sorted.last ?? 0)) ms"
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
}
