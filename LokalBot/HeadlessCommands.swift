import Foundation
import AVFoundation
import AppKit

enum HeadlessCommand: Equatable {
    case process(folder: URL, transcribe: Bool, summarize: Bool)
    case search(query: String)
    case record(seconds: Int)
    case shotTest
    case digest(dayKey: String?)
    case dream(dayKey: String?)
    case chat(question: String)
    case agent(prompt: String)
    case cotypingBench
    case cotypingEngineBench(model: URL, passes: Int)
    case cotypingReplay(input: URL, engine: CotypingQualityReplay.Engine)
    case cotypingMeasurements
    case eventTaps
    case dictationReplay(input: URL, endpoint: URL)
    case exportDiagnostics(destination: URL)
    case health(dayKey: String?, json: Bool)
    case recordCapture(seconds: Int, scenario: String)
#if LOKALBOT_TEST_HOOKS
    case setBoundaries(folder: URL, start: TimeInterval, end: TimeInterval)
    case searchScreen(query: String)
#endif
    case agentSessions(dayKey: String?)

    @MainActor static var requested: HeadlessCommand?

    static func parse(_ args: [String]) -> HeadlessCommand? {
        if let flag = args.firstIndex(of: "--process"), args.count > flag + 1 {
            return .process(
                folder: URL(fileURLWithPath: args[flag + 1], isDirectory: true),
                transcribe: !args.contains("--summary-only"),
                summarize: !args.contains("--no-summary"))
        }
        if let flag = args.firstIndex(of: "--search"), args.count > flag + 1 {
            return .search(query: args[flag + 1])
        }
        if let flag = args.firstIndex(of: "--record"), args.count > flag + 1,
           let seconds = Int(args[flag + 1]) {
            return .record(seconds: seconds)
        }
        if args.contains("--shot-test") { return .shotTest }
        if let flag = args.firstIndex(of: "--digest") {
            let next = args.count > flag + 1 ? args[flag + 1] : nil
            return .digest(dayKey: next.flatMap { $0.hasPrefix("--") ? nil : $0 })
        }
        if let flag = args.firstIndex(of: "--dream") {
            let next = args.count > flag + 1 ? args[flag + 1] : nil
            return .dream(dayKey: next.flatMap { $0.hasPrefix("--") ? nil : $0 })
        }
        if args.contains("--cotyping-bench") {
            guard let flag = args.firstIndex(of: "--model-path"), args.count > flag + 1 else { return .cotypingBench }
            let passes = args.firstIndex(of: "--passes").flatMap { args.count > $0 + 1 ? Int(args[$0 + 1]) : nil }
            return .cotypingEngineBench(model: URL(fileURLWithPath: args[flag + 1]),
                                        passes: min(20, max(1, passes ?? 5)))
        }
        if args.contains("--cotyping-measurements") { return .cotypingMeasurements }
        if args.contains("--event-taps") { return .eventTaps }
        if let flag = args.firstIndex(of: "--dictation-replay"), args.count > flag + 1,
           let serverFlag = args.firstIndex(of: "--server-url"), args.count > serverFlag + 1,
           let endpoint = URL(string: args[serverFlag + 1]) {
            return .dictationReplay(input: URL(fileURLWithPath: args[flag + 1]), endpoint: endpoint)
        }
        if let flag = args.firstIndex(of: "--cotyping-replay"), args.count > flag + 1,
           let engine = CotypingQualityReplay.Engine.parse(args) {
            return .cotypingReplay(input: URL(fileURLWithPath: args[flag + 1]), engine: engine)
        }
        if args.contains("--health") {
            let dayFlag = args.firstIndex(of: "--day")
            let dayKey = dayFlag.flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
            return .health(dayKey: dayKey, json: args.contains("--json"))
        }
        if let flag = args.firstIndex(of: "--export-diagnostics"), args.count > flag + 1 {
            return .exportDiagnostics(destination: URL(fileURLWithPath: args[flag + 1]))
        }
#if LOKALBOT_TEST_HOOKS
        if let flag = args.firstIndex(of: "--set-boundaries"), args.count > flag + 3,
           let start = TimeInterval(args[flag + 2]), let end = TimeInterval(args[flag + 3]) {
            return .setBoundaries(folder: URL(fileURLWithPath: args[flag + 1], isDirectory: true), start: start, end: end)
        }
        if let flag = args.firstIndex(of: "--search-screen"), args.count > flag + 1 {
            return .searchScreen(query: args[flag + 1])
        }
#endif
#if DEBUG
        if let flag = args.firstIndex(of: "--record-capture"), args.count > flag + 1, let seconds = Int(args[flag + 1]) {
            let scenario = args.firstIndex(of: "--scenario").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
            return .recordCapture(seconds: seconds, scenario: scenario ?? "real")
        }
#endif
        if let flag = args.firstIndex(of: "--chat"), args.count > flag + 1 {
            return .chat(question: args[flag + 1])
        }
        if let flag = args.firstIndex(of: "--agent-sessions") {
            let next = args.count > flag + 1 ? args[flag + 1] : nil
            return .agentSessions(dayKey: next.flatMap { $0.hasPrefix("--") ? nil : $0 })
        }
        if let flag = args.firstIndex(of: "--agent"), args.count > flag + 1 {
            return .agent(prompt: args[flag + 1])
        }
        return nil
    }

