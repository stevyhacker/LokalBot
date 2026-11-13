import CoreGraphics
import XCTest
@testable import LokalBot

/// Hand off reads the focused window once, writes a brief, and packages
/// both for the agent the person picks.
@MainActor
final class WindowHandoffCaptureTests: XCTestCase {
    private let source = SelectionSource(processID: 42, bundleID: "com.example.editor", appName: "Editor")
    private let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
    private var documentReads = 0
    private var recognized = 0

    private func snapshot(text: String = String(repeating: "Plan the beta launch. ", count: 20),
                          focusedSecureField: Bool? = false, url: String? = nil,
                          selection: String? = nil) -> ScreenAccessibilitySnapshot {
        ScreenAccessibilitySnapshot(
            text: text, sourceURL: url, documentName: nil, focusedSecureField: focusedSecureField,
            windowTitle: "Launch plan", windowFrame: frame, hasWebContent: url != nil,
            selectedText: selection)
    }

    private func dependencies(_ document: ScreenAccessibilitySnapshot?, trusted: Bool = true,
                              screenCapture: Bool = true, ocr: String = "") -> WindowHandoffCapturer.Dependencies {
        let source = source, frame = frame
        return .init(
            source: { source },
            isTrusted: { trusted },
            readDocument: { [weak self] _ in
                self?.documentReads += 1
                return document
            },
            readVisible: { _ in ScreenAccessibilityCaptureResult(snapshot: document, timedOut: false) },
            frontmostProcessID: { source.processID },
            screenCaptureGranted: { screenCapture },
            windows: {
                [ScreenshotCaptureLayout.Window(id: 7, processID: source.processID, appName: source.appName,
                                                title: "Launch plan", frame: frame)]
            },
            captureImage: { _ in try XCTUnwrap(Self.image()) },
            recognizeText: { [weak self] _ in
                self?.recognized += 1
                return ocr
            })
    }

    private static func image() -> CGImage? {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context?.makeImage()
    }

