import Foundation
import AVFoundation
import AppKit

/// A `LokalBot --flag` subcommand. Parsed once, in `LokalBotMain.main()`,
/// before SwiftUI launches — so argument handling never lives inside
/// `AppState`, and the parse itself is a pure, testable function.
///
/// The commands still execute inside the normal app launch (they need the
/// main run loop for audio, timers, and screen capture); each schedules its
/// work and calls `exit()` when done.
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

    /// Set by `LokalBotMain.main()`; consumed by `AppState.init`.
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
        if args.contains("--cotyping-bench") { return .cotypingBench }
        if let flag = args.firstIndex(of: "--chat"), args.count > flag + 1 {
            return .chat(question: args[flag + 1])
        }
        if let flag = args.firstIndex(of: "--agent"), args.count > flag + 1 {
            return .agent(prompt: args[flag + 1])
        }
        return nil
    }

    /// Resolve the CLI's optional day without allowing a current/future day
    /// to advance the durable memory watermark past days that have not yet
    /// happened. Requiring the canonical key also rejects normalized dates
    /// such as 2026-02-30 and ambiguous shorthand such as 2026-7-2.
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

/// Executes headless subcommands against the app's real subsystems (pipeline,
/// indexes, recorder). Test hooks for CI and `Scripts/e2e.sh` — the same code
/// paths as the UI, no window required.
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
        }
    }

    /// `LokalBot --process <meeting folder>`: run the pipeline headless and
    /// exit. Add `--summary-only` to keep the current transcript, matching the
    /// Re-summarize button. Lets the pipeline be exercised (and CI-tested)
    /// without the UI.
    private func runProcess(folder: URL, transcribe: Bool, summarize: Bool) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
              let decoded = try? decoder.decode(Meeting.self, from: data) else {
            print("LokalBot --process: no readable meta.json in \(folder.path)")
            exit(2)
        }
        app.pipeline.enqueue(decoded, transcribe: transcribe, summarize: summarize)
        // Poll the pipeline until the job leaves the stage table, then exit.
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                switch app.pipeline.stages[decoded.id] {
                case .none:
                    print("LokalBot --process: done → \(folder.path)")
                    await LlamaServer.shared.stop()
                    exit(0)
                case .failed(let message):
                    print("LokalBot --process: FAILED — \(message)")
                    await LlamaServer.shared.stop()
                    exit(1)
                default:
                    continue
                }
            }
        }
    }

    /// `LokalBot --record <seconds>`: manual mic recording, no pipeline.
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

    /// `LokalBot --shot-test`: one screenshot capture, exit 0 ok / 3 skip / 1 fail.
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

    /// `LokalBot --digest [yyyy-MM-dd]`: generate a journal digest and exit.
    /// `LOKALBOT_DIGEST_MODEL_ID` is a headless-only evaluation override; it
    /// never changes the persisted model selection.
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

    /// `LokalBot --dream [yyyy-MM-dd]`: dream one day (default: yesterday) and
    /// exit. Bypasses the scheduler's hour/downtime/power gates like "Dream
    /// now" — the caller explicitly asked. Test hook for the dreaming
    /// pipeline, same spirit as --digest.
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

    /// `LokalBot --chat "<question>"`: run the meeting chat agent once against
    /// the real engine + tools and print the answer. Test hook for the chat
    /// assistant, same spirit as --search / --digest.
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

    /// `LokalBot --agent "<prompt>"`: one Agent Mode turn against the real
    /// runtime + Main LLM engine, auto-approving file changes and declining
    /// privacy-sensitive shell/external-read requests, then printing each transcript
    /// item. Exit 0 ok / 3 skip (runtime not installed) / 1 fail. Test hook
    /// for Agent Mode, same spirit as --chat.
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
            // send() returns after the prompt is accepted; work streams in as
            // events. Immediately after send() the state may still read .ready
            // (agent_start hasn't arrived yet), so first wait for .running,
            // THEN wait for it to leave .running. Otherwise the settle loop
            // exits before any work happened.
            for _ in 0..<100 where controller.state != .running {   // 10s to start
                await controller.denyAllPendingApprovals()
                try? await Task.sleep(for: .milliseconds(100))
            }
            for _ in 0..<600 where controller.state == .running {   // 60s to settle
                await controller.denyAllPendingApprovals()
                try? await Task.sleep(for: .milliseconds(100))
            }
            for item in controller.items {
                switch item {
                case .user(_, let text): print("LokalBot --agent: > \(text)")
                case .assistant(_, let text, _): print("LokalBot --agent: \(text)")
                case .tool(_, let name, _, _, let status): print("LokalBot --agent: tool \(name) [\(status)]")
                case .approval: break   // handled by the unattended-run policy above
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

    /// `LokalBot --cotyping-bench`: run the cotyping quality benchmark headless
    /// against the real engine and print one JSON document — the scriptable
    /// face of the in-app "Run cotyping check" (same scenarios, same criteria).
    /// Exit 0 when every scenario passes its safety contract, 1 otherwise.
    private func runCotypingBench() {
        Task { @MainActor in
            let summary = await app.cotyping.runQualityBenchmark()
            print(summary.jsonReport())
            await app.cotypingEngine.unload()
            await LlamaServer.shared.stop()
            exit(summary.results.allSatisfy(\.passedSafety) ? 0 : 1)
        }
    }

    /// `LokalBot --search <query>`: print index hits and exit. Test hook
    /// for the FTS5 index, same spirit as --process.
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