    static func validatedDreamTarget(
        dayKey: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DreamScheduler.Target {
        let day: Date
        if let dayKey {
            guard let parsed = DreamDay.date(fromKey: dayKey, calendar: calendar),
                  DreamDay.key(for: parsed, calendar: calendar) == dayKey else {
                throw DreamDayArgumentError.invalidFormat(dayKey)
            }
            day = parsed
        } else {
            day = DreamScheduler.previousDay(of: now, calendar: calendar)
        }

        let target = DreamScheduler.target(for: day, calendar: calendar)
        let latestAllowed = DreamScheduler.previousDay(of: now, calendar: calendar)
        guard target.day <= latestAllowed else {
            throw DreamDayArgumentError.notHistorical(target.dayKey)
        }
        return target
    }
}

enum DreamDayArgumentError: LocalizedError, Equatable {
    case invalidFormat(String)
    case notHistorical(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let dayKey):
            return "invalid day \(dayKey) (expected yyyy-MM-dd)"
        case .notHistorical(let dayKey):
            return "day \(dayKey) must be yesterday or earlier"
        }
    }
}

enum DayDigestCLIOutput {
    static func render(
        result: DayDigestGenerationResult,
        modelID: String,
        day: Date
    ) -> String {
        "LokalBot --digest: \(result.url.path) "
            + "(\(result.text.count) chars; model=\(modelID); "
            + "day=\(DreamDay.key(for: day)))"
    }
}

enum CodingAgentSessionsCLI {
    static func run(dayKey: String?, now: Date = Date()) -> Int32 {
        let day: Date
        if let dayKey {
            guard let parsed = DreamDay.date(fromKey: dayKey),
                  DreamDay.key(for: parsed) == dayKey else {
                print("LokalBot --agent-sessions: invalid day \(dayKey) (expected yyyy-MM-dd)")
                return 2
            }
            day = parsed
        } else {
            day = now
        }
        let started = Date()
        let scan = CodingAgentSessionScanner.standard().scan(day: day)
        print(render(scan, day: day, elapsed: Date().timeIntervalSince(started)))
        return 0
    }

    static func render(
        _ scan: CodingAgentDayScan, day: Date, elapsed: TimeInterval, calendar: Calendar = .current
    ) -> String {
        var blocks = scan.bursts.map { $0.evidenceText(calendar: calendar) }
        blocks += scan.unreadableFiles.map { "Unreadable transcript: \($0)" }
        let megabytes = Double(scan.bytesRead) / 1_000_000
        blocks.append(
            "LokalBot --agent-sessions: \(DreamDay.key(for: day, calendar: calendar)) — "
                + "\(scan.sessionCount) sessions, \(scan.bursts.count) bursts, "
                + "\(scan.evidenceCharacters) evidence chars from \(scan.filesRead) files "
                + String(format: "(%.0f MB) in %.1fs", megabytes, elapsed)
                + (scan.excludedSessions > 0 ? "; \(scan.excludedSessions) excluded" : ""))
        return blocks.joined(separator: "\n\n")
    }
}

