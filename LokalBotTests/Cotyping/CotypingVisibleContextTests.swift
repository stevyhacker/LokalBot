import XCTest
@testable import LokalBot

final class CotypingVisibleContextTests: XCTestCase {
    static func fixture() -> CotypingVisibleContextReplay.Fixture {
        let window = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let target = CotypingVisibleContext.Target(
            appName: "Mail", bundleID: "com.apple.mail", windowID: "window", focusID: "composer",
            scopeID: "thread", windowTitle: "Juniper launch", hasWebContent: false, focusedSecureField: false,
            windowFrame: window, fieldFrame: CGRect(x: 300, y: 700, width: 600, height: 100), scopeFrame: window)
        func node(_ id: String, _ rect: CGRect, _ text: String, role: String = "AXStaticText",
                  hidden: Bool = false, secure: Bool = false) -> CotypingVisibleContextReplay.Node {
            .init(region: .init(id: id, role: role, frame: rect, hidden: hidden, secure: secure), children: [], text: text)
        }
        let nodes = [
            node("message", CGRect(x: 320, y: 590, width: 550, height: 70), "Nadja: Please send the Juniper draft by Thursday."),
            node("sidebar", CGRect(x: 10, y: 580, width: 230, height: 70), "Send it to Mallory on Monday."),
            node("below", CGRect(x: 320, y: 810, width: 550, height: 30), "Friday is the wrong deadline."),
            node("offscreen", CGRect(x: 320, y: -70, width: 550, height: 30), "This is not visible."),
            node("hidden", CGRect(x: 320, y: 570, width: 550, height: 20), "Hidden message", hidden: true),
            node("secure", CGRect(x: 320, y: 550, width: 550, height: 20), "Secret value", secure: true),
            node("other-input", CGRect(x: 320, y: 500, width: 550, height: 40), "Draft in another input", role: "AXTextArea"),
            node("composer", target.fieldFrame, "I'll send it by ", role: "AXTextArea"),
            node("other-window", CGRect(x: 320, y: 560, width: 550, height: 20), "Other window"),
        ]
        let root = CotypingVisibleContextReplay.Node(
            region: .init(id: "thread", role: "AXGroup", frame: window, hidden: false, secure: false),
            children: nodes.filter { $0.region.id != "other-window" }.map(\.region.id))
        return .init(target: target, nodes: [root] + nodes)
    }

    func testCaptureReadsOnlyVisibleTextAboveComposerBeforePromptConstruction() throws {
        let source = CotypingVisibleContextReplay(Self.fixture())
        let capture = try XCTUnwrap(source.capture(enabled: true))
        XCTAssertEqual(capture.excerpts.map(\.id), ["message"])
        XCTAssertEqual(source.textReadIDs, ["message"], "Filtering after reading the window is too late")
        XCTAssertFalse(source.metadataReadIDs.contains("other-window"))
        let prompt = CotypingPromptRenderer.prompt(prefixText: "I'll send it by ", visibleContext: capture.text)
        XCTAssertTrue(prompt.contains("Thursday"))
        XCTAssertFalse(prompt.contains("Mallory"))
        XCTAssertTrue(prompt.hasSuffix("I'll send it by "))
    }

    func testOptOutMakesZeroBoundaryReads() {
        let source = CotypingVisibleContextReplay(Self.fixture())
        XCTAssertNil(source.capture(enabled: false))
        XCTAssertEqual(source.targetReads, 0)
        XCTAssertTrue(source.metadataReadIDs.isEmpty)
        XCTAssertTrue(source.textReadIDs.isEmpty)
    }

