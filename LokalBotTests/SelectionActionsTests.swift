import XCTest
@testable import LokalBot

/// Records every prompt and answers with a fixed reply.
private final class RecordingEngine: TextEngine {
    var reply: String
    var error: Error?
    private(set) var systems: [String] = []
    private(set) var prompts: [String] = []

    init(reply: String, error: Error? = nil) {
        self.reply = reply
        self.error = error
    }

    var displayName: String { "Stub" }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        systems.append(system)
        prompts.append(prompt)
        if let error { throw error }
        return reply
    }
}

final class SelectionActionPromptTests: XCTestCase {
    func testRewriteSendsTheSelectionAsDelimitedDataWithoutMemory() {
        let prompt = SelectionActionPrompt.userPrompt(
            action: .fixGrammar, selection: "  teh meeting is tomorow  ", memory: .empty)
        XCTAssertTrue(prompt.hasPrefix("Task: Fix spelling, grammar, and punctuation."))
        XCTAssertTrue(prompt.contains("Selected text:\n<<<\nteh meeting is tomorow\n>>>"))
        XCTAssertFalse(prompt.contains("Work memory"), "rewrites never read memory")
        XCTAssertFalse(SelectionActionPrompt.systemPrompt(usesMemory: false).contains("Work memory excerpts"))
    }

    func testMemoryActionsCarryExcerptsOrSayNoneWereFound() {
        let memory = SelectionMemoryContext(
            excerpts: "Design review: the beta moves to Friday.",
            sources: [.init(id: UUID(), title: "Design review", date: nil)])
        let withMemory = SelectionActionPrompt.userPrompt(action: .reply, selection: "When is the beta?", memory: memory)
        XCTAssertTrue(withMemory.contains("Work memory:\n<<<\nDesign review: the beta moves to Friday.\n>>>"))
        XCTAssertTrue(SelectionActionPrompt.systemPrompt(usesMemory: true).contains("Never invent"))

        let without = SelectionActionPrompt.userPrompt(action: .reply, selection: "When is the beta?", memory: .empty)
        XCTAssertTrue(without.contains("nothing relevant was found"))
    }

    func testWritingWithoutASelectionAsksForNewText() {
        let action = SelectionAction.custom("a status update on the beta", usesMemory: true)
        let prompt = SelectionActionPrompt.userPrompt(action: action, selection: " ", memory: .empty)
        XCTAssertTrue(prompt.contains("Nothing is selected."))
        XCTAssertFalse(prompt.contains("Selected text:"))
        XCTAssertEqual(SelectionActionPrompt.memoryQuery(action: action, selection: ""),
                       "a status update on the beta")
    }

    func testLongSelectionsAreClippedForThePromptAndTheMemoryQuery() {
        let long = String(repeating: "word ", count: 5_000)
        XCTAssertEqual(SelectionActionPrompt.clippedSelection(long).count, SelectionActionPrompt.selectionCharacterLimit)
        let query = SelectionActionPrompt.memoryQuery(action: .reply, selection: "Hi\n\n  there  " + long)
        XCTAssertTrue(query.hasPrefix("Hi there word"), "whitespace collapses")
        XCTAssertEqual(query.count, SelectionActionPrompt.memoryQueryCharacterLimit)
    }

    func testOutputLosesFencesAndWrappingQuotesButKeepsQuotedSelections() {
        XCTAssertEqual(SelectionActionPrompt.normalizedOutput("```\nFixed text\n```", selection: "x"), "Fixed text")
        XCTAssertEqual(SelectionActionPrompt.normalizedOutput("“Fixed text”", selection: "x"), "Fixed text")
        XCTAssertEqual(SelectionActionPrompt.normalizedOutput("\"Quoted\"", selection: "\"quoted\""), "\"Quoted\"",
                       "a selection that was itself quoted keeps its quotes")
    }

