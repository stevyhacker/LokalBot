import XCTest
@testable import LokalBot

// MARK: - Scripted engine

/// Records every request and returns (or throws) a canned result, so the
/// coordinator's engine-facing paths run without a model or server.
@MainActor
private final class ScriptedCotypingEngine: CotypingCompleting {
    var result: Result<String, Error> = .success("")
    private(set) var requests: [CotypingRequest] = []
    var beforeReturning: (() -> Void)?

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        requests.append(request)
        beforeReturning?()
        return CotypingNormalizationResult(text: try result.get(), suppression: nil)
    }
}

private struct EngineBoom: Error {}

private actor DiscardingCotypingStatsPersistence: CotypingStatsPersisting {
    func persist(_ stats: CotypingStats) {}
    func remove() {}
}

private final class CotypingSettingsBox {
    var value: AppSettings

    init(_ value: AppSettings) {
        self.value = value
    }
}

// MARK: - Coordinator

/// Most of the coordinator needs live AX + event taps, so these tests pin the
/// paths that run before any permission check: the settings gate in
/// `applySettings()` (which must bail out without touching AX) and the
/// permission-free `previewSuggestion` pipeline the in-app playground uses.
@MainActor
final class CotypingCoordinatorTests: XCTestCase {
    private var tempDir: URL!
    private var engine: ScriptedCotypingEngine!
    private var settings = AppSettings()
    /// Counters for this test only: never the installed app's saved ones.
    private var stats: CotypingStatsStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-cotyping-coordinator-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        engine = ScriptedCotypingEngine()
        settings = AppSettings()
        let suite = try XCTUnwrap(UserDefaults(suiteName: "cotyping-coordinator-stats-\(UUID().uuidString)"))
        stats = CotypingStatsStore(defaults: suite, persistence: DiscardingCotypingStatsPersistence())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeCoordinator() -> CotypingCoordinator {
        CotypingCoordinator(
            engine: engine,
            settingsProvider: { [settings] in settings },
            learningStore: CotypingLearningStore(storageRoot: tempDir, initialSnapshot: .init()),
            selfBundleID: "me.dotenv.LokalBot.tests",
            stats: stats)
    }

    private func makeCoordinator(
        settingsBox: CotypingSettingsBox,
        memoryProvider: @escaping (CotypingField, AppSettings) async -> CotypingMemoryContextProvider.Snapshot = { _, _ in .empty }
    ) -> CotypingCoordinator {
        CotypingCoordinator(
            engine: engine,
            settingsProvider: { settingsBox.value },
            learningStore: CotypingLearningStore(storageRoot: tempDir, initialSnapshot: .init()),
            memoryContextProvider: memoryProvider,
            selfBundleID: "me.dotenv.LokalBot.tests",
            stats: stats)
    }

    func testChangedVisibleContextInvalidatesPendingAndCachedSuggestion() throws {
        let coordinator = makeCoordinator()
        coordinator.isRunning = true
        let snapshot = try XCTUnwrap(CotypingVisibleContextReplay(CotypingVisibleContextTests.fixture()).capture(enabled: true))
        coordinator.activeVisibleContext = snapshot
        coordinator.lastSuggestion = "Thursday"
        coordinator.state = .generating
        let work = coordinator.generation
        coordinator.handleFocusChange(.none)
        XCTAssertGreaterThan(coordinator.generation, work)
        XCTAssertNil(coordinator.activeVisibleContext)
        XCTAssertNil(coordinator.lastSuggestion)
        XCTAssertNil(coordinator.session)
    }

    func testVisibleContextAcceptanceDoesNotEnterLearnedExamples() throws {
        let coordinator = makeCoordinator()
        let snapshot = try XCTUnwrap(CotypingVisibleContextReplay(CotypingVisibleContextTests.fixture()).capture(enabled: true))
        coordinator.activeVisibleContext = snapshot
        let field = CotypingField(appName: "Mail", processID: 123, role: "AXTextArea",
                                  precedingText: "I'll send it by ", trailingText: "", selectionLength: 0,
                                  caretRect: .zero, isSecure: false, caretIsExact: true)
        coordinator.recordAcceptedText("Thursday", field: field, settings: settings)
        XCTAssertNil(coordinator.acceptedSuggestionBatch.complete()?.learningRecord)
    }

