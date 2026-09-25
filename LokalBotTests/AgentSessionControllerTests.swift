import Combine
import Foundation
import XCTest
@testable import LokalBot

@MainActor
final class AgentSessionControllerTests: XCTestCase {

    private var transport: FakeTransport!
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("agent-controller-\(UUID())")
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    private var fixtureStorage: StorageManager {
        StorageManager(rootURL: fixtureRoot.appendingPathComponent("library"))
    }

    private func makeApprovalModeDefaults() -> UserDefaults {
        let suiteName = "AgentApprovalModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private actor BlockingBrokerEnsure {
        private var didStart = false
        private var didRelease = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func block() async {
            didStart = true
            let waitingForStart = startWaiters
            startWaiters.removeAll()
            for waiter in waitingForStart { waiter.resume() }
            guard !didRelease else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilStarted() async {
            if didStart { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            didRelease = true
            let waitingForRelease = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waitingForRelease { waiter.resume() }
        }
    }

    private func makeController(
        backend: AppSettings.SummarizerBackend = .openAICompatible,
        approvalModeDefaults: UserDefaults? = nil
    ) -> AgentSessionController {
        transport = FakeTransport()
        var settings = AppSettings()
        settings.summarizerBackend = backend
        settings.openAIBaseURL = "http://localhost:1234/v1"
        settings.openAIModel = "test-model"
        let captured = transport!
        return AgentSessionController(
            settings: { settings },
            storage: fixtureStorage,
            sessionsDirectory: fixtureRoot.appendingPathComponent("sessions"),
            defaultWorkspace: fixtureRoot.appendingPathComponent("workspace"),
            makeTransport: { _ in captured },
            approvalModeDefaults: approvalModeDefaults ?? makeApprovalModeDefaults())
    }

    private func pump() async throws {
        // Let the event-consumption task drain injected lines.
        try await Task.sleep(for: .milliseconds(150))
    }

    private func approvalEvent(
        id: String,
        tool: String,
        workspace: String,
        path: String?,
        content: String,
        command: String? = nil,
        truncated: Bool = false
    ) throws -> String {
        var payload: [String: Any] = [
            "tool": tool,
            "workspace": workspace,
            "content": content,
            "truncated": truncated,
        ]
        if tool == "bash" { payload["command"] = command ?? "printf fixture" }
        if let path { payload["path"] = path }
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadString = String(decoding: payloadData, as: UTF8.self)
        let event: [String: Any] = [
            "type": "extension_ui_request",
            "id": id,
            "method": "confirm",
            "title": "lokalbot_tool_approval",
            "message": payloadString,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    }

    func testHostQueueCanBeEditedAndCanceledBeforeAnythingIsSent() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"agent_start"}"#)
        try await pump()
        controller.draft = "First follow-up"
        controller.queueDraft()
        let first = try XCTUnwrap(controller.queuedPrompts.first)
        XCTAssertTrue(transport.sentLines.isEmpty)
        controller.editQueued(first.id)
        XCTAssertEqual(controller.draft, "First follow-up")
        XCTAssertTrue(controller.queuedPrompts.isEmpty)
        controller.draft = "Edited follow-up"
        controller.queueDraft()
        controller.cancelQueued(try XCTUnwrap(controller.queuedPrompts.first).id)
        transport.inject(#"{"type":"agent_settled"}"#)
        try await pump()
        XCTAssertTrue(transport.sentLines.isEmpty, "a canceled follow-up must never reach Pi")
        await controller.shutdown()
    }

    func testQueuedPromptWaitsUntilTurnEndsThenUsesOrdinaryPrompt() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"agent_start"}"#)
        try await pump()
        controller.draft = "Next task"
        controller.queueDraft()
        XCTAssertTrue(transport.sentLines.isEmpty)
        transport.inject(#"{"type":"agent_end","willRetry":true}"#)
        try await pump()
        XCTAssertTrue(transport.sentLines.isEmpty, "agent_end must not race Pi retry or compaction")
        XCTAssertEqual(controller.state, .running)
        transport.inject(#"{"type":"agent_settled"}"#)
        try await pump()
        let line = try XCTUnwrap(transport.sentLines.first)
        let command = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(command["type"] as? String, "prompt")
        XCTAssertEqual(command["message"] as? String, "Next task")
        XCTAssertNil(command["streamingBehavior"], "the editable host queue must not also use Pi's hidden queue")
        transport.inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        try await pump()
        XCTAssertTrue(controller.queuedPrompts.isEmpty)
        await controller.shutdown()
    }

    func testSteeringUsesNativeSteerCommand() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"agent_start"}"#)
        try await pump()
        let send = Task { await controller.send(prompt: "Use the shorter version", steer: true) }
        try await pump()
        XCTAssertTrue(transport.sentLines.contains { $0.contains(#""type":"steer""#) })
        transport.inject(#"{"type":"response","id":"steer1","command":"steer","success":true}"#)
        let accepted = await send.value
        XCTAssertTrue(accepted)
        await controller.shutdown()
    }

    func testTerminalProviderFailurePausesTheHostQueue() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"agent_start"}"#)
        try await pump()
        controller.draft = "Dependent next task"
        controller.queueDraft()
        transport.inject(#"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"401 Invalid API key"}}"#)
        transport.inject(#"{"type":"agent_end"}"#)
        transport.inject(#"{"type":"agent_settled"}"#)
        try await pump()
        XCTAssertEqual(controller.turnError, "401 Invalid API key")
        XCTAssertEqual(controller.taskStatus, "Needs attention")
        XCTAssertTrue(controller.queueIsPaused)
        XCTAssertEqual(controller.queuedPrompts.map(\.text), ["Dependent next task"])
        XCTAssertTrue(transport.sentLines.isEmpty)
        XCTAssertTrue(controller.items.contains { if case .notice(_, "401 Invalid API key", true) = $0 { true } else { false } })
        await controller.shutdown()
    }

    func testStopKeepsFollowUpsPausedAndUnsent() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"agent_start"}"#)
        try await pump()
        controller.draft = "Do not run after stop"
        controller.queueDraft()
        let stopping = Task { await controller.abort() }
        try await pump()
        transport.inject(#"{"type":"response","id":"a1","command":"abort","success":true}"#)
        transport.inject(#"{"type":"agent_settled"}"#)
        await stopping.value
        try await pump()
        XCTAssertTrue(controller.queueIsPaused)
        XCTAssertEqual(controller.queuedPrompts.count, 1)
        XCTAssertFalse(transport.sentLines.contains { $0.contains(#""type":"prompt""#) })
        await controller.shutdown()
    }

    func testRejectedPromptRemainsAvailableForExplicitRetry() async throws {
        let controller = makeController()
        await controller.start()
        let send = Task { await controller.send(prompt: "Original prompt") }
        try await pump()
        transport.inject(#"{"type":"response","id":"p1","command":"prompt","success":false,"error":"Model unavailable"}"#)
        let accepted = await send.value
        XCTAssertFalse(accepted)
        controller.reviewRetry()
        XCTAssertEqual(controller.draft, "Original prompt")
        XCTAssertTrue(controller.composerError?.contains("may be repeated") == true)
        XCTAssertEqual(transport.sentLines.count, 1, "reviewing a retry never resends on its own")
        await controller.shutdown()
    }

    func testStopCancelsPendingApprovalBeforeAwaitingIdle() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"agent_start"}"#)
        transport.inject(try approvalEvent(id: "pending", tool: "write", workspace: controller.workspace.path,
                                          path: controller.workspace.appendingPathComponent("draft.md").path, content: "Draft"))
        try await pump()
        XCTAssertEqual(controller.pendingApprovals.count, 1)
        let stopping = Task { await controller.abort() }
        try await pump()
        XCTAssertTrue(controller.pendingApprovals.isEmpty)
        XCTAssertTrue(transport.sentLines.contains { $0.contains(#""cancelled":true"#) })
        // The RPC acknowledgement and settled event are consumed separately.
        // Await the published state instead of racing the event-consumption task.
        let settled = expectation(description: "Controller consumes the settled event")
        let observation = controller.$state.filter { $0 == .ready }.first().sink { _ in settled.fulfill() }
        defer { observation.cancel() }
        transport.inject(#"{"type":"response","id":"a1","command":"abort","success":true}"#)
        transport.inject(#"{"type":"agent_settled"}"#)
        await stopping.value
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(controller.state, .ready)
        await controller.shutdown()
    }

    func testStopDuringQueuedAcknowledgementDoesNotFailOrDuplicatePrompt() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"agent_start"}"#)
        try await pump()
        controller.draft = "Already delivered"
        controller.queueDraft()
        controller.draft = "Stay paused"
        controller.queueDraft()
        transport.inject(#"{"type":"agent_settled"}"#)
        try await pump()
        XCTAssertTrue(controller.isSending)
        let stopping = Task { await controller.abort() }
        try await pump()
        transport.inject(#"{"type":"response","id":"a2","command":"abort","success":true}"#)
        transport.inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        transport.inject(#"{"type":"agent_settled"}"#)
        await stopping.value
        try await pump()
        XCTAssertEqual(controller.state, .ready)
        XCTAssertTrue(controller.queueIsPaused)
        XCTAssertEqual(controller.queuedPrompts.map(\.text), ["Stay paused"])
        XCTAssertEqual(transport.sentLines.filter { $0.contains(#""type":"prompt""#) }.count, 1)
        await controller.shutdown()
    }

    func testDuplicateSubmissionWhileAwaitingAcknowledgementIsNotSent() async throws {
        let controller = makeController()
        await controller.start()
        let first = Task { await controller.send(prompt: "Once") }
        try await pump()
        let duplicate = await controller.send(prompt: "Twice")
        XCTAssertFalse(duplicate)
        transport.inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        _ = await first.value
        XCTAssertEqual(transport.sentLines.count, 1)
        await controller.shutdown()
    }

    func testUnsavedConversationCannotBeParkedOrSilentlyReplaced() async throws {
        let controller = makeController()
        controller.attachments = [.file(URL(fileURLWithPath: "/tmp/unsent-notes.txt"))]
        XCTAssertFalse(controller.canReplaceWithSavedSession)
        controller.attachments = []
        await controller.start()
        XCTAssertFalse(controller.canReplaceWithSavedSession, "a live runtime cannot be replaced by a read-only preview")
        let send = Task { await controller.send(prompt: "Keep this context") }
        try await pump()
        transport.inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        _ = await send.value
        transport.inject(#"{"type":"agent_settled"}"#)
        try await pump()
        let parked = await controller.park()
        XCTAssertFalse(parked)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertTrue(controller.items.contains { $0.searchableText == "Keep this context" })
        await controller.shutdown()
    }

    func testStartReachesReady() async throws {
        let controller = makeController()
        await controller.start()
        XCTAssertEqual(controller.state, .ready)
    }

    func testDefaultLaunchUsesDedicatedWorkspaceAndPassesTheProtectedLibraryRoot() async throws {
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "http://127.0.0.1:1234/v1"
        settings.openAIModel = "workspace-test"
        let storage = fixtureStorage
        var plan: PiLaunchPlan?
        let controller = AgentSessionController(
            settings: { settings }, storage: storage,
            sessionsDirectory: fixtureRoot.appendingPathComponent("sessions"),
            makeTransport: { plan = $0; return FakeTransport() })
        XCTAssertEqual(controller.workspace, AppDirectories.agentWorkspace(forLibraryRoot: storage.rootURL))
        XCTAssertNil(controller.workspaceAccessNotice)
        XCTAssertEqual(controller.workspaceDisplayName, "Agent Workspace")
        await controller.start()
        XCTAssertEqual(controller.state, .ready)
        let launched = try XCTUnwrap(plan)
        XCTAssertEqual(launched.workingDirectory, controller.workspace)
        XCTAssertNil(launched.environment["LOKALBOT_LLM_API_KEY"], "Injected transports must not retrieve real credentials")
        let roots = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(
            launched.environment["LOKALBOT_AGENT_PRIVATE_ROOTS"]).utf8))
        XCTAssertTrue(roots.contains(storage.rootURL.standardizedFileURL.path))
        XCTAssertFalse(roots.contains(controller.workspace.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: controller.workspace.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        await controller.shutdown()
    }

    func testLegacyLibraryResumeCannotLaunchOrAcquireTheOldWorkspace() async {
        let controller = makeController()
        let saved = AgentSavedSession(id: "legacy", sessionID: "legacy",
            fileURL: fixtureRoot.appendingPathComponent("sessions/legacy.jsonl"),
            workspace: fixtureStorage.rootURL, title: "Saved library conversation",
            createdAt: .distantPast, modifiedAt: .now, messageCount: 2)
        await controller.resumeSavedSession(saved)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.activeSessionFile, saved.fileURL)
        XCTAssertNotNil(controller.workspaceAccessNotice)
        XCTAssertNotNil(controller.composerError)
        XCTAssertNil(controller.modelContext, "reject the workspace before model preparation")
        XCTAssertTrue(transport.sentLines.isEmpty)
        XCTAssertFalse(controller.canResumePreviousSession)
    }

    func testDefaultWorkspaceSymlinkIntoLibraryIsRejectedBeforeLaunch() async throws {
        let controller = makeController()
        let storage = fixtureStorage
        try FileManager.default.createDirectory(at: storage.rootURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: controller.workspace, withDestinationURL: storage.rootURL)
        await controller.start()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNotNil(controller.workspaceAccessNotice)
        XCTAssertNil(controller.modelContext)
        XCTAssertTrue(transport.sentLines.isEmpty)
    }

    func testActiveModelContextStaysWithTheResolvedConnectionUntilRestart() async {
        var configuration = AppSettings()
        configuration.summarizerBackend = .openAICompatible
        configuration.openAIBaseURL = "http://localhost:1234/v1"
        configuration.openAIModel = "original-model"
        let controller = AgentSessionController(
            settings: { configuration }, storage: fixtureStorage,
            sessionsDirectory: fixtureRoot.appendingPathComponent("sessions"),
            defaultWorkspace: fixtureRoot.appendingPathComponent("workspace"),
            makeTransport: { _ in FakeTransport() })
        await controller.start()
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.modelContext?.name, "original-model")
        XCTAssertEqual(controller.modelContext?.destination, .onDevice)

        configuration.openAIBaseURL = "https://reviewed.example/v1"
        configuration.openAIModel = "next-model"
        configuration.approvedRemoteInferenceOrigins = ["https://reviewed.example"]
        XCTAssertEqual(controller.modelContext?.name, "original-model")
        XCTAssertEqual(controller.modelContext?.destination, .onDevice)
        XCTAssertNotEqual(controller.modelContext, .init(settings: configuration))

        await controller.shutdown()
        XCTAssertNil(controller.modelContext)
        await controller.start()
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.modelContext?.name, "next-model")
        XCTAssertEqual(controller.modelContext?.destination, .remote(host: "reviewed.example"))
        await controller.shutdown()
    }

    func testUnsupportedBackendFailsWithoutSpawning() async throws {
        let controller = makeController(backend: .appleIntelligence)
        await controller.start()
        guard case .failed(let reason) = controller.state else {
            return XCTFail("expected failed state, got \(controller.state)")
        }
        XCTAssertTrue(reason.contains("Apple Intelligence"))
        XCTAssertEqual(controller.recoveryAction, .openModels)
        XCTAssertNil(controller.modelContext)
    }

    func testShutdownDuringBuiltInEnsureReleasesLateLease() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-lease-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("models", isDirectory: true),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = ModelCatalog.Entry(
            id: "agent-lease-fixture", displayName: "Agent Lease Fixture",
            fileName: "agent-lease-fixture.gguf", url: "", sizeGB: 0,
            blurb: "", disablesThinking: false)
        try Data("GGUF".utf8).write(
            to: root.appendingPathComponent("models/\(entry.fileName)"))
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn
        settings.builtInModelID = entry.id
        settings.customBuiltInModels = [entry]

        let blocker = BlockingBrokerEnsure()
        var hooks: [InferenceRole: InferenceBroker.RuntimeHooks] = [:]
        for role in InferenceRole.allCases {
            hooks[role] = .init(
                ensure: { _ in
                    if role == .mainLLM { await blocker.block() }
                },
                stop: {})
        }
        let broker = InferenceBroker(hooks: hooks, leaseStateSink: { _, _ in })
        var transportCalls = 0
        let controller = AgentSessionController(
            settings: { settings },
            storage: StorageManager(rootURL: root),
            sessionsDirectory: root.appendingPathComponent("sessions"),
            defaultWorkspace: fixtureRoot.appendingPathComponent("workspace"),
            broker: broker,
            makeTransport: { _ in
                transportCalls += 1
                return FakeTransport()
            })

        let starting = Task { await controller.start() }
        await blocker.waitUntilStarted()
        await controller.shutdown()
        await blocker.release()
        await starting.value
        XCTAssertNil(controller.modelContext, "A canceled startup must not restore stale model context")

        var active = await broker.activeLeaseCount(.mainLLM)
        let deadline = Date().addingTimeInterval(3)
        while active != 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
            active = await broker.activeLeaseCount(.mainLLM)
        }
        XCTAssertEqual(active, 0)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(transportCalls, 0, "a closed tab must not spawn pi after ensure returns")
    }

    func testSendFoldsUserAndStreamsAssistant() async throws {
        let controller = makeController()
        await controller.start()
        // send() awaits pi's response ack, so run it concurrently and ack it
        // once the prompt line is on the wire (first request id is "p1").
        let send = Task { await controller.send(prompt: "hello") }
        try await pump()
        XCTAssertTrue(transport.sentLines.contains { $0.contains(#""type":"prompt""#) && $0.contains("hello") })
        transport.inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        await send.value

        transport.inject(#"{"type":"agent_start"}"#)
        transport.inject(#"{"type":"message_start","message":{"role":"assistant"}}"#)
        transport.inject(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hi "}}"#)
        transport.inject(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"there"}}"#)
        try await pump()
        XCTAssertEqual(controller.state, .running)
        guard case .assistant(_, let text, let streaming) = controller.items.last else {
            return XCTFail("\(controller.items)")
        }
        XCTAssertEqual(text, "Hi there")
        XCTAssertTrue(streaming)

        transport.inject(#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Hi there!"}]}}"#)
        transport.inject(#"{"type":"agent_settled"}"#)
        try await pump()
        XCTAssertEqual(controller.state, .ready)
        guard case .assistant(_, let final, let stillStreaming) = controller.items.last else {
            return XCTFail("expected final assistant item, got \(controller.items)")
        }
        XCTAssertEqual(final, "Hi there!")
        XCTAssertFalse(stillStreaming)
    }

    func testBurstTextDeltasArePublishedInDisplaySizedBatches() async throws {
        let controller = makeController()
        await controller.start()
        var streamedTextPublications = 0
        let observation = controller.$items.dropFirst().sink { items in
            guard case .assistant(_, let text, true) = items.last, !text.isEmpty else { return }
            streamedTextPublications += 1
        }
        defer { observation.cancel() }

        transport.inject(#"{"type":"message_start","message":{"role":"assistant"}}"#)
        for _ in 0..<50 {
            transport.inject(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"x"}}"#)
        }
        try await pump()

        guard case .assistant(_, let text, true) = controller.items.last else {
            return XCTFail("expected streaming assistant item, got \(controller.items)")
        }
        XCTAssertEqual(text, String(repeating: "x", count: 50))
        XCTAssertLessThan(streamedTextPublications, 10,
                          "a burst should not publish once per token")
    }

    func testConfirmRequestRaisesApprovalCardAndReplies() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"extension_ui_request","id":"u1","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"write\",\"workspace\":\"/tmp/project\",\"path\":\"/tmp/project/note.txt\",\"content\":\"exact content\",\"truncated\":false}"}"#)
        try await pump()
        guard case .approval(let request) = controller.items.last else {
            return XCTFail("\(controller.items)")
        }
        XCTAssertEqual(request.id, "u1")
        XCTAssertEqual(request.tool, "write")
        XCTAssertEqual(request.workspace, "/tmp/project")
        XCTAssertEqual(request.path, "/tmp/project/note.txt")
        XCTAssertEqual(request.content, "exact content")

        await controller.respondToApproval(id: "u1", approved: true, scope: .once)
        try await pump()
        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"u1""#) && $0.contains(#""confirmed":true"#)
        })
        XCTAssertFalse(controller.items.contains {
            if case .approval = $0 { return true } else { return false }
        }, "approval card removed after answer")
    }

    func testDenialAddsDeterministicHostNotice() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"extension_ui_request","id":"u1","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\",\"workspace\":\"/tmp\",\"command\":\"rm -rf ./cache\"}"}"#)
        try await pump()

        await controller.respondToApproval(id: "u1", approved: false, scope: .once)
        try await pump()

        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"u1""#) && $0.contains(#""confirmed":false"#)
        })
        guard case .notice(_, let text, false) = controller.items.last else {
            return XCTFail("\(controller.items)")
        }
        XCTAssertEqual(text, "You denied this bash request. Nothing changed.")
    }

    func testSessionScopeAutoApprovesRepeats() async throws {
        let controller = makeController()
        await controller.start()
        let root = controller.workspace.path
        transport.inject(try approvalEvent(
            id: "u1", tool: "write", workspace: root,
            path: root + "/one.txt", content: "one"))
        try await pump()
        await controller.respondToApproval(id: "u1", approved: true, scope: .session)
        transport.inject(try approvalEvent(
            id: "u2", tool: "write", workspace: root,
            path: root + "/nested/two.txt", content: "two"))
        try await pump()
        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"u2""#) && $0.contains(#""confirmed":true"#)
        }, "second write auto-approved for the session")
        XCTAssertFalse(controller.items.contains {
            if case .approval(let request) = $0 { return request.id == "u2" } else { return false }
        })
    }

    func testReadModeAutoApprovesReadsButStillShowsFileChangesAndShell() async throws {
        let controller = makeController()
        await controller.start()
        await controller.setApprovalMode(.approveReads)
        let root = controller.workspace.path

        transport.inject(try approvalEvent(
            id: "read", tool: "read", workspace: root,
            path: "/private/notes.txt", content: ""))
        transport.inject(try approvalEvent(
            id: "write", tool: "write", workspace: root,
            path: root + "/note.txt", content: "note"))
        transport.inject(try approvalEvent(
            id: "bash", tool: "bash", workspace: root,
            path: nil, content: ""))
        try await pump()

        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"read""#) && $0.contains(#""confirmed":true"#)
        })
        for id in ["write", "bash"] {
            XCTAssertTrue(controller.items.contains {
                if case .approval(let request) = $0 { return request.id == id }
                return false
            })
        }
    }

    func testReadEditModeAutoApprovesAddressedFileCallsButStillShowsAmbiguousEditAndShell() async throws {
        let controller = makeController()
        await controller.start()
        await controller.setApprovalMode(.approveReadsAndEdits)
        let root = controller.workspace.path

        for (id, tool, path) in [
            ("read", "read", "/private/notes.txt"),
            ("write", "write", "/private/outside.txt"),
            ("edit", "edit", nil),
        ] {
            transport.inject(try approvalEvent(
                id: id, tool: tool, workspace: root, path: path, content: "change"))
        }
        transport.inject(try approvalEvent(
            id: "bash", tool: "bash", workspace: root, path: nil, content: ""))
        try await pump()

        for id in ["read", "write"] {
            XCTAssertTrue(transport.sentLines.contains {
                $0.contains("\"id\":\"\(id)\"") && $0.contains(#""confirmed":true"#)
            }, id)
        }
        for id in ["edit", "bash"] {
            XCTAssertTrue(controller.items.contains {
                if case .approval(let request) = $0 { return request.id == id }
                return false
            })
        }
    }

    func testModeChangeResolvesAlreadyPendingRequestsItNowAllows() async throws {
        let controller = makeController()
        await controller.start()
        let root = controller.workspace.path

        transport.inject(try approvalEvent(
            id: "read", tool: "read", workspace: root,
            path: "/private/notes.txt", content: ""))
        transport.inject(try approvalEvent(
            id: "bash", tool: "bash", workspace: root, path: nil, content: ""))
        try await pump()

        await controller.setApprovalMode(.approveReads)
        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"read""#) && $0.contains(#""confirmed":true"#)
        })
        XCTAssertTrue(controller.items.contains {
            if case .approval(let request) = $0 { return request.id == "bash" }
            return false
        })

        await controller.setApprovalMode(.fullAccess)
        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"bash""#) && $0.contains(#""confirmed":true"#)
        })
        XCTAssertFalse(controller.items.contains {
            if case .approval = $0 { return true }
            return false
        })
    }

    func testApprovalModeSurvivesSessionClose() async throws {
        let defaults = makeApprovalModeDefaults()
        let controller = makeController(approvalModeDefaults: defaults)
        await controller.setApprovalMode(.fullAccess)
        await controller.start()
        XCTAssertEqual(controller.approvalMode, .fullAccess)

        await controller.shutdown()

        XCTAssertEqual(controller.approvalMode, .fullAccess)
        XCTAssertEqual(
            defaults.integer(forKey: AgentSessionController.approvalModeDefaultsKey),
            AgentApprovalMode.fullAccess.rawValue)
    }

    func testApprovalModeRestoresForAnotherController() async {
        let defaults = makeApprovalModeDefaults()
        let first = makeController(approvalModeDefaults: defaults)
        XCTAssertEqual(first.approvalMode, .askBeforeChanges)

        await first.setApprovalMode(.approveReadsAndEdits)

        let second = makeController(approvalModeDefaults: defaults)
        XCTAssertEqual(second.approvalMode, .approveReadsAndEdits)
    }

    func testApprovalModeDowngradeOverwritesRememberedMode() async {
        let defaults = makeApprovalModeDefaults()
        let controller = makeController(approvalModeDefaults: defaults)

        await controller.setApprovalMode(.fullAccess)
        await controller.setApprovalMode(.approveReads)

        XCTAssertEqual(
            defaults.integer(forKey: AgentSessionController.approvalModeDefaultsKey),
            AgentApprovalMode.approveReads.rawValue)
        let restored = makeController(approvalModeDefaults: defaults)
        XCTAssertEqual(restored.approvalMode, .approveReads)
    }

    func testOutsideAndMissingWritePathsNeverInheritAutomationApproval() async throws {
        let controller = makeController()
        await controller.start()
        controller.approveWorkspaceFileChangesForAutomation()
        let root = controller.workspace.path

        transport.inject(try approvalEvent(
            id: "outside", tool: "write", workspace: root,
            path: "/private/lokalbot-outside.txt", content: "outside"))
        transport.inject(try approvalEvent(
            id: "missing", tool: "edit", workspace: root,
            path: nil, content: "missing"))
        transport.inject(try approvalEvent(
            id: "mismatch", tool: "write", workspace: "/private/other-workspace",
            path: root + "/inside.txt", content: "mismatch"))
        try await pump()

        for id in ["outside", "missing", "mismatch"] {
            XCTAssertTrue(controller.items.contains {
                if case .approval(let request) = $0 { return request.id == id }
                return false
            })
            XCTAssertFalse(transport.sentLines.contains {
                $0.contains("\"id\":\"\(id)\"") && $0.contains(#""confirmed":true"#)
            })
        }
    }

    func testBashAlwaysRequiresOneTimeApproval() async throws {
        let controller = makeController()
        await controller.start()
        controller.approveWorkspaceFileChangesForAutomation()

        transport.inject(#"{"type":"extension_ui_request","id":"bash1","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\",\"workspace\":\"/tmp/project\",\"command\":\"cat ~/.ssh/config\"}"}"#)
        try await pump()
        XCTAssertTrue(controller.items.contains {
            if case .approval(let request) = $0 { return request.id == "bash1" }
            return false
        })
        XCTAssertFalse(transport.sentLines.contains {
            $0.contains(#""id":"bash1""#) && $0.contains(#""confirmed":true"#)
        })

        // A caller cannot persist shell permission even if it requests session
        // scope; the next command must surface independently.
        await controller.respondToApproval(id: "bash1", approved: true, scope: .session)
        transport.inject(#"{"type":"extension_ui_request","id":"bash2","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\",\"workspace\":\"/tmp/project\",\"command\":\"env\"}"}"#)
        try await pump()
        XCTAssertTrue(controller.items.contains {
            if case .approval(let request) = $0 { return request.id == "bash2" }
            return false
        })
        XCTAssertFalse(transport.sentLines.contains {
            $0.contains(#""id":"bash2""#) && $0.contains(#""confirmed":true"#)
        })
    }

    func testIncompleteShellRequestsAreDeniedEvenInFullAccessMode() async throws {
        let controller = makeController()
        await controller.setApprovalMode(.fullAccess)
        await controller.start()
        transport.inject(try approvalEvent(id: "truncated", tool: "bash",
            workspace: controller.workspace.path, path: nil, content: "",
            command: "visible prefix", truncated: true))
        transport.inject(try approvalEvent(id: "oversized", tool: "bash",
            workspace: controller.workspace.path, path: nil, content: "",
            command: String(repeating: "😀", count: 32_769)))
        try await pump()
        XCTAssertTrue(controller.pendingApprovals.isEmpty)
        for id in ["truncated", "oversized"] {
            XCTAssertTrue(transport.sentLines.contains {
                $0.contains("\"id\":\"\(id)\"") && $0.contains(#""confirmed":false"#)
            })
            XCTAssertFalse(transport.sentLines.contains {
                $0.contains("\"id\":\"\(id)\"") && $0.contains(#""confirmed":true"#)
            })
        }
        await controller.shutdown()
    }

    func testOutsideWorkspaceReadAlwaysRequiresOneTimeApproval() async throws {
        let controller = makeController()
        await controller.start()
        controller.approveWorkspaceFileChangesForAutomation()

        transport.inject(#"{"type":"extension_ui_request","id":"read1","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"read\",\"workspace\":\"/tmp/project\",\"path\":\"/private/notes.txt\"}"}"#)
        try await pump()
        XCTAssertTrue(controller.items.contains {
            if case .approval(let request) = $0 { return request.id == "read1" }
            return false
        })
        XCTAssertFalse(transport.sentLines.contains {
            $0.contains(#""id":"read1""#) && $0.contains(#""confirmed":true"#)
        })

        // Even if a caller attempts session scope, reads outside the selected
        // workspace remain one-request capabilities.
        await controller.respondToApproval(id: "read1", approved: true, scope: .session)
        transport.inject(#"{"type":"extension_ui_request","id":"read2","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"read\",\"workspace\":\"/tmp/project\",\"path\":\"/private/other.txt\"}"}"#)
        try await pump()
        XCTAssertTrue(controller.items.contains {
            if case .approval(let request) = $0 { return request.id == "read2" }
            return false
        })
        XCTAssertFalse(transport.sentLines.contains {
            $0.contains(#""id":"read2""#) && $0.contains(#""confirmed":true"#)
        })
    }

    func testNonConfirmUIRequestIsDeclined() async throws {
        let controller = makeController()
        await controller.start()
        transport.inject(#"{"type":"extension_ui_request","id":"u3","method":"input","title":"Enter value"}"#)
        try await pump()
        XCTAssertTrue(transport.sentLines.contains {
            $0.contains(#""id":"u3""#) && $0.contains(#""cancelled":true"#)
        })
        guard case .notice(_, let text, _) = controller.items.last else {
            return XCTFail("expected unsupported-request notice, got \(controller.items)")
        }
        XCTAssertTrue(text.contains("unsupported"))
    }

    func testTransportDeathFailsSession() async throws {
        let controller = makeController()
        await controller.start()
        transport.close()
        try await pump()
        guard case .failed = controller.state else { return XCTFail("\(controller.state)") }
        guard case .notice(_, _, let isError) = controller.items.last else {
            return XCTFail("expected transport failure notice, got \(controller.items)")
        }
        XCTAssertTrue(isError)
    }

    func testRequestFailureTearsDownOldEventLoopBeforeRestart() async throws {
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "http://127.0.0.1:1234/v1"
        settings.openAIModel = "test-model"
        var transports: [FakeTransport] = []
        let controller = AgentSessionController(
            settings: { settings },
            storage: fixtureStorage,
            sessionsDirectory: fixtureRoot.appendingPathComponent("sessions"),
            defaultWorkspace: fixtureRoot.appendingPathComponent("workspace"),
            makeTransport: { _ in
                let transport = FakeTransport()
                transports.append(transport)
                return transport
            })

        await controller.start()
        let first = try XCTUnwrap(transports.first)
        first.failFutureSends()
        await controller.send(prompt: "trigger transport failure")
        guard case .failed = controller.state else {
            return XCTFail("expected failed state, got \(controller.state)")
        }

        await controller.start()
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(transports.count, 2)

        // The first stream is deliberately still open. A late event from it
        // must not mutate the replacement session.
        first.inject(#"{"type":"agent_start"}"#)
        try await pump()
        XCTAssertEqual(controller.state, .ready)

        transports[1].inject(#"{"type":"agent_start"}"#)
        try await pump()
        XCTAssertEqual(controller.state, .running)
    }

    func testFirstPromptNamesSessionAndDraftRequiresCloseConfirmation() async throws {
        let controller = makeController()
        controller.draft = "unsent"
        XCTAssertTrue(controller.requiresCloseConfirmation)
        controller.draft = ""

        await controller.start()
        let send = Task {
            await controller.send(prompt: "Summarize the action items from today's meeting")
        }
        try await pump()
        transport.inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        await send.value

        XCTAssertEqual(controller.sessionTitle, "Summarize the action items from…")
        XCTAssertTrue(controller.requiresCloseConfirmation)
    }

    func testResumeLaunchesContinueAndRestoresVisibleHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-resume-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageManager(rootURL: root.appendingPathComponent("library", isDirectory: true))
        let workspace = root.appendingPathComponent("workspace")
        let header = #"{"type":"session","id":"saved","cwd":"\#(workspace.path)"}"#
        try Data((header + "\n").utf8).write(to: sessions.appendingPathComponent("saved.jsonl"))

        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "http://127.0.0.1:1234/v1"
        settings.openAIModel = "resume-test"
        var transports: [FakeTransport] = []
        var plans: [PiLaunchPlan] = []
        let controller = AgentSessionController(
            settings: { settings },
            storage: storage,
            sessionsDirectory: sessions,
            defaultWorkspace: workspace,
            makeTransport: { plan in
                plans.append(plan)
                let transport = FakeTransport()
                transports.append(transport)
                return transport
            })

        await controller.start()
        XCTAssertTrue(controller.canResumePreviousSession)

        let resume = Task { await controller.resumePreviousSession() }
        for _ in 0..<20 where transports.count < 2 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let resumedTransport = try XCTUnwrap(transports.last)
        for _ in 0..<20 where !resumedTransport.sentLines.contains(where: { $0.contains("get_messages") }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        resumedTransport.inject(#"{"type":"response","id":"history1","command":"get_messages","success":true,"data":{"messages":[{"role":"user","content":"Review yesterday's decisions"},{"role":"assistant","content":[{"type":"text","text":"Here are the decisions."}]}]}}"#)
        await resume.value

        XCTAssertTrue(try XCTUnwrap(plans.last).arguments.contains("--continue"))
        XCTAssertEqual(controller.sessionTitle, "Review yesterday's decisions")
        XCTAssertTrue(controller.items.contains {
            if case .user(_, "Review yesterday's decisions") = $0 { return true }
            return false
        })
        XCTAssertTrue(controller.items.contains {
            if case .assistant(_, "Here are the decisions.", false) = $0 { return true }
            return false
        })
    }

    func testResumeSavedSessionLaunchesExactFileAndWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-exact-resume-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("project", isDirectory: true)
        let sessionFile = root.appendingPathComponent("sessions/saved.jsonl")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sessionFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: sessionFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let saved = AgentSavedSession(
            id: sessionFile.path,
            sessionID: "saved-id",
            fileURL: sessionFile,
            workspace: workspace,
            title: "Saved planning session",
            createdAt: .distantPast,
            modifiedAt: .now,
            messageCount: 2)
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "http://127.0.0.1:1234/v1"
        settings.openAIModel = "resume-test"
        var transports: [FakeTransport] = []
        var plans: [PiLaunchPlan] = []
        let controller = AgentSessionController(
            settings: { settings },
            storage: StorageManager(rootURL: root.appendingPathComponent("library")),
            sessionsDirectory: sessionFile.deletingLastPathComponent(),
            makeTransport: { plan in
                plans.append(plan)
                let transport = FakeTransport()
                transports.append(transport)
                return transport
            })

        let resume = Task { await controller.resumeSavedSession(saved) }
        for _ in 0..<20 where transports.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        let resumedTransport = try XCTUnwrap(transports.first)
        for _ in 0..<20 where !resumedTransport.sentLines.contains(where: {
            $0.contains("get_messages")
        }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        resumedTransport.inject(#"{"type":"response","id":"history1","command":"get_messages","success":true,"data":{"messages":[{"role":"user","content":"Continue the plan"},{"role":"assistant","content":"Continuing."}]}}"#)
        await resume.value

        let plan = try XCTUnwrap(plans.first)
        let sessionIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--session"))
        XCTAssertEqual(plan.arguments[sessionIndex + 1], sessionFile.path)
        XCTAssertFalse(plan.arguments.contains("--continue"))
        XCTAssertEqual(plan.workingDirectory, workspace)
        XCTAssertEqual(controller.activeSessionFile, sessionFile)
        XCTAssertEqual(controller.sessionTitle, "Saved planning session")
        XCTAssertTrue(controller.items.contains {
            if case .notice(_, "Resumed \"Saved planning session\".", false) = $0 { return true }
            return false
        })
    }
}