    func testActionsFilterByTitleAndNeedASelection() {
        XCTAssertEqual(SelectionAction.matching("", hasSelection: true).map(\.id),
                       SelectionAction.builtIn.map(\.id))
        XCTAssertEqual(SelectionAction.matching("short", hasSelection: true).map(\.id), ["shorter"])
        XCTAssertEqual(SelectionAction.matching("memory", hasSelection: true).map(\.id), ["explain", "reply"])
        XCTAssertEqual(SelectionAction.matching("", hasSelection: false), [], "built-in actions rewrite a selection")
        XCTAssertTrue(SelectionAction.custom("x", usesMemory: false).worksWithoutSelection)
    }

    func testOnlyMemoryActionsReadMemory() {
        XCTAssertEqual(SelectionAction.builtIn.filter(\.usesMemory).map(\.id), ["explain", "reply"])
        XCTAssertEqual(SelectionAction.builtIn.filter { $0.result == .newText }.map(\.id),
                       ["summarize", "explain", "reply"])
    }
}

@MainActor
final class SelectionActionsControllerTests: XCTestCase {
    private var captured = SelectionCaptureResult(
        source: SelectionSource(processID: 4_242, bundleID: "com.example.notes", appName: "Notes"),
        text: "teh plan",
        target: DictationDeliveryTarget(processID: 4_242, bundleID: "com.example.notes", focusIdentityKey: "field"))
    private var engine = RecordingEngine(reply: "The plan")
    private var memoryQueries: [String] = []
    private var memory = SelectionMemoryContext.empty
    private var delivered: [String] = []
    private var deliveryOutcome = SelectionActionsController.DeliveryOutcome.inserted
    private var copied: [String] = []
    private var focusReturns: [pid_t] = []
    private var panelOpens = 0
    private var reports: [String] = []
    private var lokalBotFrontmost = false

    private func makeController() -> SelectionActionsController {
        SelectionActionsController(dependencies: .init(
            isLokalBotFrontmost: { [unowned self] in self.lokalBotFrontmost },
            capture: { [unowned self] in self.captured },
            makeEngine: { [unowned self] in self.engine },
            memory: { [unowned self] query in
                self.memoryQueries.append(query)
                return self.memory
            },
            deliver: { [unowned self] text, _ in
                self.delivered.append(text)
                return self.deliveryOutcome
            },
            copy: { [unowned self] text in self.copied.append(text) },
            returnFocus: { [unowned self] source in self.focusReturns.append(source.processID) },
            openPanel: { [unowned self] in self.panelOpens += 1 },
            report: { [unowned self] message in self.reports.append(message) }))
    }

    /// Waits up to about a second for `condition`.
    private func waitFor(_ controller: SelectionActionsController,
                         _ condition: @MainActor (SelectionActionsController) -> Bool) async {
        var attempts = 0
        while !condition(controller), attempts < 200 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testShortcutReadsTheSelectionBeforeOpeningThePanel() async {
        let controller = makeController()
        controller.invoke()
        XCTAssertEqual(controller.phase, .capturing)
        XCTAssertEqual(panelOpens, 0, "opening the panel first would move focus off the selection")
        await waitFor(controller) { $0.phase == .choosing }
        XCTAssertEqual(controller.capture, captured)
        XCTAssertEqual(panelOpens, 1)
    }

    func testShortcutFromLokalBotKeepsTheOpenPanel() async {
        let controller = makeController()
        controller.invoke()
        await waitFor(controller) { $0.phase == .choosing }
        lokalBotFrontmost = true
        controller.invoke()
        XCTAssertEqual(controller.phase, .choosing)
        XCTAssertEqual(controller.capture, captured, "the selection is not re-read from LokalBot's own panel")
        XCTAssertEqual(panelOpens, 2)
    }

    func testRewriteStreamsWithoutReadingMemory() async {
        let controller = makeController()
        controller.invoke()
        await waitFor(controller) { $0.phase == .choosing }
        controller.run(.fixGrammar)
        XCTAssertEqual(controller.phase, .generating)
        await waitFor(controller) { $0.phase == .finished }
        XCTAssertEqual(controller.output, "The plan")
        XCTAssertEqual(controller.modelName, "Stub")
        XCTAssertEqual(memoryQueries, [])
        XCTAssertTrue(engine.prompts.first?.contains("<<<\nteh plan\n>>>") == true)
    }

    func testMemoryActionsSearchWithTheSelectionAndListSources() async {
        let meeting = UUID()
        memory = SelectionMemoryContext(excerpts: "Beta moves to Friday.",
                                        sources: [.init(id: meeting, title: "Design review", date: nil)])
        let controller = makeController()
        controller.invoke()
        await waitFor(controller) { $0.phase == .choosing }
        controller.run(.reply)
        await waitFor(controller) { $0.phase == .finished }
        XCTAssertEqual(memoryQueries, ["teh plan"])
        XCTAssertEqual(controller.memorySources.map(\.id), [meeting])
        XCTAssertTrue(engine.prompts.first?.contains("Beta moves to Friday.") == true)
        XCTAssertTrue(engine.systems.first?.contains("Never invent") == true)
    }

    func testEngineFailureIsShownAndCanBeRetried() async {
        engine = RecordingEngine(reply: "Second try", error: TextEngineError.noModel)
        let controller = makeController()
        controller.invoke()
        await waitFor(controller) { $0.phase == .choosing }
        controller.run(.improve)
        await waitFor(controller) { controller in
            if case .failed = controller.phase { return true }
            return false
        }
        guard case .failed(let message) = controller.phase else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("No Think model"))

        engine.error = nil
        controller.retry()
        await waitFor(controller) { $0.phase == .finished }
        XCTAssertEqual(controller.output, "Second try")
    }

