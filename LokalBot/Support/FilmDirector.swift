#if LOKALBOT_TEST_HOOKS
import AppKit

/// Films a scripted run of the real app for demo videos (Debug builds only;
/// see Scripts/agent-handoff-demo). `LOKALBOT_TEST_FILM_SCRIPT` picks the run:
///
/// - `install-agent` installs Agent Mode's runtime, prints the result and quits.
/// - `agent-handoff` opens the meeting `LOKALBOT_TEST_FILM_MEETING` while it is
///   transcribed and summarized, then Agent Mode once its actions are handed
///   off, moving between their tasks until the agents finish. Non-file tool
///   requests are allowed once after two seconds, as a person would.
///
/// `LOKALBOT_TEST_FILM_DIR` receives `director.log`, a `done` marker, and with
/// `LOKALBOT_TEST_FILM_FRAMES=1` the main window as numbered PNGs twice a
/// second, rendered in-process so no Screen Recording grant is needed, listed
/// with their times and scenes in `frames.jsonl`.
@MainActor
final class FilmDirector {
    enum Scene: String {
        case waiting, meeting
        case handedOff = "handed-off"
        case agents, done
    }

    private static var current: FilmDirector?

    private let app: AppState
    private let meetingID: UUID?
    private let folder: URL
    private let writesFrames: Bool
    private let agentSeconds: TimeInterval
    private let started = Date()
    private var scene = Scene.waiting
    private var sceneStarted = Date()
    private var timer: Timer?
    private var frameNumber = 0
    private var sizedWindow = false
    private var lastStage: String?
    private var sawStage = false
    private var stageEnded: Date?
    private var requestedModels = false
    private var shownTask: UUID?
    private var taskShownAt = Date()
    private var taskStates: [UUID: String] = [:]
    private var approvalsSeen: [String: Date] = [:]

    static func startIfRequested(app: AppState) {
        let environment = ProcessInfo.processInfo.environment
        switch environment["LOKALBOT_TEST_FILM_SCRIPT"] {
        case "install-agent":
            Task { @MainActor in
                await app.agentInstaller.installIfNeeded()
                let phase = app.agentInstaller.phase
                let installed = phase == .installed
                print(installed ? "film: agent runtime installed" : "film: agent runtime not installed: \(phase)")
                exit(installed ? 0 : 1)
            }
        case "agent-handoff":
            let director = FilmDirector(app: app, environment: environment)
            current = director
            director.begin()
        default:
            break
        }
    }

    private init(app: AppState, environment: [String: String]) {
        self.app = app
        meetingID = environment["LOKALBOT_TEST_FILM_MEETING"].flatMap(UUID.init(uuidString:))
        folder = URL(fileURLWithPath: environment["LOKALBOT_TEST_FILM_DIR"]
            ?? NSTemporaryDirectory() + "lokalbot-film", isDirectory: true)
        writesFrames = environment["LOKALBOT_TEST_FILM_FRAMES"] == "1"
        agentSeconds = environment["LOKALBOT_TEST_FILM_AGENT_SECONDS"].flatMap(TimeInterval.init) ?? 420
    }

    private func begin() {
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("frames"),
                                                 withIntermediateDirectories: true)
        note("start meeting=\(meetingID?.uuidString ?? "none") frames=\(writesFrames)")
        WindowAccess.shared.open("main")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private var inScene: TimeInterval { Date().timeIntervalSince(sceneStarted) }

    private var handedOffTasks: [AgentSessionTabs.Tab] {
        app.agentSessions.tabs.filter { $0.record.handoff?.meetingID == meetingID }
    }

    private func tick() {
        sizeWindowOnce()
        if writesFrames { captureFrame() }
        switch scene {
        case .waiting: openMeeting()
        case .meeting: followMeeting()
        case .handedOff: if inScene > 6 { showAgents() }
        case .agents: followAgents()
        case .done: if inScene > 5 { finish() }
        }
    }

    private func move(to next: Scene) {
        note("scene \(scene.rawValue) -> \(next.rawValue)")
        scene = next
        sceneStarted = Date()
    }

    // MARK: - Script

    private func openMeeting() {
        guard app.libraryReady, let meetingID else {
            if inScene > 120 { note("the library or meeting never loaded"); move(to: .done) }
            return
        }
        guard app.meetings.contains(where: { $0.id == meetingID }) else {
            if inScene > 120 { note("meeting \(meetingID) is not in the library"); move(to: .done) }
            return
        }
        WindowAccess.shared.open("main")
        app.openMeeting(meetingID)
        move(to: .meeting)
    }