@MainActor
struct HeadlessCommandRunner {
    static let recordSystemAudioPolicy: RecordingSystemAudioPolicy = .microphoneOnly

    let app: AppState

    func run(_ command: HeadlessCommand) {
        switch command {
        case .process(let folder, let transcribe, let summarize):
            runProcess(folder: folder, transcribe: transcribe, summarize: summarize)
        case .search(let query): runSearch(query: query)
        case .record(let seconds): runRecord(seconds: seconds)
        case .shotTest: runShotTest()
        case .digest(let dayKey): runDigest(dayKey: dayKey)
        case .dream(let dayKey): runDream(dayKey: dayKey)
        case .chat(let question): runChat(question: question)
        case .agent(let prompt): runAgent(prompt: prompt)
        case .cotypingBench: runCotypingBench()
        case .cotypingEngineBench(let model, let passes):
            Task { @MainActor in exit(await CotypingBenchmarkRunner.runEngine(model: model, passes: passes)) }
        case .cotypingReplay(let input, let engine):
            Task { @MainActor in exit(await CotypingQualityReplay.run(input: input, engine: engine)) }
        case .dictationReplay(let input, let endpoint):
            Task { @MainActor in exit(await DictationContextReplay.run(input: input, endpoint: endpoint)) }
        case .exportDiagnostics(let destination): runExportDiagnostics(to: destination)
        case .health(let dayKey, let json): runHealth(dayKey: dayKey, json: json)
        case .recordCapture(let seconds, let scenario): runRecordCapture(seconds: seconds, scenario: scenario)
#if LOKALBOT_TEST_HOOKS
        case .setBoundaries(let folder, let start, let end): runSetBoundaries(folder: folder, start: start, end: end)
        case .searchScreen(let query): runSearchScreen(query: query)
#endif
        case .agentSessions(let dayKey): exit(CodingAgentSessionsCLI.run(dayKey: dayKey))
        case .cotypingMeasurements: exit(CotypingStatsStore.printSaved())
        case .eventTaps: exit(EventTapAudit.printCurrent())
        }
    }

    private func runProcess(folder: URL, transcribe: Bool, summarize: Bool) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
              let decoded = try? decoder.decode(Meeting.self, from: data) else {
            print("LokalBot --process: no readable meta.json in \(folder.path)")
            exit(2)
        }
        app.pipeline.enqueue(decoded, transcribe: transcribe, summarize: summarize)
        waitForPipeline(decoded.id, label: "--process", folder: folder)
    }

    private func waitForPipeline(_ id: Meeting.ID, label: String, folder: URL) {
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                switch app.pipeline.stages[id] {
                case .none:
                    print("LokalBot \(label): done → \(folder.path)")
                    await LlamaServer.shared.stop()
                    exit(0)
                case .failed(let message):
                    print("LokalBot \(label): FAILED — \(message)")
                    await LlamaServer.shared.stop()
                    exit(1)
                default:
                    continue
                }
            }
        }
    }

#if LOKALBOT_TEST_HOOKS
    private func runSetBoundaries(folder: URL, start: TimeInterval, end: TimeInterval) {
        guard let meeting = app.meetings.first(where: { $0.folderURL(in: app.storage).standardizedFileURL == folder.standardizedFileURL }) else {
            print("LokalBot --set-boundaries: no meeting at \(folder.path)")
            exit(2)
        }
        do {
            try app.setMeetingBoundaries(Meeting.ContentRange(start: start, end: end), for: meeting)
        } catch {
            print("LokalBot --set-boundaries: FAILED — \(error.localizedDescription)")
            exit(1)
        }
        waitForPipeline(meeting.id, label: "--set-boundaries", folder: folder)
    }