    func testCopyClosesAndReturnsFocusToTheSourceApp() async {
        let controller = makeController()
        controller.invoke()
        await waitFor(controller) { $0.phase == .choosing }
        controller.run(.shorter)
        await waitFor(controller) { $0.phase == .finished }
        controller.copyOutput()
        XCTAssertEqual(copied, ["The plan"])
        XCTAssertEqual(focusReturns, [4_242])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.capture, SelectionCaptureResult(), "the selection is forgotten")
    }

    func testFailedPasteBringsTheResultBackWithTheReason() async {
        deliveryOutcome = .copied("Focus moved to another field, so the result was copied to the clipboard instead.")
        let controller = makeController()
        controller.invoke()
        await waitFor(controller) { $0.phase == .choosing }
        controller.run(.professional)
        await waitFor(controller) { $0.phase == .finished }
        controller.insertOutput()
        XCTAssertEqual(controller.phase, .idle, "the panel closes while pasting")
        await waitFor(controller) { $0.phase == .finished }
        XCTAssertEqual(delivered, ["The plan"])
        XCTAssertEqual(controller.output, "The plan")
        XCTAssertEqual(controller.notice, deliveryOutcome.reason)
        XCTAssertEqual(panelOpens, 2)
    }

    func testReadOnlySelectionCannotBeReplaced() async {
        captured.target = nil
        let controller = makeController()
        controller.invoke()
        await waitFor(controller) { $0.phase == .choosing }
        controller.run(.summarize)
        await waitFor(controller) { $0.phase == .finished }
        controller.insertOutput()
        XCTAssertEqual(controller.phase, .finished)
        XCTAssertEqual(delivered, [])
    }

    func testBlockedCaptureRunsNothing() async {
        captured.issue = .excludedApp
        captured.text = ""
        let controller = makeController()
        controller.invoke()
        await waitFor(controller) { $0.phase == .choosing }
        controller.run(.custom("draft a note", usesMemory: true))
        XCTAssertEqual(controller.phase, .choosing)
        XCTAssertEqual(engine.prompts, [])
    }

    func testClosingThePanelStopsGeneration() async {
        let controller = makeController()
        controller.invoke()
        await waitFor(controller) { $0.phase == .choosing }
        controller.run(.fixGrammar)
        controller.panelClosed()
        XCTAssertEqual(controller.phase, .idle)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.phase, .idle, "a cancelled request never writes a result")
        XCTAssertEqual(controller.output, "")
    }
}

private extension SelectionActionsController.DeliveryOutcome {
    var reason: String? {
        if case .copied(let reason) = self { return reason }
        return nil
    }
}