    func testAppDomainSecureAndUnknownOriginGatesBeforeText() {
        var blocked: [CotypingVisibleContextReplay.Fixture] = []
        var fixture = Self.fixture()
        fixture.excludedApps = ["Mail"]
        blocked.append(fixture)
        fixture = Self.fixture()
        fixture.target.focusedSecureField = true
        blocked.append(fixture)
        fixture.target.focusedSecureField = nil
        blocked.append(fixture)
        fixture = Self.fixture()
        fixture.target.appName = "Chrome"
        fixture.target.bundleID = "com.google.Chrome"
        blocked.append(fixture)
        fixture.target.hasWebContent = true
        fixture.target.sourceURL = "https://mail.private.example/thread"
        fixture.excludedDomains = ["private.example"]
        blocked.append(fixture)
        fixture = Self.fixture()
        fixture.target.windowTitle = nil
        blocked.append(fixture)
        for fixture in blocked {
            let source = CotypingVisibleContextReplay(fixture)
            XCTAssertNil(source.capture(enabled: true))
            XCTAssertTrue(source.textReadIDs.isEmpty)
            XCTAssertTrue(source.metadataReadIDs.isEmpty)
        }
    }

    func testParentHiddenAndClippedScrollAreasNeverReadChildText() throws {
        for hidden in [false, true] {
            var fixture = Self.fixture()
            fixture.nodes[0].children = ["scroll"]
            fixture.nodes.append(.init(region: .init(
                id: "scroll", role: "AXScrollArea", frame: CGRect(x: 300, y: 630, width: 600, height: 60),
                hidden: hidden, secure: false), children: ["message"]))
            let source = CotypingVisibleContextReplay(fixture)
            XCTAssertNil(try XCTUnwrap(source.capture(enabled: true)).text)
            XCTAssertTrue(source.textReadIDs.isEmpty)
        }
    }

    func testCrossOriginSubtreeAndToolbarAreNotRead() throws {
        for role in ["AXWebArea", "AXToolbar", "AXOutline"] {
            var fixture = Self.fixture()
            fixture.nodes[0].children = ["pane"]
            fixture.nodes.append(.init(region: .init(
                id: "pane", role: role, frame: CGRect(x: 300, y: 200, width: 600, height: 500),
                hidden: false, secure: false, sourceURL: "https://unrelated.example"), children: ["message"]))
            let source = CotypingVisibleContextReplay(fixture)
            XCTAssertNil(try XCTUnwrap(source.capture(enabled: true)).text)
            XCTAssertTrue(source.textReadIDs.isEmpty)
        }
    }

    func testTargetChangesDuringReadDiscardContext() {
        for keyPath in [\CotypingVisibleContext.Target.windowID, \.focusID, \.scopeID] {
            var fixture = Self.fixture()
            var changed = fixture.target
            changed[keyPath: keyPath] = "changed"
            fixture.afterTarget = changed
            let source = CotypingVisibleContextReplay(fixture)
            XCTAssertNil(source.capture(enabled: true))
        }
        var fixture = Self.fixture()
        fixture.afterTarget = fixture.target
        fixture.afterTarget?.fieldFrame.origin.y += 10
        XCTAssertNil(CotypingVisibleContextReplay(fixture).capture(enabled: true))
    }

    func testScrollDuringReadAndDeadlineDiscardPartialContext() {
        let source = CotypingVisibleContextReplay(Self.fixture())
        source.onTextRead = { id in
            var region = source.fixture.nodes.first { $0.region.id == id }!.region
            region.frame?.origin.y -= 20
            source.regionOverrides[id] = region
        }
        XCTAssertNil(source.capture(enabled: true))
        let timedOut = CotypingVisibleContextReplay(Self.fixture())
        timedOut.onTextRead = { _ in timedOut.withinBudget = false }
        XCTAssertNil(timedOut.capture(enabled: true))
    }

    func testNearestMessagesHavePriorityAndPromptStaysBounded() throws {
        var fixture = Self.fixture()
        fixture.nodes[0].children = []
        for index in 0..<12 {
            let id = "message-\(index)"
            fixture.nodes[0].children.append(id)
            fixture.nodes.append(.init(region: .init(
                id: id, role: "AXStaticText", frame: CGRect(x: 320, y: 120 + index * 45, width: 550, height: 30),
                hidden: false, secure: false), children: [], text: "Message \(index): " + String(repeating: "content ", count: 50)))
        }
        let source = CotypingVisibleContextReplay(fixture)
        let capture = try XCTUnwrap(source.capture(enabled: true))
        XCTAssertEqual(source.textReadIDs, ["message-11", "message-10"])
        XCTAssertEqual(capture.excerpts.map(\.id), ["message-10", "message-11"])
        XCTAssertLessThanOrEqual(capture.text?.count ?? 0, CotypingVisibleContext.maximumCharacters)
    }

