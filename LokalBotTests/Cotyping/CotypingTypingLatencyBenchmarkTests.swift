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

    /// Opt-in: how long the first suggestion takes after the person stops
    /// typing for a while, against a keystroke while typing. For each pause in
    /// `LOKALBOT_COTYPING_IDLE_GAPS` (seconds, e.g. `0,60,300,1800`) it types a
    /// short burst, waits, times the next keystroke, then the same request
    /// again as the warm reference. The run takes as long as the pauses add
    /// up to, per warm-up mode.
    ///
    /// `LOKALBOT_COTYPING_IDLE_WARMUP` lists warm-up modes (default `none`):
    /// - `none`: nothing runs between the burst and the key.
    /// - `key`: `touch` starts when the key lands and the suggestion is asked
    ///   for 45 ms later, about the app's wait for the field to update plus its
    ///   debounce. Timed from the request, like the others.
    /// - `ahead`: `touch` finishes before the key, as it would from a focus
    ///   change or unlock a moment earlier. Its own time is reported apart.
    /// - `every<N>`: `touch` every N seconds during the pause, e.g. `every120`.
    ///
    /// Use a copy of the GGUF (`cp -c`) that the installed app does not map:
    /// the page cache is per file, and the app's own typing would keep it warm.
    /// `LOKALBOT_COTYPING_IDLE_OUT` appends the report to a file.
    func testFirstSuggestionAfterIdle() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["LOKALBOT_COTYPING_LATENCY_MODEL"],
              FileManager.default.fileExists(atPath: modelPath),
              let gapList = environment["LOKALBOT_COTYPING_IDLE_GAPS"] else {
            throw XCTSkip("Set LOKALBOT_COTYPING_LATENCY_MODEL and LOKALBOT_COTYPING_IDLE_GAPS to run this benchmark.")
        }
        let gaps = gapList.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let modes = (environment["LOKALBOT_COTYPING_IDLE_WARMUP"] ?? "none").split(separator: ",").map(String.init)
        let runtime = LlamaCotypingRuntime.forAutocomplete()
        let engine = LocalLlamaCotypingEngine(runtime: runtime, modelPath: modelPath)
        try await engine.prewarm()
        let keepAlive = environment["GGML_METAL_RESIDENCY_KEEP_ALIVE_S"] ?? "default"
        var lines = ["cotyping-idle model \(URL(fileURLWithPath: modelPath).lastPathComponent), "
            + "metal keep_alive \(keepAlive), \(Self.osVersion)"]
        let characters = Array(Self.reply)
        // Every pause ends on the same keystroke ("…design team has time",
        // suggesting " to review the numbers."), so the work after it is the
        // same in every mode and pause, and the same request right after it is
        // the warm reference. `LOKALBOT_COTYPING_IDLE_KEY` moves it.
        let key = environment["LOKALBOT_COTYPING_IDLE_KEY"].flatMap { Int($0) } ?? 178
        for mode in modes {
            for gap in gaps {
                for end in (key - 8)..<key {
                    _ = try await timedSuggestion(engine, characters, end)
                }
                let touchEvery = mode.hasPrefix("every") ? Double(mode.dropFirst(5)) : nil
                var touches = 0
                let energyBefore = Self.processEnergy()
                let pauseStart = ContinuousClock.now
                while true {
                    let remaining = gap - Self.milliseconds(since: pauseStart) / 1000
                    guard remaining > 0 else { break }
                    let step = min(remaining, touchEvery ?? remaining)
                    try await Task.sleep(for: .milliseconds(Int(step * 1000)))
                    if touchEvery != nil, gap - Self.milliseconds(since: pauseStart) / 1000 > 1 {
                        await runtime.touch()
                        touches += 1
                    }
                }
                let energyAfter = Self.processEnergy()
                let wired = Self.wiredGigabytes()
                let resident = Self.residentFraction(ofFileAt: modelPath)
                var touchMs: Double?
                let first: (ms: Double, text: String)
                switch mode {
                case "key":
                    // Timed from the request, as in the other modes: the 45 ms
                    // before it are spent waiting either way.
                    let touch = Task { await runtime.touch() }
                    try await Task.sleep(for: .milliseconds(45))
                    first = try await timedSuggestion(engine, characters, key)
                    _ = await touch.value
                case "ahead":
                    let started = ContinuousClock.now
                    await runtime.touch()
                    touchMs = Self.milliseconds(since: started)
                    first = try await timedSuggestion(engine, characters, key)
                default:
                    first = try await timedSuggestion(engine, characters, key)
                }
                let firstPrefill = await runtime.lastPrefillTokenCount
                let again = try await timedSuggestion(engine, characters, key)
                lines.append(String(
                    format: "cotyping-idle mode %@ gap %.0f s: first %.0f ms, same key again %.0f ms, "
                        + "touch %@, touches %d, re-decoded %d tokens, model file resident %.0f%%, wired %.1f GB, "
                        + "pause used %.1f mJ CPU, suggestion %@",
                    mode, gap, first.ms, again.ms, touchMs.map { String(format: "%.0f ms", $0) } ?? "-",
                    touches, firstPrefill, resident * 100, wired,
                    energyAfter - energyBefore,
                    first.text == again.text ? first.text.debugDescription : "differs"))
                print(lines.last!)
            }
        }
        await engine.unload()
        let report = lines.joined(separator: "\n") + "\n"
        print(report)
        if let output = environment["LOKALBOT_COTYPING_IDLE_OUT"] {
            let url = URL(fileURLWithPath: output)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(report.utf8))
                try handle.close()
            } else {
                try report.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// One keystroke of `reply` typed up to `end` characters, with the
    /// "stable context" prompt, timed through the engine as the app calls it.
    private func timedSuggestion(
        _ engine: LocalLlamaCotypingEngine, _ characters: [Character], _ end: Int
    ) async throws -> (ms: Double, text: String) {
        var config = CotypingConfiguration.standard
        config.maxResponseWords = 4
        config.maxResponseTokens = AppSettings().cotypingMaxResponseTokens
        let personalization = CotypingPersonalization(
            userName: nil, styleNote: nil, languageHint: nil, isMultiLine: false,
            appContextEnabled: true, extendedContext: nil)
        let field = CotypingField(
            appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", processID: 0, role: "AXTextArea",
            precedingText: String(characters[..<end]), trailingText: "", selectionLength: 0, caretRect: .zero,
            isSecure: false, caretIsExact: true, windowTitle: "launch-planning")
        let request = try XCTUnwrap(CotypingRequestBuilder.build(
            field: field, config: config, personalization: personalization, generation: UInt64(end),
            memoryContext: "Launch review: moved to Thursday 3pm",
            visibleContext: "Marko: Here are the Q3 numbers for the review | Ana: Can we talk about the launch timeline on Thursday?",
            learnedExamples: ["let me know if that works for everyone"]))
        let started = ContinuousClock.now
        let result = try await engine.generate(request)
        return (Self.milliseconds(since: started), result.text)
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// CPU energy the system has charged to this process so far, in mJ.
    private static func processEnergy() -> Double {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        return result == 0 ? Double(usage.ri_energy_nj) / 1e6 : 0
    }

    /// Memory the system cannot page out or compress, all processes.
    private static func wiredGigabytes() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(stats.wire_count) * Double(getpagesize()) / 1e9
    }

    /// Share of the file's pages in memory now. A fresh read-only mapping
    /// shares the file's cached pages and `mincore` reads them without
    /// faulting any in.
    private static func residentFraction(ofFileAt path: String) -> Double {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return 0 }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { return 0 }
        let length = Int(info.st_size)
        guard let mapping = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0),
              mapping != UnsafeMutableRawPointer(bitPattern: -1) else { return 0 }
        defer { munmap(mapping, length) }
        let pageSize = Int(getpagesize())
        let pages = (length + pageSize - 1) / pageSize
        var vector = [CChar](repeating: 0, count: pages)
        guard mincore(mapping, length, &vector) == 0 else { return 0 }
        return Double(vector.filter { $0 & 1 != 0 }.count) / Double(pages)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
}