    func testReadsTheWholeWindowWithItsSelectionAndScreenshot() async throws {
        let capture = await WindowHandoffCapturer.capture(
            excludedApps: [], excludedDomains: [],
            dependencies: dependencies(snapshot(selection: "  beta launch  ")))

        XCTAssertNil(capture.issue)
        XCTAssertTrue(capture.hasContent)
        XCTAssertEqual(capture.source, source)
        XCTAssertEqual(capture.windowTitle, "Launch plan")
        XCTAssertTrue(capture.text.hasPrefix("Plan the beta launch."))
        XCTAssertEqual(capture.selection, "  beta launch  ")
        XCTAssertFalse(capture.textFromScreenshot)
        XCTAssertEqual(recognized, 0, "plenty of window text needs no OCR")
        let png = try XCTUnwrap(capture.screenshot)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testExcludedAppsAreNeverRead() async {
        let capture = await WindowHandoffCapturer.capture(
            excludedApps: ["editor"], excludedDomains: [], dependencies: dependencies(snapshot()))

        XCTAssertEqual(capture.issue, .excludedApp)
        XCTAssertEqual(documentReads, 0)
        XCTAssertFalse(capture.hasContent)
    }

    func testMissingAccessibilityAccessAndUnreadableWindowsSaySo() async {
        let untrusted = await WindowHandoffCapturer.capture(
            excludedApps: [], excludedDomains: [], dependencies: dependencies(snapshot(), trusted: false))
        XCTAssertEqual(untrusted.issue, .accessibilityNeeded)
        XCTAssertEqual(documentReads, 0)

        let unreadable = await WindowHandoffCapturer.capture(
            excludedApps: [], excludedDomains: [], dependencies: dependencies(nil))
        XCTAssertEqual(unreadable.issue, .unreadable)
    }

    func testAPasswordFieldKeepsEverythingOut() async {
        let capture = await WindowHandoffCapturer.capture(
            excludedApps: [], excludedDomains: [],
            dependencies: dependencies(snapshot(focusedSecureField: true)))

        XCTAssertEqual(capture.issue, .secureField)
        XCTAssertEqual(capture.text, "")
        XCTAssertNil(capture.screenshot)
    }

    func testExcludedSitesAreNotRead() async {
        let capture = await WindowHandoffCapturer.capture(
            excludedApps: [], excludedDomains: ["bank.example.com"],
            dependencies: dependencies(snapshot(url: "https://bank.example.com/accounts")))

        XCTAssertEqual(capture.issue, .excludedSite)
        XCTAssertEqual(capture.text, "")
    }

    func testRedactionDropsTheScreenshot() async {
        let text = String(repeating: "Billing notes. ", count: 20) + "Card 4111 1111 1111 1111."
        let capture = await WindowHandoffCapturer.capture(
            excludedApps: [], excludedDomains: [], dependencies: dependencies(snapshot(text: text)))

        XCTAssertNil(capture.issue)
        XCTAssertFalse(capture.text.contains("4111 1111 1111 1111"))
        XCTAssertEqual(capture.redactions, 1)
        XCTAssertNil(capture.screenshot, "the pixels would still show what was redacted")
    }

    func testThinWindowTextIsReadFromTheScreenshot() async {
        let capture = await WindowHandoffCapturer.capture(
            excludedApps: [], excludedDomains: [],
            dependencies: dependencies(snapshot(text: "Canvas"), ocr: "Sprint board: ship the export fix by Friday"))

        XCTAssertEqual(recognized, 1)
        XCTAssertTrue(capture.textFromScreenshot)
        XCTAssertEqual(capture.text, "Sprint board: ship the export fix by Friday")
        XCTAssertNotNil(capture.screenshot)
    }

    func testWithoutScreenRecordingOnlyTheTextIsRead() async {
        let capture = await WindowHandoffCapturer.capture(
            excludedApps: [], excludedDomains: [],
            dependencies: dependencies(snapshot(text: "Canvas"), screenCapture: false, ocr: "unused"))

        XCTAssertEqual(capture.text, "Canvas")
        XCTAssertNil(capture.screenshot)
        XCTAssertEqual(recognized, 0)
    }

    func testDocumentTextKeepsTextRolesWhetherOrNotTheyAreScrolledIntoView() {
        XCTAssertEqual(ScreenDocumentTextPolicy.text(role: "AXStaticText", hidden: false, value: "Below the fold"),
                       ["Below the fold"])
        XCTAssertEqual(ScreenDocumentTextPolicy.text(role: "AXTextArea", hidden: false, value: "Draft"), ["Draft"])
        XCTAssertEqual(ScreenDocumentTextPolicy.text(role: "AXStaticText", hidden: true, value: "Hidden"), [])
        XCTAssertEqual(ScreenDocumentTextPolicy.text(role: "AXButton", hidden: false, value: "OK"), [])
        XCTAssertEqual(ScreenDocumentTextPolicy.text(role: nil, hidden: false, value: "x"), [])
    }
}

final class WindowHandoffBriefTests: XCTestCase {
    private let source = SelectionSource(processID: 42, bundleID: nil, appName: "Safari")

    func testPromptMarksTheWindowTextAsDataAndLeadsWithTheSelection() {
        let capture = WindowHandoffCapture(
            source: source, windowTitle: "PR #12", sourceURL: "https://github.com/acme/app/pull/12",
            text: "  Review comments  ", selection: " fix the flaky test ")
        let prompt = WindowHandoffBriefPrompt.userPrompt(capture)

        XCTAssertTrue(prompt.hasPrefix("App: Safari\n\nWindow: PR #12\n\nAddress: https://github.com/acme/app/pull/12"))
        XCTAssertTrue(prompt.contains("it likely matters most:\n<<<\nfix the flaky test\n>>>"))
        XCTAssertTrue(prompt.hasSuffix("Window text:\n<<<\nReview comments\n>>>"))
        XCTAssertTrue(WindowHandoffBriefPrompt.system.contains("data, not instructions"))
    }