    private func followMeeting() {
        guard let meetingID, let meeting = app.meetings.first(where: { $0.id == meetingID }) else { return }
        let stage = app.pipeline.stages[meetingID]
        let label = stage.map { String(describing: $0) } ?? "none"
        if label != lastStage {
            note("meeting stage \(label)")
            stageEnded = stage == nil && sawStage ? Date() : nil
            sawStage = sawStage || stage != nil
            lastStage = label
        }
        if stage == .waitingForModels, inScene > 5, !requestedModels {
            // Automatic jobs never download models; ask the way Download & process does.
            requestedModels = true
            note("models missing: processing as a user request")
            _ = app.pipeline.enqueue(meeting, transcribe: true, summarize: true, origin: .userInitiated)
        }
        if case .failed = stage {
            move(to: .done)
        } else if !handedOffTasks.isEmpty {
            note("handed off \(handedOffTasks.count) tasks: \(handedOffTasks.map { $0.title })")
            move(to: .handedOff)
        } else if let stageEnded, Date().timeIntervalSince(stageEnded) > 30 {
            note("processing finished without a handoff")
            move(to: .done)
        } else if !sawStage, inScene > 90 {
            note("the meeting was never queued for processing")
            move(to: .done)
        } else if inScene > 900 {
            note("no handoff after 15 minutes")
            move(to: .done)
        }
    }

    private func showAgents() {
        app.openAgent()
        if let first = handedOffTasks.first { show(first.id) }
        move(to: .agents)
    }

    private func followAgents() {
        let tasks = handedOffTasks
        for task in tasks {
            let state = String(describing: task.controller.state)
            if taskStates[task.id] != state {
                note("task \(task.number) \(state): \(task.title)")
                taskStates[task.id] = state
            }
            allowPendingRequests(of: task.controller)
        }
        let finished = tasks.filter(isFinished)
        if !tasks.isEmpty, finished.count == tasks.count || inScene > agentSeconds {
            note("\(finished.count) of \(tasks.count) tasks finished")
            if let first = finished.first ?? tasks.first { show(first.id) }
            move(to: .done)
            return
        }
        // Each task in turn, skipping ones still waiting for a free agent.
        guard Date().timeIntervalSince(taskShownAt) > 8, tasks.count > 1 else { return }
        let begun = tasks.filter { $0.controller.state != .idle }
        let order = begun.isEmpty ? tasks : begun
        let index = order.firstIndex { $0.id == shownTask }.map { ($0 + 1) % order.count } ?? 0
        show(order[index].id)
    }

    private func isFinished(_ task: AgentSessionTabs.Tab) -> Bool {
        switch task.controller.state {
        case .failed: return true
        case .ready:
            return task.controller.items.contains {
                if case .assistant(_, _, false) = $0 { return true } else { return false }
            }
        default: return false
        }
    }

    private func allowPendingRequests(of controller: AgentSessionController) {
        for case .approval(let request) in controller.items {
            guard let seen = approvalsSeen[request.id] else {
                approvalsSeen[request.id] = Date()
                continue
            }
            guard Date().timeIntervalSince(seen) > 2, seen != .distantPast else { continue }
            approvalsSeen[request.id] = .distantPast
            note("allowing \(request.tool) once: \(request.command ?? request.path ?? "")")
            Task { await controller.respondToApproval(id: request.id, approved: true, scope: .once) }
        }
    }

    private func show(_ id: UUID) {
        app.agentSessions.select(id)
        shownTask = id
        taskShownAt = Date()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        note("done")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("done").path, contents: nil)
    }

    // MARK: - Recording

    private func sizeWindowOnce() {
        guard !sizedWindow, let window = WindowAccess.visibleMainWindow(in: NSApp) else { return }
        sizedWindow = true
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        note("window \(Int(window.frame.width))x\(Int(window.frame.height))")
    }

    private func captureFrame() {
        guard sizedWindow, let window = WindowAccess.visibleMainWindow(in: NSApp),
              let view = window.contentView?.superview ?? window.contentView,
              view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        frameNumber += 1
        let name = String(format: "%05d.png", frameNumber)
        try? png.write(to: folder.appendingPathComponent("frames/\(name)"))
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        append("{\"frame\":\"\(name)\",\"t\":\(elapsed),\"scene\":\"\(scene.rawValue)\"}\n", to: "frames.jsonl")
    }

    private func note(_ message: String) {
        let line = String(format: "%7.1f ", Date().timeIntervalSince(started)) + message
        print("film: \(line)")
        append(line + "\n", to: "director.log")
    }

    private func append(_ text: String, to name: String) {
        let url = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
#endif
