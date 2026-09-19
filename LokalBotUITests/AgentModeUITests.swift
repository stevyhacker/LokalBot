import XCTest

/// Runs only on the hosted UI runner. The fixture opts out of model warm-up,
/// subprocesses, capabilities, real tool execution, and network requests.
final class AgentModeUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        try launch()
    }
    override func tearDownWithError() throws {
        app?.terminate(); fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    private func launch(approval: Bool = false) throws {
        let launch = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "AgentMode",
            environment: approval ? ["LOKALBOT_AGENT_UI_TEST_READY": "1", "LOKALBOT_AGENT_UI_TEST_APPROVAL": "1"]
                : ["LOKALBOT_AGENT_UI_TEST_READY": "1"])
        app = launch.app; defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(app.descendants(matching: .any)["today.header"].waitForExistence(timeout: 10))
        UITestHarness.clickSidebar("sidebar.agent", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["agent.tasks"].waitForExistence(timeout: 8))
        XCTAssertTrue(composer.waitForExistence(timeout: 6))
    }

    func testMoreThanFourTasksCanBeCreatedWithoutStartingRuntime() throws {
        for _ in 0..<5 { app.typeKey("n", modifierFlags: .command) }
        XCTAssertTrue(UITestHarness.waitUntil { (try? self.taskRecords().count) == 6 })
        XCTAssertEqual(app.textFields.matching(identifier: "agent.composer").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("agent-ui-rpc.jsonl").path))
        XCTAssertTrue(app.staticTexts["Ready to start"].exists)
    }

    func testSwitchingTasksAndReturningToAgentKeepsDrafts() {
        composer.click(); composer.typeText("First draft")
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(UITestHarness.waitUntil { (self.composer.value as? String)?.isEmpty == true })
        composer.click(); composer.typeText("Second draft")
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        XCTAssertTrue(UITestHarness.waitUntil { self.composer.value as? String == "First draft" })
        UITestHarness.clickSidebar("sidebar.today", in: app)
        UITestHarness.clickSidebar("sidebar.agent", in: app)
        XCTAssertEqual(composer.value as? String, "First draft")
    }

    func testStarterOnlyPrefillsAndRuntimeWaitsForExplicitSend() {
        XCTAssertTrue(app.staticTexts["Ready to start"].waitForExistence(timeout: 4))
        app.buttons["agent.starter.followUp"].click()
        XCTAssertTrue(UITestHarness.waitUntil { (self.composer.value as? String)?.contains("Draft a follow-up") == true })
        XCTAssertTrue(app.staticTexts["Ready to start"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("agent-ui-rpc.jsonl").path))
    }

    func testTaskRenamePinArchiveAndRestoreAreDurable() throws {
        composer.click(); composer.typeText("Keep my archived draft")
        let row = taskRow
        row.rightClick()
        app.menuItems["Rename…"].click()
        let alert = app.alerts.firstMatch.exists ? app.alerts.firstMatch : app.dialogs.firstMatch.exists ? app.dialogs.firstMatch : app.sheets.firstMatch
        let nameField = alert.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 4))
        nameField.click(); nameField.typeKey("a", modifierFlags: .command); nameField.typeText("Weekly follow-up")
        alert.buttons["Save"].click()
        XCTAssertTrue(UITestHarness.waitUntil { (try? self.taskRecords().first?["title"] as? String) == "Weekly follow-up" })
        taskRow.rightClick(); app.menuItems["Pin"].click()
        XCTAssertTrue(UITestHarness.waitUntil { (try? self.taskRecords().first?["isPinned"] as? Bool) == true })
        taskRow.rightClick(); app.menuItems["Archive task"].click()
        XCTAssertTrue(UITestHarness.waitUntil { (try? self.taskRecords().first?["isArchived"] as? Bool) == true })
        XCTAssertTrue(UITestHarness.waitUntil { (self.composer.value as? String)?.isEmpty == true })
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Task options'")).firstMatch.click()
        app.menuItems["Show archived tasks"].click()
        taskRow.click()
        XCTAssertTrue(app.buttons["Restore task to continue"].waitForExistence(timeout: 4))
        app.buttons["Restore task to continue"].click()
        XCTAssertTrue(UITestHarness.waitUntil { self.composer.value as? String == "Keep my archived draft" })
    }

    func testAtMentionAttachesMeetingWithoutSendingIt() {
        composer.click(); composer.typeText("@");
        let search = app.textFields["agent.contextSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        let attach = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Attach '")).firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 4)); attach.click()
        app.buttons["Done"].click()
        XCTAssertTrue(app.descendants(matching: .any)["agent.attachments"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove '")).firstMatch.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("agent-ui-rpc.jsonl").path))
    }

    func testFindAndResultsKeyboardCommands() throws {
        app.terminate(); UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
        try launch(approval: true)
        composer.click(); composer.typeText("Draft a follow-up")
        app.buttons["agent.send"].click()
        XCTAssertTrue(app.descendants(matching: .any)["agent.assistant"].waitForExistence(timeout: 6))
        app.typeKey("f", modifierFlags: .command)
        let find = app.textFields["agent.findField"]
        XCTAssertTrue(find.waitForExistence(timeout: 4)); find.click(); find.typeText("Agent result")
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 3))
        app.buttons["Close find"].click()
        app.buttons["Open in results"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["agent.resultsPanel"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Copy result"].exists)
        app.typeKey("b", modifierFlags: [.command, .option])
        XCTAssertTrue(UITestHarness.waitUntil { !self.app.descendants(matching: .any)["agent.resultsPanel"].exists })
    }

    func testQueuedFollowUpCanBeCanceledWhileApprovalRemainsDocked() throws {
        app.terminate(); UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
        try launch(approval: true)
        composer.click(); composer.typeText("Draft a follow-up")
        app.buttons["agent.send"].click()
        let deny = app.buttons["agent.approve.deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 6))
        composer.click(); composer.typeText("Then make it shorter")
        app.buttons["agent.send"].click()
        let queue = app.descendants(matching: .any)["agent.queue"]
        XCTAssertTrue(queue.waitForExistence(timeout: 4)); queue.click()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3)); cancel.click()
        XCTAssertTrue(deny.exists)
        let log = try String(contentsOf: fixture.root.appendingPathComponent("agent-ui-rpc.jsonl"), encoding: .utf8)
        XCTAssertFalse(log.contains("Then make it shorter"))
        deny.click(); app.buttons["agent.stop"].click()
    }

    private var composer: XCUIElement { app.textFields["agent.composer"] }
    private var taskRow: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'agent.task.'")).firstMatch
    }
    private func taskRecords() throws -> [[String: Any]] {
        let data = try Data(contentsOf: fixture.root.appendingPathComponent("agent/sessions/tasks.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
}