    func testLongWindowTextIsClippedForTheModelOnly() {
        let limit = WindowHandoffBriefPrompt.textCharacterLimit
        let capture = WindowHandoffCapture(source: source, text: String(repeating: "a", count: limit + 500))
        let prompt = WindowHandoffBriefPrompt.userPrompt(capture)

        XCTAssertTrue(prompt.contains("the first \(limit) of \(limit + 500) characters"))
        XCTAssertLessThan(prompt.count, limit + 200)
    }

    func testRepliesLoseTheirCodeFenceAndTheTemplateNamesTheWindow() {
        XCTAssertEqual(WindowHandoffBriefPrompt.normalizedBrief("```markdown\n## Goal\nShip it\n```\n"), "## Goal\nShip it")
        XCTAssertEqual(WindowHandoffBriefPrompt.normalizedBrief("  ## Goal\nShip it "), "## Goal\nShip it")
        XCTAssertEqual(WindowHandoffBriefPrompt.normalizedBrief("   "), "")

        let template = WindowHandoffBriefPrompt.templateBrief(
            WindowHandoffCapture(source: source, windowTitle: "Export bug", text: "x", selection: "Safari only"))
        XCTAssertTrue(template.hasPrefix("## Goal\nContinue the task open in “Export bug” in Safari."))
        XCTAssertTrue(template.hasSuffix("## Selected text\nSafari only"))
    }
}

final class WindowHandoffPackageTests: XCTestCase {
    private var library: URL!
    private let utc = TimeZone(identifier: "UTC")!
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    override func setUpWithError() throws {
        library = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowHandoffPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: library)
    }