#endif

    private func runHealth(dayKey: String?, json: Bool) {
        let day: Date
        if let dayKey {
            guard let parsed = DreamDay.date(fromKey: dayKey), DreamDay.key(for: parsed) == dayKey else {
                print("LokalBot --health: invalid day \(dayKey) (expected yyyy-MM-dd)")
                exit(2)
            }
            day = parsed
        } else {
            day = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))
                ?? Date()
        }
        let report = app.libraryHealthReport(for: day)
        do {
            try LibraryHealthReportStore.write(report, root: app.storage.rootURL)
        } catch {
            print("LokalBot --health: could not write report — \(error.localizedDescription)")
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(data: (try? encoder.encode(report)) ?? Data(), encoding: .utf8) ?? "{}")
        } else {
            print(LibraryHealthReportStore.markdown(report))
        }
        exit(report.status == .fail ? 1 : 0)
    }

    private func runRecordCapture(seconds: Int, scenario: String) {
#if DEBUG
        guard let recorder = CaptureTraceRecorder.active else {
            print("LokalBot --record-capture: FAILED — recorder was not installed at launch")
            exit(1)
        }
        app.sampler.start()
        app.screenshots.start()
        app.detector.start()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            app.detector.stop()
            app.screenshots.stop()
            app.sampler.stop()
            do {
                let url = try recorder.finish(to: DiagnosticsPaths.captureTraces(root: app.storage.rootURL))
                print("LokalBot --record-capture: \(url.path)")
                exit(0)
            } catch {
                print("LokalBot --record-capture: FAILED — \(error.localizedDescription)")
                exit(1)
            }
        }
