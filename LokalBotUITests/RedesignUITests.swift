import AppKit
import XCTest

/// Hosted-only review of the integrated redesign against synthetic evidence.
/// Screenshots remain in the test result bundle; no private library is used.
final class RedesignUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var suite: String?
    private var previousVisualFixtures: [SyntheticFixture.Library] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
    }
    override func tearDownWithError() throws {
        app?.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: suite)
        fixture?.cleanUp()
        previousVisualFixtures.forEach { $0.cleanUp() }
    }

    func testWorkspaceVisualMatrix() throws {
        // Collect route assertion failures across the matrix for review. Any
        // failed assertion still fails this test and the aggregate release gate.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        let routes: [(String, [String: String])] = [
            ("today", ["LOKALBOT_INITIAL_SECTION": "today"]),
            ("actions", ["LOKALBOT_INITIAL_ACTIONS": "1"]),
            ("meeting", ["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0"]),
            ("transcript", ["LOKALBOT_INITIAL_SECTION": "meetings", "LOKALBOT_SELECT_INDEX": "0", "LOKALBOT_DETAIL_TAB": "transcript"]),
            ("timeline", ["LOKALBOT_INITIAL_SECTION": "timeline"]),
            ("search", ["LOKALBOT_INITIAL_SECTION": "ask", "LOKALBOT_INITIAL_ASK_MODE": "search", "LOKALBOT_INITIAL_SEARCH": "failover"]),
            ("ask", ["LOKALBOT_INITIAL_SECTION": "ask"]),
            ("settings", ["LOKALBOT_INITIAL_SECTION": "settings", "LOKALBOT_INITIAL_SETTINGS_CATEGORY": "privacy"]),
            ("models", ["LOKALBOT_INITIAL_SECTION": "models"]),
            ("dictation", ["LOKALBOT_INITIAL_SECTION": "dictation"]),
            ("autocomplete", ["LOKALBOT_INITIAL_SECTION": "autocomplete", "LOKALBOT_COTYPING_DEMO": "1"]),
            ("agent", ["LOKALBOT_INITIAL_SECTION": "agent", "LOKALBOT_AGENT_DEMO": "1"]),
        ]
        let processEnvironment = ProcessInfo.processInfo.environment
        let requestedSize = processEnvironment["LOKALBOT_VISUAL_SIZE"] ?? ""
        let allSizes = ["1000x700", "1180x740", "1440x900"]
        XCTAssertTrue(requestedSize.isEmpty || allSizes.contains(requestedSize), "Unknown visual shard")
        let sizes = requestedSize.isEmpty ? allSizes : [requestedSize]
        for size in sizes {
            for appearance in ["light", "dark"] {
                for (route, state) in routes {
                    // A complete matrix can cross midnight. Keep Today and
                    // Timeline populated on the new civil day, while retaining
                    // earlier attachment files until XCTest serializes them.
                    if !Calendar.current.isDateInToday(fixture.designReview.startedAt) {
                        previousVisualFixtures.append(fixture)
                        fixture = try SyntheticFixture.plant()
                    }
                    let name = "\(size)-\(appearance)-\(route)"
                    let destination = fixture.root.appendingPathComponent(name + ".png")
                    var environment = state
                    environment.merge([
                        "LOKALBOT_CAPTURE_FILE": destination.path,
                        "LOKALBOT_CAPTURE_SIZE": size, "LOKALBOT_CAPTURE_SCALE": "1", "LOKALBOT_CAPTURE_DELAY": "8",
                        "LOKALBOT_CAPTURE_APPEARANCE": appearance, "LOKALBOT_SCREEN_MEMORY_DEMO": "1",
                        "LOKALBOT_AGENT_UI_TEST_READY": "1",
                    ]) { _, value in value }
                    let readyFile = destination.appendingPathExtension("ready")
                    if processEnvironment["LOKALBOT_CAPTURE_MODE"] != "legacy" {
                        environment["LOKALBOT_CAPTURE_READY_FILE"] = readyFile.path
                    }
                    try launch(environment)
                    if environment["LOKALBOT_CAPTURE_READY_FILE"] != nil {
                        try acknowledgeCaptureReadiness(route: route, size: size, readyFile: readyFile)
                    }
                    XCTAssertTrue(UITestHarness.waitUntil(timeout: 20) { FileManager.default.fileExists(atPath: destination.path) },
                                  "Native capture did not finish: \(name)")
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: destination)))
                    XCTAssertEqual(bitmap.pixelsWide, Int(size.split(separator: "x")[0]), "Capture width must match the requested layout")
                    XCTAssertEqual(bitmap.pixelsHigh, Int(size.split(separator: "x")[1]), "Capture height must match the requested layout")
                    let attachment = XCTAttachment(contentsOfFile: destination)
                    attachment.name = name; attachment.lifetime = .keepAlways
                    add(attachment)
                    if let evidencePath = processEnvironment["LOKALBOT_VISUAL_EVIDENCE"] {
                        let directory = URL(fileURLWithPath: evidencePath, isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: destination, to: directory.appendingPathComponent(name + ".png"))
                    }
                }
            }
        }
    }

    private func acknowledgeCaptureReadiness(route: String, size: String, readyFile: URL) throws {
        let anchors = [
            "today": "today.dayDigest.text", "actions": "actions.search",
            "meeting": "meeting.audioPlayer", "transcript": "transcript.segment.0.text",
            "timeline": "timeline.workSessions", "search": "search.hit.\(fixture.designReview.id.uuidString).segment",
            "ask": "ask.submit", "settings": "settings.retention", "models": "models.overview",
            "dictation": "dictation.form", "agent": "agent.composer",
        ]
        if let identifier = anchors[route] {
            XCTAssertTrue(element(identifier).waitForExistence(timeout: 10), "Capture content not ready: \(route)")
        } else {
            XCTAssertTrue(app.staticTexts["Try the real autocomplete"].waitForExistence(timeout: 10))
        }
        if route == "timeline" {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Xcode"))
                .firstMatch.waitForExistence(timeout: 5), "Capture must include the seeded work session")
            XCTAssertTrue(element("capture.meeting.\(fixture.designReview.id.uuidString)").exists,
                          "Capture must include the seeded meeting")
        }
        if route == "meeting" || route == "transcript" {
            let title = element("detail.title")
            let expectedTitle = fixture.designReview.title
            XCTAssertTrue(UITestHarness.waitUntil(timeout: 5) {
                (title.value as? String ?? title.label) == expectedTitle
            }, "Capture must select the requested meeting")
        }
        let dimensions = size.split(separator: "x").compactMap { Double($0) }
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 5) {
            let frame = self.app.windows.firstMatch.frame
            return abs(frame.width - dimensions[0]) < 1 && abs(frame.height - dimensions[1]) < 1
        }, "Capture window has not reached the requested geometry")
        try Data("ready".utf8).write(to: readyFile, options: .atomic)
    }

    func testSearchReturnIsSilentAndExplicitAskReviewsScope() throws {
        try launch()
        UITestHarness.clickSidebar("sidebar.ask", in: app)
        UITestHarness.selectSegment("Search", pickerIdentifier: "ask.retrieval", in: app)
        let input = app.textFields["search.field"]
        input.click(); input.typeText("failover")
        XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 6))
        input.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["transcript.segment.3.text"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["chat.message.user"].exists)
        XCTAssertTrue(app.buttons["Play"].exists, "Evidence should be paused until Play is chosen")
        app.buttons["Back"].firstMatch.click()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "failover")
        app.buttons["ask.escalate"].click()
        XCTAssertTrue(element("ask.selectedEvidence").exists)
        XCTAssertFalse(app.staticTexts["chat.message.user"].exists)
        snapshot("bounded-ask-draft")
    }

    func testAutocompleteAcceptsPhysicalTabAndEscapeDismissesGhost() throws {
        try launch(["LOKALBOT_COTYPING_DEMO": "1"])
        UITestHarness.clickSidebar("sidebar.type", in: app)
        UITestHarness.selectSegment("Autocomplete", pickerIdentifier: "type.tab", in: app)
        let start = app.buttons["Start"]
        UITestHarness.scrollTo(start, in: app)
        start.click()
        XCTAssertTrue(UITestHarness.waitUntil { self.app.buttons["Insert suggestion"].isEnabled })
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(UITestHarness.staticText(containing: "Rehearsal complete", in: app).waitForExistence(timeout: 4))
        app.buttons["Restart"].click()
        XCTAssertTrue(UITestHarness.waitUntil { self.app.buttons["Insert suggestion"].isEnabled })
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["Insert suggestion"].isEnabled)
        XCTAssertFalse(UITestHarness.staticText(containing: "Rehearsal complete", in: app).exists)
        let editor = app.textViews["autocomplete.rehearsal.editor"]
        let textBeforeNavigation = editor.value as? String
        XCTAssertNotNil(textBeforeNavigation)
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(editor.value as? String, textBeforeNavigation, "Tab without a suggestion should navigate, not insert a tab")
        app.typeKey(.tab, modifierFlags: .shift)
        XCTAssertEqual(editor.value as? String, textBeforeNavigation, "Shift-Tab should preserve the rehearsal text")
        snapshot("autocomplete-keyboard-rehearsal")
    }

    func testHighContrastKeepsActionsAccessible() throws {
        try launch(["LOKALBOT_CAPTURE_APPEARANCE": "contrast-dark"])
        XCTAssertTrue(app.buttons["toolbar.record"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(element("settings.categories").waitForExistence(timeout: 5))
        app.textFields["settings.search"].click()
        app.textFields["settings.search"].typeText("retention")
        XCTAssertTrue(element("settings.searchResults").waitForExistence(timeout: 5))
        XCTAssertTrue(UITestHarness.staticText(containing: "Results across all categories", in: app).exists)
        try auditWorkspaceAccessibility()
        snapshot("settings-high-contrast")
    }

    func testReducedMotionWorkspaceRemainsOperable() throws {
        guard UserDefaults(suiteName: "org.localhost.lokalbot.redesign-ci")?.bool(forKey: "requiresReducedMotion") == true else {
            throw XCTSkip("Runs in the dedicated hosted Reduce Motion step")
        }
        XCTAssertTrue(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "The hosted runner must actually enable Reduce Motion")
        try launch(["LOKALBOT_CAPTURE_APPEARANCE": "contrast-dark", "LOKALBOT_SCREEN_MEMORY_DEMO": "1"])
        UITestHarness.clickSidebar("sidebar.timeline", in: app)
        XCTAssertTrue(element("timeline.workSessions").waitForExistence(timeout: 5))
        UITestHarness.clickSidebar("sidebar.meetings", in: app)
        for meeting in [fixture.designReview, fixture.standup] {
            element("meeting.row.\(meeting.id.uuidString)").click()
            XCTAssertTrue(UITestHarness.waitUntil {
                let title = self.element("detail.title")
                return title.exists && (title.value as? String ?? title.label) == meeting.title
            })
            XCTAssertTrue(element("meeting.contentTabs").isHittable)
        }
        UITestHarness.clickSidebar("sidebar.ask", in: app)
        UITestHarness.selectSegment("Search", pickerIdentifier: "ask.retrieval", in: app)
        app.textFields["search.field"].click()
        app.textFields["search.field"].typeText("failover")
        XCTAssertTrue(element("search.hit.\(fixture.designReview.id.uuidString).segment").waitForExistence(timeout: 6))
        try auditWorkspaceAccessibility()
        snapshot("search-reduced-motion")
    }

    func testRetentionReviewCancelPreservesPolicy() throws {
        try launch(["LOKALBOT_SCREEN_MEMORY_DEMO": "1"])
        UITestHarness.clickSidebar("sidebar.settings", in: app)
        UITestHarness.selectSettingsCategory("Privacy & Data", in: app)
        let before = UserDefaults(suiteName: suite!)?.data(forKey: "lokalbotv3.settings")
        let review = app.buttons["Review expired context…"]
        UITestHarness.scrollTo(review, in: app)
        review.click()
        XCTAssertTrue(app.buttons["retention.confirm"].waitForExistence(timeout: 5))
        snapshot("retention-review-before-cancel")
        app.buttons["Cancel"].click()
        XCTAssertTrue(UITestHarness.waitUntil { !self.app.buttons["retention.confirm"].exists },
                      "Cancel should close retention review without applying its policy")
        XCTAssertEqual(UserDefaults(suiteName: suite!)?.data(forKey: "lokalbotv3.settings"), before)
    }

    func testFourHundredActionsStaySearchableAndCompletionCanBeUndone() throws {
        let folder = fixture.folder(for: fixture.designReview)
        let actions: [[String: Any]] = (0..<400).map { index in
            ["id": "large-action-\(index)", "schemaVersion": 2, "text": "Synthetic commitment \(index)",
             "owner": "Me", "isForUser": true, "due": "Friday", "citations": []]
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "actionItems": actions])
        try data.write(to: folder.appendingPathComponent("outcomes.json"))
        try launch()
        app.buttons["Review actions"].click()
        let search = app.textFields["actions.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("Synthetic commitment 399")
        // Failure messages repeat the action title; inspect only its list row.
        let action = element("actions.list").staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@",
                        "Synthetic commitment 399", "Synthetic commitment 399")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()
        search.click(); search.typeKey("a", modifierFlags: .command)
        search.typeText("Synthetic commitment 398")
        XCTAssertTrue(element("actions.selection.hidden").waitForExistence(timeout: 5),
                      "Filtering should preserve the selected action while excluding it from the batch")
        XCTAssertFalse(element("actions.batch").isEnabled)
        search.click(); search.typeKey("a", modifierFlags: .command)
        search.typeText("Synthetic commitment 399")
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(element("actions.batch").isEnabled, "Returning to the action should restore its selection")
        XCTAssertFalse(element("actions.selection.hidden").exists)
        let complete = app.buttons["outcome.action.toggle.\(fixture.designReview.id.uuidString):large-action-399"]
        XCTAssertTrue(complete.waitForExistence(timeout: 4))
        complete.click()
        XCTAssertTrue(UITestHarness.waitUntil { !action.exists })
        app.buttons["outcomes.undo"].click()
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        snapshot("four-hundred-actions-search-and-undo")
        let stateFile = folder.appendingPathComponent("outcome-state.json")
        try withBlockedStateFile(stateFile) {
            complete.click()
            XCTAssertTrue(UITestHarness.staticText(containing: "Could not update this action", in: app)
                .waitForExistence(timeout: 4))
            XCTAssertTrue(action.exists, "A failed save must preserve the open action")
        }
        complete.click()
        XCTAssertTrue(UITestHarness.waitUntil { !action.exists })
        XCTAssertFalse(UITestHarness.staticText(containing: "Could not update this action", in: app).exists,
                       "A successful retry should clear the previous save error")
        try withBlockedStateFile(stateFile) {
            app.buttons["outcomes.undo"].click()
            let undoFailure = UITestHarness.staticText(containing: "Could not undo", in: app)
            XCTAssertTrue(undoFailure.waitForExistence(timeout: 4))
            XCTAssertTrue(app.buttons["outcomes.undo"].exists, "Failed Undo must remain retryable")
            XCTAssertFalse(action.exists, "A failed Undo must not pretend the state was restored")
            XCTAssertLessThanOrEqual(undoFailure.frame.maxY, app.buttons["outcomes.undo"].frame.minY,
                                     "The error must remain above the retry action without covering it")
            snapshot("action-undo-write-failure")
        }
        app.buttons["outcomes.undo"].click()
        XCTAssertTrue(action.waitForExistence(timeout: 5), "Retry should restore the action after storage recovers")
        XCTAssertFalse(UITestHarness.staticText(containing: "Could not undo", in: app).exists,
                       "A successful Undo should clear its previous error")
    }

    func testAgentApprovalDescribesEffectAndDenialAndStopReachTheController() throws {
        try launch(["LOKALBOT_AGENT_UI_TEST_READY": "1", "LOKALBOT_AGENT_UI_TEST_APPROVAL": "1"])
        UITestHarness.clickSidebar("sidebar.agent", in: app)
        let composer = app.textFields["agent.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 6))
        composer.click(); composer.typeText("Draft a meeting follow-up")
        app.buttons["agent.send"].click()
        let assistant = app.descendants(matching: .any)["agent.assistant"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 6),
                      "Agent assistant response did not render")
        let rendered = assistant.value as? String ?? ""
        XCTAssertTrue(rendered.contains("Agent result"), "Agent Markdown heading was not rendered")
        XCTAssertTrue(rendered.contains("• Parent"), "Agent Markdown list was not rendered")
        XCTAssertTrue(rendered.contains("let value = 1"), "Agent fenced code was not rendered")
        XCTAssertTrue(rendered.contains("Agent │ Ready"), "Agent Markdown table was not rendered")
        XCTAssertFalse(rendered.contains("## Agent result"), "Markdown heading syntax leaked into the answer")
        XCTAssertFalse(rendered.contains("| --- | --- |"), "Markdown table syntax leaked into the answer")
        let deny = app.buttons["agent.approve.deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 6))
        XCTAssertTrue(UITestHarness.staticText(containing: "Create or replace the file", in: app).exists)
        XCTAssertTrue(UITestHarness.staticText(containing: "reviewed-note.md", in: app).exists)
        snapshot("agent-write-approval")
        deny.click()
        XCTAssertTrue(UITestHarness.staticText(containing: "You denied this write request", in: app)
            .waitForExistence(timeout: 4))
        XCTAssertFalse(deny.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("reviewed-note.md").path))
        app.buttons["agent.stop"].click()
        XCTAssertTrue(UITestHarness.waitUntil { !self.app.buttons["agent.stop"].exists })
        let lines = try String(contentsOf: fixture.root.appendingPathComponent("agent-ui-rpc.jsonl"), encoding: .utf8)
        let commands = try lines.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertTrue(commands.contains { $0["type"] as? String == "extension_ui_response" && $0["confirmed"] as? Bool == false })
        XCTAssertEqual(commands.last?["type"] as? String, "abort")
        snapshot("agent-denied-and-stopped")
    }

    private func launch(_ environment: [String: String] = [:]) throws {
        app?.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: suite)
        let run = try UITestHarness.launch(storageRoot: fixture.root, suitePrefix: "Redesign", environment: environment)
        app = run.app; suite = run.defaultsSuiteName
    }
    private func withBlockedStateFile(_ file: URL, perform body: () throws -> Void) throws {
        let contents = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? contents.write(to: file, options: .atomic)
        }
        try body()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func auditWorkspaceAccessibility() throws {
        // Report every app issue. The hosted virtual Mac also exposes a
        // system-generated Touch Bar and its Emoji picker outside our window;
        // neither is an app-owned control or a usable hosted input surface.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "workspace-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .action]) { issue in
            guard let affected = issue.element, affected.exists else { return false }
            if affected.elementType == .touchBar { return true }
            let systemBar = self.app.descendants(matching: .touchBar).firstMatch
            guard affected.elementType == .popUpButton, affected.label == "emoji & symbols",
                  systemBar.exists else { return false }
            let systemPicker = systemBar.descendants(matching: .popUpButton)
                .matching(NSPredicate(format: "label == %@", "emoji & symbols")).firstMatch
            return systemPicker.exists && systemPicker.frame == affected.frame
        }
    }
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