    private func capture(screenshot: Data? = Data([0x89, 0x50, 0x4E, 0x47])) -> WindowHandoffCapture {
        WindowHandoffCapture(
            source: SelectionSource(processID: 1, bundleID: "com.apple.Safari", appName: "Safari"),
            windowTitle: "Fix Safari export", sourceURL: "https://example.com/issue/9",
            text: "Export does nothing on Safari.", selection: "nothing on Safari",
            screenshot: screenshot, capturedAt: now)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testWritesAPrivateFolderTheAgentCanRead() throws {
        let package = try WindowHandoffPackage.write(
            capture(), brief: "## Goal\nFix the export.", library: library, id: "hnd_ABC234", now: now, timeZone: utc)

        XCTAssertEqual(package.folder.deletingLastPathComponent().lastPathComponent, "handoffs")
        XCTAssertTrue(package.folder.lastPathComponent.hasSuffix("-fix-safari-export"))
        XCTAssertEqual(package.title, "Fix Safari export")
        XCTAssertTrue(package.hasScreenshot)
        for directory in [WindowHandoffPackage.root(library: library), package.folder] {
            XCTAssertEqual(try permissions(directory), 0o700)
        }
        for file in [package.briefURL, package.manifestURL, package.pageURL, package.screenshotURL] {
            XCTAssertEqual(try permissions(file), 0o600, file.lastPathComponent)
        }

        let brief = try String(contentsOf: package.briefURL, encoding: .utf8)
        XCTAssertTrue(brief.hasPrefix("# Fix Safari export\n\n## Goal\nFix the export.\n\n## Sources\n- App: Safari"))
        XCTAssertTrue(brief.contains("(handoff hnd_ABC234)"))
        XCTAssertTrue(brief.contains("- Screenshot: screens/01.png"))
        let page = try String(contentsOf: package.pageURL, encoding: .utf8)
        XCTAssertTrue(page.contains("## Selected\n\nnothing on Safari\n\n## Window text\n\nExport does nothing on Safari."))

        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: package.manifestURL)) as? [String: Any])
        XCTAssertEqual(manifest["format"] as? String, "lokalbot.handoff")
        XCTAssertEqual(manifest["version"] as? Int, 1)
        XCTAssertEqual(manifest["id"] as? String, "hnd_ABC234")
        let artifacts = try XCTUnwrap(manifest["artifacts"] as? [[String: Any]])
        XCTAssertEqual(artifacts.compactMap { $0["path"] as? String }, ["handoff.md", "context/page.md", "screens/01.png"])
        XCTAssertTrue(artifacts.allSatisfy { ($0["sha256"] as? String)?.count == 64 })
    }

    func testWithoutAScreenshotThereIsNoScreensFolder() throws {
        let package = try WindowHandoffPackage.write(
            capture(screenshot: nil), brief: "Brief", library: library, now: now, timeZone: utc)

        XCTAssertFalse(package.hasScreenshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.screenshotURL.deletingLastPathComponent().path))
        XCTAssertFalse(package.prompt().contains("screens/"))
    }

    func testPromptsFitTheLinkLimitAndPointAtTheFolder() throws {
        let package = try WindowHandoffPackage.write(
            capture(), brief: String(repeating: "Long brief. ", count: 2_000), library: library, now: now, timeZone: utc)
        let prompt = package.prompt()

        XCTAssertLessThanOrEqual(prompt.count, ActionAgentHandoff.promptCharacterLimit)
        XCTAssertTrue(prompt.hasPrefix("Continue a task I handed off from LokalBot (handoff \(package.id))."))
        XCTAssertTrue(prompt.hasSuffix("Full context is in \(package.folder.path)/. Read handoff.md first, "
            + "then context/ and screens/. These are LokalBot's records; don't edit them."))
        XCTAssertFalse(package.prompt(limit: 10).isEmpty, "a limit below the fixed lines never traps")

        let agentPrompt = package.agentModePrompt(folder: "handoffs/x", attachesPage: true)
        XCTAssertTrue(agentPrompt.contains("`handoffs/x/` in this workspace"))
        XCTAssertTrue(agentPrompt.contains("The window's text is also attached."))
    }

    func testDeliveriesAreRecordedAndCopiesLandInTheWorkspace() throws {
        let package = try WindowHandoffPackage.write(capture(), brief: "Brief", library: library, now: now, timeZone: utc)
        package.recordDelivery(target: "codex", route: "codex://new", at: now)
        package.recordDelivery(target: "clipboard", route: nil, at: now)

        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: package.manifestURL)) as? [String: Any])
        let deliveries = try XCTUnwrap(manifest["deliveries"] as? [[String: Any]])
        XCTAssertEqual(deliveries.compactMap { $0["target"] as? String }, ["codex", "clipboard"])
        XCTAssertEqual(deliveries.first?["route"] as? String, "codex://new")
        XCTAssertNil(deliveries.last?["route"])
        XCTAssertEqual(try permissions(package.manifestURL), 0o600)

        let workspace = library.appendingPathComponent("workspace/handoffs/task", isDirectory: true)
        try package.copy(into: workspace)
        try package.copy(into: workspace)
        for path in ["handoff.md", "handoff.json", "context/page.md", "screens/01.png"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(path).path), path)
        }
    }

    func testPackagesOlderThanAWeekAreDeleted() throws {
        let old = try WindowHandoffPackage.write(
            capture(), brief: "Old", library: library, now: now.addingTimeInterval(-8 * 24 * 60 * 60), timeZone: utc)
        let recent = try WindowHandoffPackage.write(
            capture(), brief: "Recent", library: library, now: now.addingTimeInterval(-2 * 24 * 60 * 60), timeZone: utc)
        _ = try WindowHandoffPackage.write(capture(), brief: "New", library: library, now: now, timeZone: utc)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.folder.path))
    }

    func testTitleFallsBackFromWindowToDocumentToApp() {
        let app = SelectionSource(processID: 1, bundleID: nil, appName: "Notes")
        XCTAssertEqual(WindowHandoffPackage.title(for: WindowHandoffCapture(source: app, windowTitle: " ")), "Notes")
        XCTAssertEqual(WindowHandoffPackage.title(for: WindowHandoffCapture(
            source: app, documentName: "Plan.txt")), "Plan.txt")
        XCTAssertEqual(WindowHandoffPackage.title(for: WindowHandoffCapture()), "Handed-off window")
        XCTAssertTrue(WindowHandoffPackage.makeID().hasPrefix("hnd_"))
        XCTAssertEqual(WindowHandoffPackage.makeID().count, 10)
    }
}