    func testSharedCaptureExclusionAndVisibleConsentChangesInvalidateLifecycle() {
        let original = AppSettings()
        var changed = original
        changed.cotypingUseVisibleContext.toggle()
        XCTAssertTrue(AppState.cotypingLifecycleChanged(from: original, to: changed))
        changed = original
        changed.excludedApps += ", Mail"
        XCTAssertTrue(AppState.cotypingLifecycleChanged(from: original, to: changed))
        changed = original
        changed.excludedScreenDomains = "private.example"
        XCTAssertTrue(AppState.cotypingLifecycleChanged(from: original, to: changed))
    }

    func testApplySettingsWithCotypingOffDisablesWithoutRunning() {
        settings.cotypingEnabled = false
        let coordinator = makeCoordinator()

        coordinator.applySettings()

        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(coordinator.state, .disabled("Cotyping is off."))
    }

    func testStopWithoutReasonReturnsToIdle() {
        settings.cotypingEnabled = false
        let coordinator = makeCoordinator()
        coordinator.applySettings()

        coordinator.stop()

        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testExclusionChangesRefreshCachedAppReadPolicy() {
        defer { CotypingAXHelper.configureAppReadPolicy(CotypingAppReadPolicy()) }
        settings.cotypingEnabled = true
        let box = CotypingSettingsBox(settings)
        let coordinator = makeCoordinator(settingsBox: box)
        coordinator.applySettings()

        box.value.cotypingExcludedApps = "Mail"
        coordinator.applySettings()

        let expected = CotypingAppReadPolicy(
            enabled: true,
            excludedApps: ["Mail"],
            selfBundleID: "me.dotenv.LokalBot.tests")
        XCTAssertFalse(
            CotypingAXHelper.configureAppReadPolicy(expected),
            "applySettings must install the updated exclusion policy before the next AX read")
    }

    func testAppStateReconcilesCotypingWhenExclusionListsChange() {
        var original = AppSettings()
        original.cotypingEnabled = true

        var changed = original
        changed.cotypingExcludedApps = "Mail"
        XCTAssertTrue(AppState.cotypingLifecycleChanged(from: original, to: changed))

        changed = original
        changed.cotypingExcludedDomains = "bank.example"
        XCTAssertTrue(AppState.cotypingLifecycleChanged(from: original, to: changed))
    }

    func testPreviewSuggestionRunsThePipelineAgainstTheEngine() async throws {
        engine.result = .success("ld, how are you?")

        let text = try await makeCoordinator()
            .previewSuggestion(precedingText: "Hello wor", trailingText: "ld!")

        XCTAssertEqual(text, "ld, how are you?")
        XCTAssertEqual(engine.requests.count, 1)
        let request = try XCTUnwrap(engine.requests.first)
        XCTAssertTrue(request.prefixText.hasSuffix("Hello wor"),
                      "the caret prefix must reach the engine")
        XCTAssertTrue(request.prompt.contains("Hello wor"))
        XCTAssertEqual(request.trailingText, "ld!")
        XCTAssertTrue(request.forceWordContinuation,
                      "word characters on both sides of the caret must force word continuation")
    }

    func testPreviewSuggestionWithBlankPrefixSkipsTheEngine() async throws {
        let text = try await makeCoordinator()
            .previewSuggestion(precedingText: "   \n  ")

        XCTAssertEqual(text, "")
        XCTAssertTrue(engine.requests.isEmpty,
                      "a blank-before-caret field must never hit the model")
    }

    func testSetupCheckUsesSampleTextWithoutPersonalization() async throws {
        settings.cotypingUserName = "PRIVATE TEST NAME"
        settings.cotypingStyleNote = "PRIVATE STYLE NOTE"
        settings.cotypingExtendedContext = "PRIVATE VOCABULARY"
        let coordinator = makeCoordinator()

        _ = try await coordinator.previewSuggestion(precedingText: "The local model setup is", sampleOnly: true)
        let sample = try XCTUnwrap(engine.requests.last)
        XCTAssertTrue(sample.prompt.contains("The local model setup is"))
        XCTAssertFalse(sample.prompt.contains("PRIVATE TEST NAME"))
        XCTAssertFalse(sample.prompt.contains("PRIVATE STYLE NOTE"))
        XCTAssertFalse(sample.prompt.contains("PRIVATE VOCABULARY"))

        _ = try await coordinator.previewSuggestion(precedingText: "The local model setup is")
        let personalized = try XCTUnwrap(engine.requests.last)
        XCTAssertTrue(personalized.prompt.contains("PRIVATE TEST NAME"))
        XCTAssertTrue(personalized.prompt.contains("PRIVATE VOCABULARY"))
    }

    func testPreviewSuggestionPropagatesEngineFailure() async {
        engine.result = .failure(EngineBoom())

        do {
            _ = try await makeCoordinator().previewSuggestion(precedingText: "Hello wor")
            XCTFail("an engine failure must surface to the playground caller")
        } catch is EngineBoom {
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    private func memorySnapshot() -> CotypingMemoryContextProvider.Snapshot {
        .init(selection: .init(items: [
            .init(id: "atlas", title: "Atlas", text: "Atlas owner is Priya.",
                  updatedAt: Date(), requiresMeetings: true),
        ]), policy: .init(meetings: true, screenDerived: false))
    }

    func testMemoryPreviewIsOptInAndSampleNeverRetrieves() async throws {
        let box = CotypingSettingsBox(settings)
        let snapshot = memorySnapshot()
        var calls = 0
        let coordinator = makeCoordinator(settingsBox: box) { _, _ in
            calls += 1
            return snapshot
        }
        _ = try await coordinator.previewSuggestion(precedingText: "Atlas owner is ")
        XCTAssertEqual(calls, 0)
        box.value.cotypingUseMeetingMemory = true
        _ = try await coordinator.previewSuggestion(precedingText: "Atlas owner is ", sampleOnly: true)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(try XCTUnwrap(engine.requests.last).prompt.contains("Priya"))
        _ = try await coordinator.previewSuggestion(precedingText: "Atlas owner is ")
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(try XCTUnwrap(engine.requests.last).prompt.contains("Priya"))
        XCTAssertEqual(coordinator.memoryContextSources, ["Atlas"])
    }

    func testMemoryPermissionRevokedDuringInferenceDropsPreview() async throws {
        settings.cotypingUseMeetingMemory = true
        let box = CotypingSettingsBox(settings)
        let snapshot = memorySnapshot()
        let coordinator = makeCoordinator(settingsBox: box) { _, _ in snapshot }
        engine.result = .success("Priya")
        engine.beforeReturning = { box.value.cotypingUseMeetingMemory = false }
        let text = try await coordinator.previewSuggestion(precedingText: "Atlas owner is ")
        XCTAssertEqual(text, "")
        XCTAssertTrue(coordinator.memoryContextSources.isEmpty)
    }

    func testMemorySourceMutationDuringInferenceDropsPreview() async throws {
        settings.cotypingUseMeetingMemory = true
        let box = CotypingSettingsBox(settings)
        let snapshot = memorySnapshot()
        let coordinator = makeCoordinator(settingsBox: box) { _, _ in snapshot }
        engine.result = .success("Priya")
        engine.beforeReturning = { coordinator.invalidateMemoryContext() }
        let text = try await coordinator.previewSuggestion(precedingText: "Atlas owner is ")
        XCTAssertEqual(text, "")
    }

    func testMemoryInvalidationDropsCachedTextAndFencesPendingGeneration() {
        settings.cotypingUseMeetingMemory = true
        let coordinator = makeCoordinator()
        coordinator.activeMemoryContext = memorySnapshot()
        coordinator.memoryContextSources = ["Atlas"]
        coordinator.lastSuggestion = "Priya"
        coordinator.suggestionAnchorCache.record(identityKey: "field", requestFingerprint: "request",
                                                   precedingText: "Atlas owner is ", fullText: "Priya")
        let generation = coordinator.generation
        coordinator.invalidateMemoryContext()
        XCTAssertGreaterThan(coordinator.generation, generation)
        XCTAssertNil(coordinator.lastSuggestion)
        XCTAssertTrue(coordinator.memoryContextSources.isEmpty)
        XCTAssertTrue(coordinator.activeMemoryContext.selection.items.isEmpty)
        XCTAssertNil(coordinator.suggestionAnchorCache.remainder(
            identityKey: "field", requestFingerprint: "request", precedingText: "Atlas owner is "))
    }

    // MARK: - Rehearsal context

    func testRehearsalOffersTheSampleConversationOnlyWithTheVisibleTextGrant() async throws {
        let box = CotypingSettingsBox(settings)
        // On for new installs; this test starts without the grant.
        box.value.cotypingUseVisibleContext = false
        let coordinator = makeCoordinator(settingsBox: box)
        let sample = CotypingRehearsalConversation.sample
        engine.result = .success(" up on the timeline")

        var preview = try await coordinator.preview(precedingText: "I wanted to follow", conversation: sample)
        XCTAssertFalse(preview.use.visibleText)
        XCTAssertFalse(try XCTUnwrap(engine.requests.last).prompt.contains("Sarah"))

        box.value.cotypingUseVisibleContext = true
        preview = try await coordinator.preview(precedingText: "I wanted to follow", conversation: sample)
        XCTAssertEqual(preview.text, " up on the timeline")
        XCTAssertTrue(preview.use.visibleText)
        let prompt = try XCTUnwrap(engine.requests.last).prompt
        XCTAssertTrue(prompt.contains("Current visible text above the field: Sarah: The migration timeline"))
        XCTAssertTrue(prompt.hasSuffix("I wanted to follow"), "context never changes the text at the caret")

        // The setup sample stays free of every optional source.
        _ = try await coordinator.preview(precedingText: "The local model setup is", conversation: sample,
                                          sampleOnly: true)
        XCTAssertFalse(try XCTUnwrap(engine.requests.last).prompt.contains("Sarah"))
    }

    func testVisibleTextGrantRevokedDuringInferenceDropsThePreview() async throws {
        settings.cotypingUseVisibleContext = true
        let box = CotypingSettingsBox(settings)
        let coordinator = makeCoordinator(settingsBox: box)
        engine.result = .success(" up on the timeline")
        engine.beforeReturning = { box.value.cotypingUseVisibleContext = false }
        let preview = try await coordinator.preview(precedingText: "I wanted to follow",
                                                    conversation: CotypingRehearsalConversation.sample)
        XCTAssertEqual(preview, CotypingPreview())
    }

    func testRehearsalReportsAMemoryLookupThatFoundNothing() async throws {
        settings.cotypingUseMeetingMemory = true
        let box = CotypingSettingsBox(settings)
        let nothing = CotypingMemoryContextProvider.Snapshot(
            selection: .init(), policy: .init(meetings: true, screenDerived: false))
        let coordinator = makeCoordinator(settingsBox: box) { _, _ in nothing }
        engine.result = .success("you")
        let preview = try await coordinator.preview(precedingText: "I'll get back to ")
        XCTAssertTrue(preview.use.searchedMemory)
        XCTAssertTrue(preview.use.meetingSources.isEmpty)
        XCTAssertTrue(coordinator.memoryContextSearched)
        XCTAssertTrue(coordinator.memoryContextSources.isEmpty)
        coordinator.invalidateMemoryContext()
        XCTAssertFalse(coordinator.memoryContextSearched)

        // With the grant off there is no lookup to report.
        box.value.cotypingUseMeetingMemory = false
        let ungranted = try await coordinator.preview(precedingText: "I'll get back to ")
        XCTAssertFalse(ungranted.use.searchedMemory)
        XCTAssertFalse(coordinator.memoryContextSearched)
    }

    // MARK: - Live typing measurements

    private func liveField(_ text: String, bundleID: String = "com.apple.Notes") -> CotypingField {
        CotypingField(appName: "Notes", bundleID: bundleID, processID: 42, role: "AXTextArea",
                      precedingText: text, trailingText: "", selectionLength: 0, caretRect: .zero,
                      isSecure: false, caretIsExact: true)
    }

    func testAcceptedTextIsConfirmedOnceTheFieldShowsIt() {
        let coordinator = makeCoordinator()
        coordinator.noteAcceptance(field: liveField("I wanted to follow"), inserted: " up", charsAccepted: 3)
        XCTAssertEqual(stats.stats.accepts, 1)
        XCTAssertEqual(stats.stats.live["other"]?.accepts, 1)
        coordinator.resolveInsertionCheck(live: liveField("I wanted to follow"))
        XCTAssertNotNil(coordinator.pendingInsertionCheck, "the app has not published the insert yet")
        coordinator.resolveInsertionCheck(live: liveField("I wanted to follow up"))
        XCTAssertNil(coordinator.pendingInsertionCheck)
        XCTAssertEqual(stats.stats.live["other"]?.insertionsConfirmed, 1)
    }

    func testAcceptsSentBeforeTheAppCatchesUpAreConfirmedTogether() {
        let coordinator = makeCoordinator()
        let before = liveField("I wanted to follow", bundleID: "com.tinyspeck.slackmacgap")
        coordinator.noteAcceptance(field: before, inserted: " up", charsAccepted: 3)
        coordinator.noteAcceptance(field: before, inserted: " on", charsAccepted: 3)
        XCTAssertEqual(coordinator.pendingInsertionCheck?.count, 2)
        coordinator.resolveInsertionCheck(
            live: liveField("I wanted to follow up on", bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertEqual(stats.stats.live["chat"]?.accepts, 2)
        XCTAssertEqual(stats.stats.live["chat"]?.insertionsConfirmed, 2)
    }

    /// With no further key or focus change the check used to stay open, and
    /// the text it compares stayed in memory.
    func testAnInsertionCheckExpiresWithoutAnotherEvent() async throws {
        let coordinator = makeCoordinator()
        coordinator.insertionCheckExpiryMilliseconds = 40
        coordinator.noteAcceptance(field: liveField("I wanted to follow"), inserted: " up", charsAccepted: 3)
        XCTAssertNotNil(coordinator.pendingInsertionCheck)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(coordinator.pendingInsertionCheck, "the compared text must not outlive the timeout")
        XCTAssertEqual(stats.stats.live["other"]?.insertionsUnconfirmed, 1)
        XCTAssertEqual(stats.stats.live["other"]?.insertionsConfirmed, 0)
    }

    func testAKeyThatChangesTheTextBeforeTheCaretClosesAnOpenCheck() {
        let coordinator = makeCoordinator()
        let before = liveField("I wanted to follow")
        let backspace = CotypingInputEvent(kind: .textMutation, characters: "")

        // Typing on leaves the check open: the inserted text is still there to read.
        coordinator.noteAcceptance(field: before, inserted: " up", charsAccepted: 3)
        coordinator.noteKey(CotypingInputEvent(kind: .textMutation, characters: " "), live: before)
        XCTAssertNotNil(coordinator.pendingInsertionCheck)
        coordinator.noteKey(CotypingInputEvent(kind: .textMutation, characters: "o"),
                            live: liveField("I wanted to follow up o"))
        XCTAssertNil(coordinator.pendingInsertionCheck)
        XCTAssertEqual(stats.stats.live["other"]?.insertionsConfirmed, 1)

        // Taking the text back, or moving the caret, means it can no longer be read back.
        for key in [backspace, CotypingInputEvent(kind: .navigation, characters: ""),
                    CotypingInputEvent(kind: .shortcut, characters: "", isUndo: true)] {
            coordinator.noteAcceptance(field: before, inserted: " up", charsAccepted: 3)
            coordinator.noteKey(key, live: before)
            XCTAssertNil(coordinator.pendingInsertionCheck)
        }
        XCTAssertEqual(stats.stats.live["other"]?.insertionsUnconfirmed, 3)
        XCTAssertEqual(stats.stats.live["other"]?.insertionsMismatched, 0)
        XCTAssertEqual(stats.stats.live["other"]?.acceptsCorrected, 2, "the deletion and the undo")
    }

    func testOnlyAnImmediateDeletionOrUndoCountsAsACorrection() {
        let coordinator = makeCoordinator()
        let field = liveField("I wanted to follow")
        let backspace = CotypingInputEvent(kind: .textMutation, characters: "")

        coordinator.noteAcceptance(field: field, inserted: " up", charsAccepted: 3)
        coordinator.noteKeyAfterAcceptance(CotypingInputEvent(kind: .acceptance, characters: ""))
        coordinator.noteKeyAfterAcceptance(backspace)
        coordinator.noteKeyAfterAcceptance(backspace)
        XCTAssertEqual(stats.stats.live["other"]?.acceptsCorrected, 1, "only the first key after an accept counts")

        coordinator.noteAcceptance(field: field, inserted: " up", charsAccepted: 3)
        coordinator.noteKeyAfterAcceptance(CotypingInputEvent(kind: .textMutation, characters: " "))
        coordinator.noteKeyAfterAcceptance(backspace)
        XCTAssertEqual(stats.stats.live["other"]?.acceptsCorrected, 1, "typing on keeps the accepted text")

        coordinator.noteAcceptance(field: field, inserted: " up", charsAccepted: 3)
        coordinator.noteKeyAfterAcceptance(CotypingInputEvent(kind: .shortcut, characters: "", isUndo: true))
        XCTAssertEqual(stats.stats.live["other"]?.acceptsCorrected, 2)

        coordinator.noteAcceptance(field: field, inserted: " up", charsAccepted: 3)
        coordinator.acceptAwaitingNextKey?.uptimeNanoseconds = 0
        coordinator.noteKeyAfterAcceptance(backspace)
        XCTAssertEqual(stats.stats.live["other"]?.acceptsCorrected, 2, "a late deletion is ordinary editing")
    }

    func testKeystrokeToVisibleIsMeasuredOncePerKeystroke() {
        let coordinator = makeCoordinator()
        let field = liveField("I wanted to follow", bundleID: "com.apple.Safari")
        let session = CotypingSession(field: field, fullText: " up")
        coordinator.noteSuggestionShown(session)
        XCTAssertNil(stats.stats.live["browser"], "nothing was waiting on a keystroke")

        coordinator.pendingKeystrokeUptime = DispatchTime.now().uptimeNanoseconds
        // A typo fix is instant and says nothing about suggestion latency.
        coordinator.noteSuggestionShown(CotypingSession(field: field, fullText: "follow", kind: .correction(typoWord: "folow")))
        XCTAssertNil(stats.stats.live["browser"])
        coordinator.noteSuggestionShown(session)
        coordinator.noteSuggestionShown(session)
        XCTAssertEqual(stats.stats.live["browser"]?.shown, 1)
        XCTAssertEqual(stats.stats.live["browser"]?.visibleLatenciesMs.count, 1)

        coordinator.pendingKeystrokeUptime = 1
        coordinator.noteSuggestionShown(session)
        XCTAssertEqual(stats.stats.live["browser"]?.shown, 1, "a stale wait is not typing latency")
        XCTAssertNil(coordinator.pendingKeystrokeUptime)
    }

    func testMemoryGroundedAcceptanceDoesNotCreateLearningCopy() {
        settings.cotypingUseLocalLearning = true
        let coordinator = makeCoordinator()
        let field = CotypingField(appName: "Notes", bundleID: "com.apple.Notes", processID: 0,
            role: "AXTextArea", precedingText: "Atlas owner is ", trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true, learningScopeKey: "document:atlas")
        coordinator.activeMemoryContext = memorySnapshot()
        coordinator.recordAcceptedText("Priya leads the release.", field: field, settings: settings)
        coordinator.clearSuggestion()
        XCTAssertEqual(coordinator.learningStore.exampleCount, 0)
        coordinator.activeMemoryContext = .empty
        coordinator.recordAcceptedText("Our usual next step.", field: field, settings: settings)
        coordinator.clearSuggestion()
        XCTAssertEqual(coordinator.learningStore.exampleCount, 1, "control proves the field supports learning")
    }

    // MARK: - Topping up while accepting

    private func shownSession(_ suggestion: String, after text: String) -> CotypingSession {
        var session = CotypingSession(field: liveField(text, bundleID: "com.apple.TextEdit"), fullText: suggestion)
        session.isOpenEnded = true
        return session
    }

    func testATopUpContinuesFromTheEndOfTheSuggestionWithItsContext() async throws {
        settings.cotypingUseClipboard = false
        let coordinator = makeCoordinator()
        let shown = shownSession(" between the number", after: "The main tradeoff is")
            .advanced(by: " between".count)
        engine.result = .success(" of menu items")
        let addition = await coordinator.suggestionExtension(for: shown, settings: settings)
        XCTAssertEqual(addition, " of menu items")
        let request = try XCTUnwrap(engine.requests.last)
        XCTAssertEqual(request.prefixText, "The main tradeoff is between the number")
        XCTAssertEqual(request.maxWords, settings.cotypingMaxWords - 1, "a top-up is one word shorter")
    }

    func testATopUpThatWouldRewriteAVisibleWordIsDropped() async {
        settings.cotypingUseClipboard = false
        let coordinator = makeCoordinator()
        let shown = shownSession(" between the number", after: "The main tradeoff is")
        engine.result = .success("s of items")
        let lengthened = await coordinator.suggestionExtension(for: shown, settings: settings)
        XCTAssertNil(lengthened)
        engine.result = .failure(EngineBoom())
        let failed = await coordinator.suggestionExtension(for: shown, settings: settings)
        XCTAssertNil(failed, "a failed top-up leaves the suggestion as it is")
    }

    func testATopUpIsOnlyAppliedToTheSuggestionOnScreen() {
        let coordinator = makeCoordinator()
        coordinator.isRunning = true
        let shown = shownSession(" between the number", after: "The main tradeoff is")
        coordinator.session = shown
        // No ghost is on screen in a unit test, so nothing may be appended.
        XCTAssertNil(coordinator.extendedSession(adding: " of menu items", to: shown, settings: settings))
        coordinator.extendSuggestionIfNeeded()
        XCTAssertNil(coordinator.extensionTask, "three words ahead need no top-up")
        coordinator.clearSuggestion()
        XCTAssertNil(coordinator.extensionTask)
    }

    // MARK: - Typing away from a suggestion

    /// The 2026-10-09 report: in Chrome the ghost stayed on screen over the
    /// letters just typed until the browser published them, which takes a
    /// while there. A key that leaves the suggestion takes it down at once.
    func testAKeyThatLeavesTheSuggestionTakesItDownAtOnce() {
        let coordinator = makeCoordinator()
        coordinator.isRunning = true
        defer { coordinator.stop() }
        for key in [CotypingInputEvent(kind: .textMutation, characters: "x"),
                    CotypingInputEvent(kind: .textMutation, characters: "")] {
            coordinator.session = shownSession(" up on the timeline", after: "I wanted to follow")
            coordinator.markReady(" up on the timeline")
            coordinator.handleKey(key)
            XCTAssertNil(coordinator.session, key.characters.debugDescription)
            XCTAssertEqual(coordinator.state, .idle)
            XCTAssertFalse(coordinator.inputMonitor.isAcceptActive)
        }
    }

    /// A suggestion with nowhere on screen to go that covers no text is
    /// dropped, not drawn somewhere else: here a guessed caret in a field
    /// that reports no frame, so a popup has no outside to go to.
    func testASuggestionWithNowhereToBeShownIsDropped() {
        let coordinator = makeCoordinator()
        coordinator.isRunning = true
        defer { coordinator.stop() }
        var field = liveField("I wanted to follow", bundleID: "com.google.Chrome")
        field.caretIsExact = false
        coordinator.pendingKeystrokeUptime = DispatchTime.now().uptimeNanoseconds
        coordinator.present(CotypingSession(field: field, fullText: " up on the timeline"), overlayText: " up on the timeline")
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.inputMonitor.isAcceptActive)
        XCTAssertNil(stats.stats.live["browser"], "nothing was shown, so no wait is measured")
    }

    // MARK: - A suggestion left alone

    /// Cotypist 2026.5 fixed a suggestion staying up after a minute without
    /// typing and taking the Tab meant for the app.
    func testASuggestionLeftAloneIsTakenDownSoTabReachesTheApp() async throws {
        let coordinator = makeCoordinator()
        coordinator.isRunning = true
        coordinator.idleSuggestionLifetimeMilliseconds = 400
        coordinator.session = shownSession(" up on the timeline", after: "I wanted to follow")
        coordinator.markReady(" up on the timeline")
        try await Task.sleep(for: .milliseconds(200))
        // Typing through the suggestion is activity, so the clock starts again.
        coordinator.markReady(" on the timeline")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNotNil(coordinator.session, "typed through 250 ms ago, inside the lifetime")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.suggestionExpiryTask)
        XCTAssertFalse(coordinator.inputMonitor.isAcceptActive)
    }

    func testClearingASuggestionStopsItsIdleClock() {
        let coordinator = makeCoordinator()
        coordinator.session = shownSession(" up", after: "I wanted to follow")
        coordinator.markReady(" up")
        XCTAssertNotNil(coordinator.suggestionExpiryTask)
        coordinator.clearSuggestion()
        XCTAssertNil(coordinator.suggestionExpiryTask)
        XCTAssertNil(coordinator.lastSuggestionActivity)
    }

    /// One pending re-read of the caret at a time, and none once the
    /// suggestion it was for is gone.
    func testOnlyTheLatestCaretRereadRuns() {
        let coordinator = makeCoordinator()
        coordinator.session = shownSession(" up", after: "I wanted to follow")
        coordinator.refreshCaretSoon()
        let first = coordinator.caretRefreshTask
        coordinator.refreshCaretSoon()
        XCTAssertTrue(first?.isCancelled ?? false, "a newer key replaces the read")
        let second = coordinator.caretRefreshTask
        coordinator.clearSuggestion()
        XCTAssertTrue(second?.isCancelled ?? false)
        XCTAssertNil(coordinator.caretRefreshTask)
    }

    // MARK: - Escape

    func testEscapeHoldsOnlyTheFieldItWasPressedInAndOnlyBriefly() {
        let coordinator = makeCoordinator()
        let field = liveField("I wanted to follow", bundleID: "com.apple.TextEdit")
        var other = field
        other.focusIdentityKey = "another-field"
        let now = Date()
        XCTAssertFalse(coordinator.isPausedByEscape(in: field, now: now))

        coordinator.escapePause = (
            fieldAnchor: CotypingFieldIdentity.suggestionAnchor(for: field),
            until: now.addingTimeInterval(CotypingEscapeBehavior.pauseSeconds))
        XCTAssertTrue(coordinator.isPausedByEscape(in: field, now: now.addingTimeInterval(9)))
        XCTAssertFalse(coordinator.isPausedByEscape(in: other, now: now.addingTimeInterval(1)))
        XCTAssertFalse(coordinator.isPausedByEscape(in: field, now: now.addingTimeInterval(11)))
        XCTAssertNil(coordinator.escapePause, "an expired hold is forgotten")
    }

    func testEscapeIsLeftAloneWhenNoSuggestionIsShowing() {
        let coordinator = makeCoordinator()
        coordinator.isRunning = true
        XCTAssertFalse(coordinator.dismissFromTap(), "Escape must reach the app")
        XCTAssertNil(coordinator.escapePause)
        // A session without a visible ghost is not a suggestion the user can see.
        coordinator.session = shownSession(" up", after: "I wanted to follow")
        XCTAssertFalse(coordinator.dismissFromTap())
        XCTAssertNil(coordinator.escapePause)
    }
}
