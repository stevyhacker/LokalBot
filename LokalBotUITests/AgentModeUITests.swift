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

    private func launch(approval: Bool = false, appearance: String? = nil) throws {
        var environment = ["LOKALBOT_AGENT_UI_TEST_READY": "1"]
        if approval { environment["LOKALBOT_AGENT_UI_TEST_APPROVAL"] = "1" }
        if let appearance { environment["LOKALBOT_CAPTURE_APPEARANCE"] = appearance }
        let launch = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "AgentMode",
            environment: environment)
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
        snapshot("agent-restored-task")
    }

    func testAtMentionAttachesMeetingWithoutSendingIt() {
        composer.click(); composer.typeText("@")
        let search = app.textFields["agent.contextSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        let attach = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Attach '")).firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 4)); attach.click()
        app.buttons["Done"].click()
        XCTAssertTrue(app.descendants(matching: .any)["agent.attachments"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove '")).firstMatch.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("agent-ui-rpc.jsonl").path))
        snapshot("agent-attached-context")
    }

    func testLegacyPrivateLibraryTaskKeepsHistoryAndDraftWithoutStartingRuntime() throws {
        app.terminate(); UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
        let directory = fixture.root.appendingPathComponent("agent/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let records: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "private-root", "cwd": fixture.root.path],
            ["type": "message", "id": "question", "message": ["role": "user", "content": "Legacy private library task"]],
            ["type": "message", "id": "answer", "parentId": "question",
             "message": ["role": "assistant", "content": "Saved history stays readable."]],
        ]
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent("private-root.jsonl"))
        try launch(approval: true)
        let search = app.textFields["agent.taskSearch"]
        search.click(); search.typeText("Legacy private library task")
        XCTAssertTrue(taskRow.waitForExistence(timeout: 4)); taskRow.click()
        XCTAssertTrue(app.descendants(matching: .any)["agent.assistant"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["agent.workspaceNotice"].exists)
        composer.click(); composer.typeText("Keep this draft")
        app.buttons["agent.send"].click()
        XCTAssertTrue(UITestHarness.waitUntil {
            (try? self.taskRecords().contains { $0["draft"] as? String == "Keep this draft" }) == true
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("agent-ui-rpc.jsonl").path))
        snapshot("agent-private-library-task")
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
        responseMore.click()
        app.menuItems["Open in results"].click()
        XCTAssertTrue(app.descendants(matching: .any)["agent.resultsPanel"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Copy result"].exists)
        snapshot("agent-results-inspector")
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
        XCTAssertTrue(queue.waitForExistence(timeout: 4))
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3)); cancel.click()
        XCTAssertTrue(UITestHarness.waitUntil { !queue.exists })
        XCTAssertTrue(deny.exists)
        snapshot("agent-docked-approval")
        let log = try String(contentsOf: fixture.root.appendingPathComponent("agent-ui-rpc.jsonl"), encoding: .utf8)
        XCTAssertFalse(log.contains("Then make it shorter"))
        app.buttons["agent.stop"].click()
        XCTAssertTrue(UITestHarness.waitUntil { !deny.exists && !self.app.buttons["agent.stop"].exists })
    }

    func testResponseSelectionCopiesAcrossHeadingsListsAndCode() throws {
        app.terminate(); UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
        try launch(approval: true)
        composer.click(); composer.typeText("Draft a follow-up")
        app.buttons["agent.send"].click()
        let answer = app.textViews["agent.assistant"]
        XCTAssertTrue(answer.waitForExistence(timeout: 6))
        XCTAssertTrue(app.descendants(matching: .any)["agent.taskTitle"].exists)
        XCTAssertFalse(app.buttons["Open in results"].exists)
        answer.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        composer.click()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(UITestHarness.waitUntil {
            let copied = self.composer.value as? String ?? ""
            return copied.contains("Agent result\n") && copied.contains("• Parent\n")
                && copied.contains("let value = 1") && copied.contains("Agent │ Ready")
        }, "Selection must span the complete answer without separate selection islands")
        // Clear the pasted draft so the capture shows the conversation hierarchy.
        composer.typeKey("a", modifierFlags: .command)
        composer.typeKey(.delete, modifierFlags: [])
        snapshot("agent-response-hierarchy")
    }

    /// Exercise an actual edge drag after opening long history. A startup
    /// capture at a small size misses content-driven native window minimums.
    func testLongSavedConversationCanShrinkWithoutClippingActions() throws {
        app.terminate(); UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
        let directory = fixture.root.appendingPathComponent("agent/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paragraph = "A compact window should wrap this saved response while keeping its message actions and composer reachable. "
        let response = "## Compact reading\n\n" + String(repeating: paragraph, count: 3)
            + "\n\n**Next steps**\n\n- " + String(repeating: paragraph, count: 2)
            + "\n  - Keep nested items readable.\n- Review `notes/meeting-summary.md` before sending.\n\nThe response and its actions should stay connected."
        let records: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "compact", "cwd": fixture.root.path],
            ["type": "message", "id": "user", "message": ["role": "user", "content": "Compact conversation with a long saved response"]],
            ["type": "message", "id": "answer", "parentId": "user", "message": ["role": "assistant", "content": response]],
        ]
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("compact.jsonl"))

        for appearance in ["light", "dark"] {
            try launch(appearance: appearance)
            let search = app.textFields["agent.taskSearch"]
            search.click(); search.typeText("Compact conversation")
            XCTAssertTrue(taskRow.waitForExistence(timeout: 4)); taskRow.click()
            let answer = app.descendants(matching: .any)["agent.assistant"]
            XCTAssertTrue(answer.waitForExistence(timeout: 4))

            resizeWindow(to: 760)
            let retry = app.buttons["Retry response"].firstMatch
            let more = responseMore
            let transcript = app.scrollViews["agent.transcript"]
            UITestHarness.scrollTo(more, in: app, within: transcript)
            XCTAssertTrue(retry.isHittable)
            XCTAssertTrue(more.isHittable)
            XCTAssertTrue(transcript.frame.contains(more.frame))
            let composerSurface = app.descendants(matching: .any)["agent.composerSurface"]
            XCTAssertLessThanOrEqual(answer.frame.width, composerSurface.frame.width + 4)
            XCTAssertLessThanOrEqual(more.frame.maxX, app.windows["main.window"].frame.maxX - 10)
            more.click()
            XCTAssertTrue(app.menuItems["Branch from here"].exists)
            XCTAssertTrue(app.menuItems["Open in results"].isEnabled)
            app.typeKey(.escape, modifierFlags: [])
            snapshot("agent-compact-760-\(appearance)")

            // Query the toolbar's direct child to avoid its nested AX wrapper.
            app.windows["main.window"].toolbars.firstMatch.children(matching: .button)
                .matching(identifier: "toolbar.sidebarToggle").firstMatch.click()
            XCTAssertTrue(UITestHarness.waitUntil {
                !self.app.descendants(matching: .any)["sidebar.settings"].exists
            })
            resizeWindow(to: 600)
            UITestHarness.scrollTo(more, in: app, within: transcript)
            XCTAssertTrue(retry.isHittable)
            XCTAssertTrue(transcript.frame.contains(more.frame))
            XCTAssertTrue(composer.isHittable)
            XCTAssertLessThanOrEqual(app.buttons["agent.send"].frame.maxX, app.windows["main.window"].frame.maxX - 10)
            snapshot("agent-compact-600-\(appearance)")
            retry.click()
            XCTAssertTrue(UITestHarness.waitUntil { (self.composer.value as? String)?.contains("Compact conversation") == true })
            app.terminate(); UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
        }
    }

    private func resizeWindow(to width: CGFloat) {
        let window = app.windows["main.window"]
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.75))
            .withOffset(CGVector(dx: -1, dy: 0))
        let target = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.75))
            .withOffset(CGVector(dx: width - 1, dy: 0))
        edge.press(forDuration: 0.1, thenDragTo: target)
        XCTAssertTrue(UITestHarness.waitUntil { abs(window.frame.width - width) <= 4 },
                      "Window could not shrink to \(width) points; actual width: \(window.frame.width)")
    }

    private var responseMore: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "agent.responseMore").firstMatch
    }
    private var composer: XCUIElement { app.textFields["agent.composer"] }
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private var taskRow: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'agent.task.'")).firstMatch
    }
    private func taskRecords() throws -> [[String: Any]] {
        let data = try Data(contentsOf: fixture.root.appendingPathComponent("agent/sessions/tasks.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
}