#endif
    }

    private func runExportDiagnostics(to destination: URL) {
        do {
            let manifest = try app.exportDiagnostics(to: destination)
            let missing = manifest.missing.isEmpty ? "none" : manifest.missing.joined(separator: ", ")
            print("LokalBot --export-diagnostics: \(destination.path) (missing: \(missing))")
            exit(0)
        } catch {
            print("LokalBot --export-diagnostics: FAILED — \(error.localizedDescription)")
            exit(1)
        }
    }

    private func runRecord(seconds: Int) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("LokalBot --record: SKIP (microphone not granted)")
            exit(3)
        }
        app.startRecording(
            context: nil,
            source: "headless",
            systemAudioPolicy: Self.recordSystemAudioPolicy)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard app.isRecording else {
                print("LokalBot --record: FAILED to start — \(app.lastError ?? "no error recorded")")
                exit(1)
            }
            app.stopRecording(process: false)
            guard let meeting = app.meetings.first else { print("LokalBot --record: no meeting"); exit(1) }
            print("LokalBot --record: done → \(meeting.folderURL(in: app.storage).path)")
            exit(0)
        }
    }

    private func runShotTest() {
        Task { @MainActor in
            guard CGPreflightScreenCaptureAccess() else {
                print("LokalBot --shot-test: SKIP (screen recording not granted)")
                exit(3)
            }
            let before = Date()
            app.screenshots.captureNow()
            try? await Task.sleep(for: .seconds(8))
            guard let shot = app.activityStore.screenshots(on: Date()).last(where: { $0.ts >= before }) else {
                print("LokalBot --shot-test: FAILED (no screenshot row — see debug.log)")
                exit(1)
            }
            guard shot.hasPixels,
                  FileManager.default.isReadableFile(atPath: shot.path),
                  let key = try? ScreenshotService.encryptionKey(),
                  let decrypted = ScreenshotService.decryptedData(path: shot.path, key: key),
                  !decrypted.isEmpty,
                  NSImage(data: decrypted) != nil else {
                print("LokalBot --shot-test: FAILED (encrypted screenshot did not round-trip)")
                exit(1)
            }
            print("LokalBot --shot-test: ok (encrypted image round-trip; app: \(shot.app))")
            exit(0)
        }
    }

    private func runDigest(dayKey: String?) {
        Task { @MainActor in
            do {
                let day: Date
                if let dayKey {
                    guard let parsed = DreamDay.date(fromKey: dayKey),
                          DreamDay.key(for: parsed) == dayKey else {
                        print("LokalBot --digest: invalid day \(dayKey) (expected yyyy-MM-dd)")
                        exit(2)
                    }
                    day = parsed
                } else {
                    day = Date()
                }
                var config = app.settings
                if let modelID = ProcessInfo.processInfo.environment["LOKALBOT_DIGEST_MODEL_ID"],
                   ModelCatalog.entry(id: modelID, custom: config.customBuiltInModels) != nil {
                    config.summarizerBackend = .builtIn
                    config.builtInModelID = modelID
                    config.dayDigestCustomPrompt = ""
                }
                let result = try await app.dayDigest.generate(for: day, settings: config)
                print(DayDigestCLIOutput.render(
                    result: result,
                    modelID: config.builtInModelID,
                    day: day))
                await LlamaServer.shared.stop()
                exit(0)
            } catch {
                print("LokalBot --digest: FAILED — \(error.localizedDescription)")
                await LlamaServer.shared.stop()
                exit(1)
            }
        }
    }

    private func runDream(dayKey: String?) {
        let calendar = Calendar.current
        let target: DreamScheduler.Target
        do {
            target = try HeadlessCommand.validatedDreamTarget(
                dayKey: dayKey,
                calendar: calendar)
        } catch {
            print("LokalBot --dream: \(error.localizedDescription)")
            exit(2)
        }
        Task { @MainActor in
            do {
                let service = DreamService(
                    storageRoot: app.storage.rootURL,
                    makeEngine: {
                        let settings = app.settings
                        let engine = try await app.thinkExecution.makeTextEngine(
                            settings, purpose: "dreaming")
                        return (engine, DreamInferenceProvenance(settings: settings))
                    })
                let report = try await service.dream(target: target)
                let kind = report.isFallback
                    ? "fallback (\(report.fallbackReason?.rawValue ?? "legacy"))"
                    : "model (\(report.engineName ?? "?"))"
                print("LokalBot --dream: \(kind) → "
                      + app.dreamStore.reportJSONURL(forDayKey: target.dayKey).path)
                await LlamaServer.shared.stop()
                exit(0)
            } catch {
                print("LokalBot --dream: FAILED — \(error.localizedDescription)")
                await LlamaServer.shared.stop()
                exit(1)
            }
        }
    }

    private func runChat(question: String) {
        Task { @MainActor in
            do {
                app.searchIndex.reindexAll(app.meetings, storage: app.storage)
                let engine = try await app.thinkExecution.makeTextEngine(app.settings)
                let tools = MeetingChatTools(
                    meetings: { [weak app] in app?.meetings ?? [] },
                    storage: app.storage, searchIndex: app.searchIndex, embeddingIndex: app.embeddingIndex,
                    activityStore: app.activityStore,
                    settings: { [store = app.settingsStore] in store.current })
                var agent = ChatAgent(engine: engine, runner: tools)
                agent.workMemory = ChatPrompt.workMemoryContext(
                    memory: (try? app.dreamStore.loadMemory()) ?? nil,
                    dreamingEnabled: app.settings.dreamingEnabled)
                if app.settings.askMemoryEnabled {
                    let selection = PersonalContextBuilder.select(
                        claims: app.personalModel.usableClaims(), question: question)
                    agent.personalContext = selection.block
                    if !selection.claims.isEmpty {
                        print("LokalBot --chat: using \(selection.claims.count) personal claim(s)")
                    }
                }
                let answer = try await agent.respond(history: [], latest: question) { event in
                    switch event {
                    case .answerPartial: break
                    case .toolStarted(let call):
                        print("LokalBot --chat: tool \(call.name)(\(call.arguments))")
                    case .toolFinished(let name, let summary):
                        print("LokalBot --chat: done \(name) — \(summary)")
                    }
                }
                print("LokalBot --chat: \(answer)")
                await LlamaServer.shared.stop()
                await LlamaServer.embedder.stop()
                exit(0)
            } catch {
                print("LokalBot --chat: FAILED — \(error.localizedDescription)")
                await LlamaServer.shared.stop()
                await LlamaServer.embedder.stop()
                exit(1)
            }
        }
    }

    private func runAgent(prompt: String) {
        Task { @MainActor in
            guard AgentRuntimeLayout.isInstalled() else {
                print("LokalBot --agent: SKIP (agent runtime not installed; enable Agent Mode in the app once)")
                exit(3)
            }
            let controller = app.agentController
            controller.approveWorkspaceFileChangesForAutomation()
            await controller.start()
            if case .failed(let reason) = controller.state {
                print("LokalBot --agent: FAILED to start — \(reason)")
                exit(1)
            }
            await controller.send(prompt: prompt)
            for _ in 0..<100 where controller.state != .running {
                await controller.denyAllPendingApprovals()
                try? await Task.sleep(for: .milliseconds(100))
            }
            for _ in 0..<600 where controller.state == .running {
                await controller.denyAllPendingApprovals()
                try? await Task.sleep(for: .milliseconds(100))
            }
            for item in controller.items {
                switch item {
                case .user(_, let text): print("LokalBot --agent: > \(text)")
                case .assistant(_, let text, _): print("LokalBot --agent: \(text)")
                case .tool(_, let name, _, _, let status): print("LokalBot --agent: tool \(name) [\(status)]")
                case .approval: break
                case .notice(_, let text, let isError): print("LokalBot --agent: \(isError ? "ERROR" : "note") \(text)")
                }
            }
            let replied = controller.items.contains {
                if case .assistant = $0 { return true } else { return false }
            }
            let ok = controller.state == .ready && replied
            await controller.shutdown()
            await LlamaServer.shared.stop()
            if ok {
                print("LokalBot --agent: done")
            } else if replied {
                print("LokalBot --agent: FAILED — turn did not settle in 60s")
            } else {
                print("LokalBot --agent: FAILED — no assistant reply")
            }
            exit(ok ? 0 : 1)
        }
    }

    private func runCotypingBench() {
        Task { @MainActor in
            let settings = app.settings
            var config = CotypingConfiguration.standard
            config.maxResponseTokens = settings.cotypingMaxResponseTokens
            config.maxResponseWords = settings.cotypingMaxWords
            let summary = await CotypingBenchmarkRunner.run(
                engine: app.cotypingEngine,
                config: config,
                personalization: settings.cotypingPersonalization)
            print(summary.jsonReport())
            await app.cotypingEngine.unload()
            await LlamaServer.shared.stop()
            exit(summary.results.allSatisfy(\.passedSafety) ? 0 : 1)
        }
    }

