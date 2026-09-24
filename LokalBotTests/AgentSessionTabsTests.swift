import XCTest
@testable import LokalBot

@MainActor
final class AgentSessionTabsTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-tabs-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    func testAddingTabCreatesIndependentSelectedSession() async throws {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        let first = try XCTUnwrap(sessions.selectedTab)
        let second = sessions.addSession()

        XCTAssertEqual(sessions.tabs.count, 2)
        XCTAssertEqual(sessions.selectedID, second.id)
        XCTAssertFalse(first.controller === second.controller)

        await first.controller.start()
        await second.controller.start()
        XCTAssertEqual(first.controller.state, .ready)
        XCTAssertEqual(second.controller.state, .ready)

        let firstSend = Task { await first.controller.send(prompt: "first tab") }
        let secondSend = Task { await second.controller.send(prompt: "second tab") }
        try await Task.sleep(for: .milliseconds(50))
        factory.transports[0].inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        factory.transports[1].inject(#"{"type":"response","id":"p1","command":"prompt","success":true}"#)
        await firstSend.value
        await secondSend.value

        XCTAssertTrue(first.controller.items.contains {
            if case .user(_, "first tab") = $0 { return true }
            return false
        })
        XCTAssertFalse(first.controller.items.contains {
            if case .user(_, "second tab") = $0 { return true }
            return false
        })
        XCTAssertTrue(second.controller.items.contains {
            if case .user(_, "second tab") = $0 { return true }
            return false
        })
    }

    func testArchivingTaskPreservesItsHistoryAndStopsOnlyItsRuntime() async {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        let first = sessions.tabs[0]
        let second = sessions.addSession()
        await first.controller.start()
        await second.controller.start()

        await sessions.close(first.id)

        XCTAssertEqual(sessions.tabs.map(\.id), [first.id, second.id])
        XCTAssertTrue(sessions.tabs[0].record.isArchived)
        XCTAssertEqual(sessions.selectedID, second.id)
        XCTAssertEqual(first.controller.state, .idle)
        XCTAssertEqual(second.controller.state, .ready)
    }

    func testClosingFinalTabCreatesFreshSession() async {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        let original = sessions.tabs[0]

        await sessions.close(original.id)

        XCTAssertEqual(sessions.tabs.count, 2)
        XCTAssertTrue(sessions.tabs[0].record.isArchived)
        XCTAssertNotEqual(sessions.selectedID, original.id)
        XCTAssertEqual(original.controller.state, .idle)
    }

    func testShutdownAllStopsEverySessionWithoutCreatingReplacement() async {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        let first = sessions.tabs[0]
        let second = sessions.addSession()
        await first.controller.start()
        await second.controller.start()

        await sessions.shutdownAll()

        XCTAssertTrue(sessions.tabs.isEmpty)
        XCTAssertEqual(first.controller.state, .idle)
        XCTAssertEqual(second.controller.state, .idle)
    }

    func testBrowsingTasksIsIndependentOfLiveProcessLimit() {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        for _ in 0..<(AgentSessionTabs.maximumLiveSessions + 3) {
            _ = sessions.addSession()
        }
        XCTAssertEqual(sessions.tabs.count, AgentSessionTabs.maximumLiveSessions + 4)
        XCTAssertTrue(factory.plans.isEmpty, "adding or browsing tasks must not start Pi")
    }