    func testCredentialSnippetsOmittedAndPromptMarkersCannotLeak() throws {
        var fixture = Self.fixture()
        fixture.nodes[1].text = "The password is hunter2 and the account owner is Nadja."
        XCTAssertNil(try XCTUnwrap(CotypingVisibleContextReplay(fixture).capture(enabled: true)).text)
        let rendered = CotypingPromptRenderer.render(
            prefixText: "I'll send it by ", memoryContext: "The old deadline was Monday.",
            visibleContext: "Nadja: The new deadline is Thursday.")
        XCTAssertTrue(CotypingPromptLeakGuard.detectsLeak(
            in: "Current visible text above the field:", conditioningPreface: rendered.conditioningPreface))
        XCTAssertTrue(CotypingPromptLeakGuard.detectsLeak(
            in: "Relevant saved facts:", conditioningPreface: rendered.conditioningPreface))
        XCTAssertLessThanOrEqual(rendered.conditioningPreface?.count ?? 0, CotypingPromptRenderer.maxPrefaceCharacters)
    }

    func testBothContextSourcesSurviveMaximumPrefaceAndKeepCaretWhitespace() {
        let visible = String(repeating: "v", count: 420)
        let memory = String(repeating: "m", count: 180)
        let rendered = CotypingPromptRenderer.render(
            prefixText: "I will send it to ", surfaceLines: ["Subject: " + String(repeating: "s", count: 80)],
            styleNote: String(repeating: "style ", count: 200), memoryContext: memory, visibleContext: visible)
        XCTAssertTrue(rendered.prompt.contains(visible))
        XCTAssertTrue(rendered.prompt.contains(memory))
        XCTAssertTrue(rendered.prompt.hasSuffix("I will send it to "))
        XCTAssertLessThanOrEqual(rendered.conditioningPreface?.count ?? 0, CotypingPromptRenderer.maxPrefaceCharacters)
    }

    @MainActor
    func testContextSnapshotFlowsThroughBackgroundExecutor() async throws {
        let snapshot = try XCTUnwrap(CotypingVisibleContextReplay(Self.fixture()).capture(enabled: true))
        let executor = CotypingAXSnapshotExecutor { options in
            var field = CotypingField(appName: "Mail", processID: 123, role: "AXTextArea",
                                      precedingText: "I'll send it by ", trailingText: "", selectionLength: 0,
                                      caretRect: .zero, isSecure: false, caretIsExact: true)
            field.visibleContextWasRequested = options.contains(.visibleContext)
            field.visibleContext = options.contains(.visibleContext) ? snapshot : nil
            return CotypingFocus(appName: "Mail", capability: .supported, field: field)
        }
        let tracker = CotypingFocusTracker(snapshotExecutor: executor)
        let focus = await tracker.refreshNow(includeVisibleContext: true)
        XCTAssertEqual(focus.field?.visibleContext, snapshot)
        let quick = await tracker.refreshForValidation()
        XCTAssertNil(quick?.field?.visibleContext)
    }

    @MainActor
    func testContextValidationTimeoutFailsClosed() async {
        let executor = CotypingAXSnapshotExecutor(deadlineMilliseconds: 10) { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return .none
        }
        let tracker = CotypingFocusTracker(snapshotExecutor: executor)
        let result = await tracker.refreshForValidation()
        XCTAssertNil(result)
    }

    /// The text above a field is read once per field and then refreshed in
    /// the background: a keystroke gets the previous read instead of waiting.
    func testAStaleFieldContextIsServedWhileItRefreshesInTheBackground() {
        let now = LockedValue<TimeInterval>(0)
        let cache = CotypingFieldContextCache<String>(label: "test", maxAge: 3, clock: { now.value })
        let reads = LockedValue(0)
        func read() -> String {
            reads.update { $0 += 1 }
            return "read \(reads.value)"
        }
        XCTAssertEqual(cache.value(forKey: "field") { read() }, "read 1")
        now.update { $0 = 2 }
        XCTAssertEqual(cache.value(forKey: "field") { read() }, "read 1")
        XCTAssertEqual(reads.value, 1)
        now.update { $0 = 5 }
        XCTAssertEqual(cache.value(forKey: "field") { read() }, "read 1")
        cache.waitForRefreshes()
        XCTAssertEqual(cache.value(forKey: "field") { read() }, "read 2")
        XCTAssertEqual(reads.value, 2)
    }

