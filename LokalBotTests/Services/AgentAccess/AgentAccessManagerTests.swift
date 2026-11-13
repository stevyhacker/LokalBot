import XCTest
@testable import LokalBot

@MainActor
final class AgentAccessManagerTests: XCTestCase {
    private var root: URL!
    private var gate: AgentAccessGate!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("accessmanager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        gate = AgentAccessGate(root: root)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeManager(
        startEngine: ((AppSettings, StorageManager) async -> String?)? = { _, _ in nil },
        broker: InferenceBroker = .shared
    ) -> AgentAccessManager {
        AgentAccessManager(
            storage: StorageManager(),
            settings: { AppSettings() },
            gate: gate,
            startEngine: startEngine,
            broker: broker)
    }

    func testToggleMirrorsMarkerFile() {
        let manager = makeManager()
        manager.start()
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(gate.isEnabled)

        manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(gate.isEnabled)

        manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(gate.isEnabled)
    }

    func testStartResumesEnabledStateFromMarker() throws {
        try gate.enable()
        let manager = makeManager()
        manager.start()
        XCTAssertTrue(manager.isEnabled)
    }

    func testWakeTouchStartsEngineAndConsumesWake() async throws {
        let woke = expectation(description: "engine started")
        let manager = makeManager { _, _ in
            woke.fulfill()
            return nil
        }
        manager.setEnabled(true)

        try gate.touchWake()
        await fulfillment(of: [woke], timeout: 5)
        try await waitUntil { !gate.pendingWake }
        XCTAssertFalse(gate.pendingWake)
        XCTAssertNil(gate.readWakeError())
    }

    func testEngineFailureWritesWakeErrorFile() async throws {
        let failed = expectation(description: "engine refused")
        let manager = makeManager { _, _ in
            failed.fulfill()
            return "The built-in model isn't downloaded."
        }
        manager.setEnabled(true)

        try gate.touchWake()
        await fulfillment(of: [failed], timeout: 5)
        try await waitUntil { gate.readWakeError() != nil }
        XCTAssertEqual(
            gate.readWakeError(),
            "The built-in model isn't downloaded.")
    }

    func testNoWakeHandlingAfterDisable() async throws {
        let woke = expectation(description: "engine started")
        woke.isInverted = true
        let manager = makeManager { _, _ in
            woke.fulfill()
            return nil
        }
        manager.setEnabled(true)
        manager.setEnabled(false)

        try? gate.touchWake()
        await fulfillment(of: [woke], timeout: 1)
    }

    // MARK: - Wake lease

    private actor BrokerHookRecorder {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
        func count(of event: String) -> Int { events.filter { $0 == event }.count }
    }

    private actor BlockingEnsure {
        private var didRelease = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func block() async {
            if didRelease { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            didRelease = true
            let waiting = waiters
            waiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
    }

    /// The manager finishes handling a wake just after the engine answers;
    /// wait for that instead of sleeping a fixed 200 ms on a busy runner.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeFakeBroker(recorder: BrokerHookRecorder) -> InferenceBroker {
        var hooks: [InferenceRole: InferenceBroker.RuntimeHooks] = [:]
        for role in InferenceRole.allCases {
            hooks[role] = InferenceBroker.RuntimeHooks(
                ensure: { _ in await recorder.record("ensure:\(role.rawValue)") },
                stop: { await recorder.record("stop:\(role.rawValue)") })
        }
        return InferenceBroker(hooks: hooks, leaseStateSink: { _, _ in })
    }

    func testWakeLeaseEnsuresEveryTimeButNeverStacks() async {
        let recorder = BrokerHookRecorder()
        let broker = makeFakeBroker(recorder: recorder)
        let manager = makeManager(startEngine: nil, broker: broker)
        let modelURL = root.appendingPathComponent("fake-model.gguf")

        let first = await manager.acquireOrRenewAgentLease(modelURL: modelURL)
        XCTAssertNil(first)
        let second = await manager.acquireOrRenewAgentLease(modelURL: modelURL)
        XCTAssertNil(second)

        let ensures = await recorder.count(of: "ensure:mainLLM")
        XCTAssertEqual(ensures, 2, "every wake re-ensures, reviving a crashed server")
        let active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 1, "each wake replaces the previous lease; they never stack")
    }

    func testDisableReleasesTheAgentLease() async throws {
        let recorder = BrokerHookRecorder()
        let broker = makeFakeBroker(recorder: recorder)
        let manager = makeManager(startEngine: nil, broker: broker)
        let modelURL = root.appendingPathComponent("fake-model.gguf")

        manager.setEnabled(true)
        _ = await manager.acquireOrRenewAgentLease(modelURL: modelURL)
        var active = await broker.activeLeaseCount(.mainLLM)
        XCTAssertEqual(active, 1)

        manager.setEnabled(false)
        // releaseAgentLease is fire-and-forget from the MainActor; poll briefly.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            active = await broker.activeLeaseCount(.mainLLM)
            if active == 0 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(active, 0, "disabling agent access must release the wake lease")
    }

    func testDisableDuringWakeReleasesLeaseAcquiredAfterDisable() async throws {
        let entry = ModelCatalog.Entry(
            id: "wake-fixture", displayName: "Wake Fixture",
            fileName: "wake-fixture.gguf", url: "", sizeGB: 0,
            blurb: "", disablesThinking: false)
        let models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: models.appendingPathComponent(entry.fileName))
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn
        settings.builtInModelID = entry.id
        settings.customBuiltInModels = [entry]

        let blocker = BlockingEnsure()
        let ensureStarted = expectation(description: "broker ensure started")
        var hooks: [InferenceRole: InferenceBroker.RuntimeHooks] = [:]
        for role in InferenceRole.allCases {
            hooks[role] = .init(
                ensure: { _ in
                    if role == .mainLLM {
                        ensureStarted.fulfill()
                        await blocker.block()
                    }
                },
                stop: {})
        }
        let broker = InferenceBroker(hooks: hooks, leaseStateSink: { _, _ in })
        let manager = AgentAccessManager(
            storage: StorageManager(),
            settings: { settings },
            gate: gate,
            startEngine: nil,
            broker: broker)

        manager.setEnabled(true)
        try gate.touchWake()
        await fulfillment(of: [ensureStarted], timeout: 5)
        manager.setEnabled(false)
        await blocker.release()

        var active = await broker.activeLeaseCount(.mainLLM)
        let deadline = Date().addingTimeInterval(3)
        while active != 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
            active = await broker.activeLeaseCount(.mainLLM)
        }
        XCTAssertEqual(active, 0)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(gate.isEnabled)
    }
}