#if LOKALBOT_TEST_HOOKS
    private func runSearchScreen(query: String) {
        let hits = app.activityStore.searchOCR(query)
        print("LokalBot --search-screen: \(hits.count) screen hit(s)")
        for hit in hits {
            print("[screen] \(hit.app) @ \(hit.ts.formatted(.iso8601)): \(hit.snippet)")
        }
        exit(hits.isEmpty ? 1 : 0)
    }
#endif

    private func runSearch(query: String) {
        let hits = app.searchIndex.search(query)
        print("LokalBot --search: \(hits.count) keyword hit(s)")
        for hit in hits {
            let meeting = app.meetings.first { $0.id == hit.meetingID }
            print("[\(hit.kind.rawValue)] \(meeting?.title ?? hit.meetingID.uuidString) @ \(Transcript.stamp(hit.start)): \(hit.snippet)")
        }
        Task { @MainActor in
            if app.settings.semanticSearchEnabled {
                await app.embeddingIndex.reindexAll(app.meetings)
                let semantic = await app.embeddingIndex.search(query)
                print("LokalBot --search: \(semantic.count) semantic hit(s)")
                for hit in semantic {
                    let meeting = app.meetings.first { $0.id == hit.meetingID }
                    print(String(format: "[≈%.2f] %@ @ %@: %@", hit.score,
                                 meeting?.title ?? "?", Transcript.stamp(hit.start),
                                 String(hit.text.prefix(90))))
                }
                await LlamaServer.embedder.stop()
                exit(hits.isEmpty && semantic.isEmpty ? 1 : 0)
            }
            exit(hits.isEmpty ? 1 : 0)
        }
    }
}