    /// An empty field has no font to read yet; the first typed character's
    /// font must be read then, not hidden behind a remembered failure.
    func testAFontThatCouldNotBeReadIsNotRemembered() {
        let now = LockedValue<TimeInterval>(0)
        let cache = CotypingFieldContextCache<String>(label: "test", maxAge: 5, clock: { now.value })
        XCTAssertNil(cache.valueIfReadable(forKey: "field") { nil })
        XCTAssertEqual(cache.valueIfReadable(forKey: "field") { "Helvetica 12" }, "Helvetica 12")
        now.update { $0 = 10 }
        XCTAssertEqual(cache.valueIfReadable(forKey: "field") { nil }, "Helvetica 12")
        cache.waitForRefreshes()
        XCTAssertEqual(cache.cachedValue(forKey: "field"), "Helvetica 12")
    }

    func testLeavingAFieldForgetsTheOthers() {
        let cache = CotypingFieldContextCache<String>(label: "test", maxAge: 3)
        _ = cache.value(forKey: "a") { "text above a" }
        _ = cache.value(forKey: "b") { "text above b" }
        cache.removeAll(except: "b")
        XCTAssertNil(cache.cachedValue(forKey: "a"))
        XCTAssertEqual(cache.cachedValue(forKey: "b"), "text above b")
        cache.removeAll(except: nil)
        XCTAssertNil(cache.cachedValue(forKey: "b"))
    }

    func testForgottenFieldContextCannotBeRestoredByAReadInFlight() {
        let now = LockedValue<TimeInterval>(0)
        let cache = CotypingFieldContextCache<String>(label: "test", maxAge: 3, clock: { now.value })
        _ = cache.value(forKey: "field") { "before" }
        now.update { $0 = 5 }
        let gate = DispatchSemaphore(value: 0)
        _ = cache.value(forKey: "field") {
            gate.wait()
            return "read before the grant was withdrawn"
        }
        cache.removeAll()
        gate.signal()
        cache.waitForRefreshes()
        XCTAssertNil(cache.cachedValue(forKey: "field"))
    }

    func testAutocompleteURLExclusionKeepsItsHostWideMeaning() {
        var settings = AppSettings()
        settings.cotypingEnabled = true
        settings.cotypingUseVisibleContext = true
        settings.cotypingExcludedDomains = "https://private.example/login"
        var target = Self.fixture().target
        target.hasWebContent = true
        target.sourceURL = "https://private.example/messages"
        XCTAssertFalse(CotypingVisibleContext.Policy(settings: settings).permits(target))
    }

    func testVisibleConversationSuppliesMemoryQueryForAGenericReplyOnlyWhenCaptured() throws {
        var fixture = Self.fixture()
        fixture.nodes[1].text = "Please send the Juniper draft to the reviewer we agreed on."
        var field = CotypingField(appName: "Mail", processID: 123, role: "AXTextArea",
                                  precedingText: "Sure, I will send it to ", trailingText: "", selectionLength: 0,
                                  caretRect: .zero, isSecure: false, caretIsExact: true)
        let now = Date()
        let facts = [CotypingMemoryContext.Item(id: "juniper-reviewer", title: "Juniper",
                                               text: "The Juniper draft reviewer is Nadja.", updatedAt: now,
                                               requiresMeetings: true)]
        func selected(_ field: CotypingField, meetings: Bool = true) -> [String] {
            CotypingMemoryContext.select(items: facts, for: field, includeTitle: false,
                                         policy: .init(meetings: meetings, screenDerived: false), now: now).items.map(\.id)
        }
        XCTAssertEqual(selected(field), [])
        field.visibleContext = try XCTUnwrap(CotypingVisibleContextReplay(fixture).capture(enabled: true))
        XCTAssertEqual(selected(field), ["juniper-reviewer"])
        XCTAssertEqual(selected(field, meetings: false), [])
        field.visibleContext = CotypingVisibleContextReplay(fixture).capture(enabled: false)
        XCTAssertEqual(selected(field), [])
    }