    func testClearSavedHistoryStopsSessionsRemovesFilesAndCreatesFreshTab() async throws {
        let factory = Factory(root: root)
        try FileManager.default.createDirectory(
            at: factory.sessionsDirectory, withIntermediateDirectories: true)
        try Data("history".utf8).write(
            to: factory.sessionsDirectory.appendingPathComponent("saved.jsonl"))
        let sessions = AgentSessionTabs { factory.makeController() }
        let original = sessions.tabs[0]
        await original.controller.start()

        try await sessions.clearSavedHistory()

        XCTAssertEqual(original.controller.state, .idle)
        XCTAssertEqual(sessions.tabs.count, 1)
        XCTAssertNotEqual(sessions.tabs[0].id, original.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: factory.sessionsDirectory,
            includingPropertiesForKeys: nil).map(\.lastPathComponent), ["tasks.json"])
        XCTAssertTrue(try AgentTaskStore(directory: factory.sessionsDirectory).load().allSatisfy { $0.draft.isEmpty && $0.sessionFile == nil })
    }

    func testLoadsAndOpensExactSavedSessionInBlankTab() async throws {
        let factory = Factory(root: root)
        try FileManager.default.createDirectory(
            at: factory.sessionsDirectory,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: factory.storage.rootURL, withIntermediateDirectories: true)
        let savedFile = factory.sessionsDirectory.appendingPathComponent("saved.jsonl")
        try writeSession(
            id: "saved-session",
            title: "Reopen this conversation",
            workspace: factory.storage.rootURL,
            to: savedFile)
        let sessions = AgentSessionTabs { factory.makeController() }
        let originalTab = try XCTUnwrap(sessions.selectedTab)

        let loaded = try await sessions.loadSavedSessions()
        let saved = try XCTUnwrap(loaded.first)
        try await sessions.openSavedSession(saved)

        XCTAssertEqual(sessions.tabs.count, 1, "a blank selected tab should be reused")
        XCTAssertEqual(sessions.selectedID, originalTab.id)
        XCTAssertEqual(originalTab.controller.activeSessionFile, savedFile)
        XCTAssertEqual(originalTab.controller.sessionTitle, "Reopen this conversation")
        XCTAssertTrue(sessions.isOpen(saved))
        XCTAssertTrue(factory.plans.isEmpty, "opening saved history is read-only")
        XCTAssertEqual(originalTab.controller.state, .idle)
        XCTAssertTrue(originalTab.controller.items.contains { $0.searchableText == "Reopen this conversation" })
        try await sessions.openSavedSession(saved)
        XCTAssertEqual(sessions.selectedID, originalTab.id, "reopening an open task should select it")
        XCTAssertNotNil(originalTab.controller.workspaceAccessNotice)
        let started = await sessions.start(originalTab.id)
        XCTAssertFalse(started, "legacy private-library history must stay readable without reopening its old access")
        XCTAssertTrue(factory.plans.isEmpty)
        XCTAssertEqual(originalTab.controller.activeSessionFile, savedFile)
        XCTAssertTrue(originalTab.controller.items.contains { $0.searchableText == "Reopen this conversation" })
    }

    func testRestoredPrivateWorkspaceMetadataKeepsDraftButCannotLaunch() async throws {
        let factory = Factory(root: root)
        var record = AgentTaskRecord(id: UUID(), workspace: factory.storage.rootURL)
        record.draft = "Preserved unsent prompt"
        try AgentTaskStore(directory: factory.sessionsDirectory).save([record])
        let sessions = AgentSessionTabs { factory.makeController() }
        let restored = try XCTUnwrap(sessions.selectedTab)
        XCTAssertEqual(restored.controller.draft, record.draft)
        XCTAssertNotNil(restored.controller.workspaceAccessNotice)
        let started = await sessions.start(restored.id)
        XCTAssertFalse(started)
        XCTAssertTrue(factory.plans.isEmpty)
        let fresh = sessions.addSession()
        XCTAssertNil(fresh.controller.workspaceAccessNotice)
        XCTAssertNotEqual(fresh.controller.workspace, factory.storage.rootURL)
        await sessions.shutdownAll()
    }

    func testRuntimeLimitRejectsFifthBusyAgentWithoutBlockingTaskCreation() async throws {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        for index in 0..<4 {
            let tab = index == 0 ? sessions.tabs[0] : sessions.addSession()
            let started = await sessions.start(tab.id)
            XCTAssertTrue(started)
            factory.transports[index].inject(#"{"type":"agent_start"}"#)
            try await Task.sleep(for: .milliseconds(30))
        }
        let fifth = sessions.addSession()
        let started = await sessions.start(fifth.id)
        XCTAssertFalse(started)
        XCTAssertEqual(fifth.controller.state, .idle)
        XCTAssertEqual(factory.plans.count, 4)
        XCTAssertEqual(sessions.tabs.count, 5)
        await sessions.shutdownAll()
    }

    func testIdleRuntimeIsParkedWhenAnotherTaskStarts() async {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        for index in 0..<4 {
            let tab = index == 0 ? sessions.tabs[0] : sessions.addSession()
            _ = await sessions.start(tab.id)
        }
        let fifth = sessions.addSession()
        let started = await sessions.start(fifth.id)
        XCTAssertTrue(started)
        XCTAssertEqual(sessions.tabs.filter { $0.controller.hasLiveRuntime }.count, 4)
        XCTAssertEqual(sessions.tabs.first?.controller.state, .idle)
        XCTAssertNil(sessions.tabs.first?.controller.modelContext, "a parked task must show the destination for its next connection")
        await sessions.shutdownAll()
    }

    func testDraftTitlePinAndArchiveSurviveRelaunchWithoutSpawning() async throws {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        let first = try XCTUnwrap(sessions.selectedTab)
        first.controller.draft = "A saved draft"
        first.controller.attachments = [.file(root.appendingPathComponent("notes.md"))]
        sessions.rename(first.id, to: "Project follow-up")
        sessions.togglePin(first.id)
        await sessions.setArchived(first.id, true)
        await sessions.shutdownAll()

        let restored = AgentSessionTabs { factory.makeController() }
        let task = try XCTUnwrap(restored.tabs.first { $0.id == first.id })
        XCTAssertEqual(task.title, "Project follow-up")
        XCTAssertTrue(task.record.isPinned)
        XCTAssertTrue(task.record.isArchived)
        XCTAssertEqual(task.controller.draft, "A saved draft")
        XCTAssertEqual(task.controller.attachments.count, 1)
        XCTAssertTrue(factory.plans.isEmpty)
        await restored.shutdownAll()
    }

    func testConcurrentStartsKeepRuntimeLimitAndArchivedTasksCannotRun() async {
        let factory = Factory(root: root)
        let sessions = AgentSessionTabs { factory.makeController() }
        for _ in 0..<5 { sessions.addSession() }
        let starts = sessions.tabs.map { tab in Task { await sessions.start(tab.id) } }
        for start in starts { _ = await start.value }
        XCTAssertLessThanOrEqual(sessions.tabs.filter { $0.controller.hasLiveRuntime }.count, 4)
        let first = sessions.tabs[0]
        await sessions.setArchived(first.id, true)
        sessions.select(first.id)
        let started = await sessions.start(first.id)
        XCTAssertFalse(started)
        XCTAssertFalse(sessions.ensureSelectedController() === first.controller)
        await sessions.shutdownAll()
    }


    private func writeSession(
        id: String,
        title: String,
        workspace: URL,
        to file: URL
    ) throws {
        let records: [[String: Any]] = [
            [
                "type": "session",
                "id": id,
                "timestamp": "2026-08-05T20:52:04.304Z",
                "cwd": workspace.path,
            ],
            [
                "type": "message",
                "message": [
                    "role": "user",
                    "content": title,
                    "timestamp": 1_785_963_156_269 as Int64,
                ],
            ],
        ]
        let lines = try records.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    }
}

@MainActor
private final class Factory {
    let storage: StorageManager
    let sessionsDirectory: URL
    private(set) var transports: [FakeTransport] = []
    private(set) var plans: [PiLaunchPlan] = []

    init(root: URL) {
        storage = StorageManager(rootURL: root.appendingPathComponent("library"))
        sessionsDirectory = root.appendingPathComponent("agent-sessions", isDirectory: true)
    }

    func makeController() -> AgentSessionController {
        let transport = FakeTransport()
        transports.append(transport)
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "http://127.0.0.1:1234/v1"
        settings.openAIModel = "tabs-test"
        return AgentSessionController(
            settings: { settings },
            storage: storage,
            sessionsDirectory: sessionsDirectory,
            makeTransport: { plan in
                self.plans.append(plan)
                return transport
            })
    }
}