/// Answers with partial and final text, or waits until cancelled.
private final class HandoffBriefEngine: TextEngine {
    var reply: String
    var error: Error?
    var waitsForCancellation = false
    private(set) var prompts: [String] = []

    init(reply: String = "## Goal\nShip the fix", error: Error? = nil) {
        self.reply = reply
        self.error = error
    }

    var displayName: String { "Stub" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        reply
    }

    func generateStreaming(system: String, prompt: String, context: [String],
                           options: TextGenerationOptions,
                           onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        prompts.append(prompt)
        if waitsForCancellation { try await Task.sleep(for: .seconds(30)) }
        if let error { throw error }
        await onPartial(String(reply.prefix(4)))
        return reply
    }
}

@MainActor
final class WindowHandoffControllerTests: XCTestCase {
    private let source = SelectionSource(processID: 42, bundleID: nil, appName: "Editor")
    private var engine = HandoffBriefEngine()
    private var captured: WindowHandoffCapture!
    private var lokalBotFrontmost = false
    private var targets = WindowHandoffTarget.allCases
    private var deliveryFailure: String?
    private var written: [(WindowHandoffCapture, String)] = []
    private var delivered: [WindowHandoffTarget] = []
    private var focusReturns = 0
    private var panelOpens = 0
    private var panelCloses = 0

    override func setUp() {
        super.setUp()
        captured = WindowHandoffCapture(source: source, windowTitle: "Plan", text: "Ship the export fix.")
    }

    private func makeController() -> WindowHandoffController {
        WindowHandoffController(dependencies: .init(
            isLokalBotFrontmost: { [unowned self] in self.lokalBotFrontmost },
            capture: { [unowned self] in self.captured },
            makeEngine: { [unowned self] in self.engine },
            targets: { [unowned self] in self.targets },
            writePackage: { [unowned self] capture, brief in
                self.written.append((capture, brief))
                return WindowHandoffPackage(
                    id: "hnd_TEST22", title: "Plan", folder: URL(fileURLWithPath: "/tmp/handoffs/plan"),
                    brief: brief, pageCharacters: capture.text.count, hasScreenshot: false)
            },
            deliver: { [unowned self] _, target in
                self.delivered.append(target)
                return self.deliveryFailure
            },
            returnFocus: { [unowned self] _ in self.focusReturns += 1 },
            openPanel: { [unowned self] in self.panelOpens += 1 },
            closePanel: { [unowned self] in self.panelCloses += 1 }))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testReadsTheWindowThenOpensTheReviewWithTheModelsBrief() async {
        let controller = makeController()
        controller.invoke()
        XCTAssertEqual(controller.phase, .capturing)
        XCTAssertEqual(panelOpens, 0, "the panel would take focus from the window being read")

        await waitUntil { controller.phase == .ready }
        XCTAssertEqual(panelOpens, 1)
        XCTAssertEqual(controller.brief, "## Goal\nShip the fix")
        XCTAssertEqual(controller.modelName, "Stub")
        XCTAssertFalse(controller.briefIsTemplate)
        XCTAssertTrue(controller.canHandOff)
        XCTAssertTrue(engine.prompts.first?.contains("Ship the export fix.") == true)
    }

    func testHandOffWritesThePackageDeliversItAndCloses() async {
        let controller = makeController()
        controller.invoke()
        await waitUntil { controller.phase == .ready }
        controller.brief = "## Goal\nEdited by hand"
        controller.target = .codex
        controller.handOff()

        await waitUntil { controller.phase == .idle }
        XCTAssertEqual(written.first?.1, "## Goal\nEdited by hand")
        XCTAssertEqual(delivered, [.codex])
        XCTAssertEqual(panelCloses, 1)
        XCTAssertEqual(focusReturns, 0, "the agent's app takes focus")
        XCTAssertEqual(controller.brief, "")
    }

    func testCopyReturnsToTheSourceApp() async {
        let controller = makeController()
        controller.invoke()
        await waitUntil { controller.phase == .ready }
        controller.target = .copy
        controller.handOff()

        await waitUntil { controller.phase == .idle }
        XCTAssertEqual(delivered, [.copy])
        XCTAssertEqual(focusReturns, 1)
    }

    func testAFailedDeliveryKeepsThePanelOpenWithTheReason() async {
        deliveryFailure = "Codex isn't installed on this Mac."
        let controller = makeController()
        controller.invoke()
        await waitUntil { controller.phase == .ready }
        controller.target = .codex
        controller.handOff()

        await waitUntil { controller.notice != nil }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.notice, "Codex isn't installed on this Mac.")
        XCTAssertEqual(panelCloses, 0)
        XCTAssertTrue(controller.canHandOff)
    }