    func testVisibleGenericVocabularyCannotRetrieveAnotherProjectsMemory() throws {
        var fixture = Self.fixture()
        fixture.nodes[1].text = "Please send the Willow export in CSV format."
        var field = CotypingField(appName: "Mail", processID: 123, role: "AXTextArea",
                                  precedingText: "Sure, I'll export it as ", trailingText: "", selectionLength: 0,
                                  caretRect: .zero, isSecure: false, caretIsExact: true)
        field.visibleContext = try XCTUnwrap(CotypingVisibleContextReplay(fixture).capture(enabled: true))
        let now = Date()
        let facts = [CotypingMemoryContext.Item(id: "mistral-format", title: "Mistral",
                                               text: "The Mistral export format is JSON.", updatedAt: now,
                                               requiresMeetings: true)]
        let policy = CotypingMemoryContext.Policy(meetings: true, screenDerived: false)
        // The visible conversation names Willow. Its incidental words ("export",
        // "format") must not admit Mistral: nearby text can name a saved source
        // but never counts as the user's own wording.
        let query = CotypingMemoryContext.query(for: field, includeTitle: false)
        XCTAssertTrue(query.all.isSuperset(of: ["willow", "export", "format"]))
        XCTAssertFalse(query.own.contains("format"))
        XCTAssertTrue(CotypingMemoryContext.select(items: facts, for: field, includeTitle: false,
                                                   policy: policy, now: now).items.isEmpty)
        // Two ordinary words of the user's own draft name no project either.
        field.visibleContext = nil
        field.precedingText = "The export format is "
        XCTAssertTrue(CotypingMemoryContext.select(items: facts, for: field, includeTitle: false,
                                                   policy: policy, now: now).items.isEmpty)
        field.precedingText = "The Mistral export format is "
        XCTAssertEqual(CotypingMemoryContext.select(items: facts, for: field, includeTitle: false,
                                                     policy: policy, now: now).items.map(\.id), ["mistral-format"])
    }

    func testSettingsConsentRoundTripAndSharedExclusions() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.cotypingUseVisibleContext)
        var settings = legacy
        settings.cotypingEnabled = true
        settings.cotypingUseVisibleContext = true
        settings.excludedApps = "Mail"
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).cotypingUseVisibleContext)
        XCTAssertFalse(CotypingVisibleContext.Policy(settings: settings).permits(Self.fixture().target))
        XCTAssertFalse(settings.cotypingUseMeetingMemory)
        XCTAssertFalse(settings.cotypingUseScreenMemory)
    }

    /// On for new installs only: settings saved by an earlier version keep
    /// what they had, and a missing key there means off.
    func testVisibleTextIsOnForNewInstallsOnly() throws {
        XCTAssertTrue(AppSettings().cotypingUseVisibleContext)
        let decoder = JSONDecoder()
        let saved = try JSONSerialization.data(withJSONObject: ["cotypingEnabled": true])
        XCTAssertFalse(try decoder.decode(AppSettings.self, from: saved).cotypingUseVisibleContext)
        for choice in [true, false] {
            var settings = AppSettings()
            settings.cotypingUseVisibleContext = choice
            let roundTrip = try decoder.decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(roundTrip.cotypingUseVisibleContext, choice)
        }
    }

    /// PRIVACY.md promises nearby text never comes from a private window.
    func testPrivateWindowsAreNeverRead() {
        var settings = AppSettings()
        settings.cotypingEnabled = true
        settings.cotypingUseVisibleContext = true
        let policy = CotypingVisibleContext.Policy(settings: settings)
        var target = Self.fixture().target
        XCTAssertTrue(policy.permits(target), "control: an ordinary window is read")
        for title in ["Juniper launch — Private Browsing", "Juniper launch - Google Chrome (Incognito)",
                      "Juniper launch — InPrivate"] {
            target.windowTitle = title
            XCTAssertFalse(policy.permits(target), title)
        }
    }
}

/// A value shared with a cache's clock or background reads.
private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func update(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }
}