    func testAModelFailureFallsBackToTheTemplate() async {
        engine = HandoffBriefEngine(error: URLError(.cannotConnectToHost))
        let controller = makeController()
        controller.invoke()

        await waitUntil { controller.phase == .ready }
        XCTAssertTrue(controller.briefIsTemplate)
        XCTAssertTrue(controller.brief.hasPrefix("## Goal\nContinue the task open in “Plan” in Editor."))
        XCTAssertNotNil(controller.notice)
        XCTAssertTrue(controller.canHandOff)
    }

    func testSkippingUsesTheTemplateAndIgnoresTheModel() async {
        engine.waitsForCancellation = true
        let controller = makeController()
        controller.invoke()
        await waitUntil { controller.phase == .writing }

        controller.skipBrief()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertTrue(controller.briefIsTemplate)
        XCTAssertNil(controller.notice)
        let template = controller.brief
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.brief, template)
    }

    func testPressingTheShortcutInLokalBotAsksForTheWindow() {
        lokalBotFrontmost = true
        let controller = makeController()
        controller.invoke()

        XCTAssertTrue(controller.needsSourceWindow)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(panelOpens, 1)
        XCTAssertFalse(controller.canHandOff)

        controller.panelClosed()
        XCTAssertFalse(controller.needsSourceWindow)
    }

    func testABlockedWindowOpensTheReviewWithoutAskingTheModel() async {
        captured = WindowHandoffCapture(source: source, issue: .secureField)
        let controller = makeController()
        controller.invoke()

        await waitUntil { controller.phase == .ready }
        XCTAssertEqual(controller.capture.issue, .secureField)
        XCTAssertTrue(engine.prompts.isEmpty)
        XCTAssertFalse(controller.canHandOff)
        controller.handOff()
        XCTAssertTrue(written.isEmpty)
    }

    func testAMissingTargetFallsBackToTheFirstAvailable() async {
        targets = [.agentMode, .copy]
        let controller = makeController()
        controller.target = .claudeCode
        controller.invoke()

        await waitUntil { controller.phase == .ready }
        XCTAssertEqual(controller.targets, [.agentMode, .copy])
        XCTAssertEqual(controller.target, .agentMode)
    }

    func testCancelReturnsToTheSourceApp() async {
        let controller = makeController()
        controller.invoke()
        await waitUntil { controller.phase == .ready }
        controller.dismiss()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(panelCloses, 1)
        XCTAssertEqual(focusReturns, 1)
        XCTAssertTrue(written.isEmpty)
    }
}
