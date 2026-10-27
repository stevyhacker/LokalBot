import XCTest
@testable import LokalBot

/// The CLI ↔ app control socket: wire format, socket placement, and a real
/// round trip through `AppControlServer` and `AppControlClient`.
final class AppControlTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-control-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
    }

    func testRequestAndResponseWireFormat() throws {
        let request = AppControlRequest(method: .settingsGet, params: ["keys": ["appTheme"]])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["protocol"] as? Int, AppControlProtocol.version)
        XCTAssertEqual(object["method"] as? String, "settings.get")
        XCTAssertEqual(try JSONDecoder().decode(AppControlRequest.self, from: JSONEncoder().encode(request)), request)

        let failure = AppControlResponse.failure(.settingsAccessDisabled)
        let decoded = try JSONDecoder().decode(AppControlResponse.self, from: JSONEncoder().encode(failure))
        XCTAssertEqual(decoded.error?.code, "settings_access_disabled")
        XCTAssertEqual(decoded.error?.errorDescription?.hasPrefix("[settings_access_disabled] "), true)
    }

    func testSocketLivesInControlFolderUnlessThePathIsTooLong() {
        let short = URL(fileURLWithPath: "/tmp/lb/control", isDirectory: true)
        XCTAssertEqual(AppControlSocket.path(controlDirectory: short), "/tmp/lb/control/app.sock")

        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120) + "/control", isDirectory: true)
        let fallback = AppControlSocket.path(controlDirectory: long, userID: 501)
        XCTAssertTrue(fallback.hasPrefix("/tmp/lokalbot-501-"))
        XCTAssertLessThanOrEqual(fallback.utf8.count, AppControlSocket.maximumPathBytes)
        XCTAssertEqual(fallback, AppControlSocket.path(controlDirectory: long, userID: 501))
        XCTAssertNotEqual(fallback, AppControlSocket.path(
            controlDirectory: long.deletingLastPathComponent().appendingPathComponent("other"), userID: 501))
    }

    func testBackgroundLaunchArgumentIsNotAHeadlessCommand() {
        let arguments = ["/Applications/LokalBot.app/Contents/MacOS/LokalBot",
                         AppControlProtocol.backgroundLaunchArgument]
        XCTAssertTrue(AppControlProtocol.isBackgroundLaunch(arguments: arguments))
        XCTAssertNil(HeadlessCommand.parse(arguments))
        XCTAssertFalse(AppControlProtocol.isBackgroundLaunch(arguments: [arguments[0]]))
    }

    func testClientRefusesBeforeConnectingWhenSettingsAccessIsOff() {
        let client = AppControlClient(root: makeRoot())
        XCTAssertThrowsError(try client.request(.hello, launch: false)) { error in
            XCTAssertEqual((error as? AppControlError)?.code, "settings_access_disabled")
        }
    }

    func testNoLaunchReportsAppNotRunning() throws {
        let root = makeRoot()
        try SettingsControlGate(root: root).enable()
        XCTAssertThrowsError(try AppControlClient(root: root).request(.hello, launch: false)) { error in
            XCTAssertEqual((error as? AppControlError)?.code, "app_not_running")
        }
    }

    func testInstanceLockMeansTheAppIsRunning() throws {
        let root = makeRoot()
        let client = AppControlClient(root: root)
        XCTAssertFalse(client.isAppRunning)
        var lock = LibraryInstanceLock.acquire(root: root, timeout: 0)
        XCTAssertNotNil(lock)
        XCTAssertTrue(client.isAppRunning)
        lock = nil
        XCTAssertFalse(client.isAppRunning)
    }

    func testRoundTripThroughTheServer() async throws {
        let root = makeRoot()
        try SettingsControlGate(root: root).enable()
        let client = AppControlClient(root: root)
        let server = AppControlServer(path: client.socketPath) { request, peer in
            request.method == "hello"
                ? .success(["echo": .string(request.method), "pid": .number(Double(peer.pid ?? 0))])
                : .failure(.unknownMethod(request.method))
        }
        try server.start()
        defer { server.stop() }

        // The client blocks on the socket; keep it off the main actor that
        // runs the server's handler.
        let reply = try await Task.detached { try client.request(.hello, launch: false) }.value
        XCTAssertEqual(reply["echo"], "hello")
        // The server identifies its peer: here, this test process.
        XCTAssertEqual(reply["pid"]?.intValue, Int(ProcessInfo.processInfo.processIdentifier))

        let refused = await Task.detached { () -> String? in
            do {
                _ = try client.request(.status, launch: false)
                return nil
            } catch {
                return (error as? AppControlError)?.code
            }
        }.value
        XCTAssertEqual(refused, "unknown_method")

        let socket = try FileManager.default.attributesOfItem(atPath: client.socketPath)
        XCTAssertEqual((socket[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testServerAnswersGarbageWithInvalidRequest() async throws {
        let root = makeRoot()
        let path = AppControlSocket.path(controlDirectory: SettingsControlGate(root: root).controlDirectory)
        try FileManager.default.createDirectory(
            at: SettingsControlGate(root: root).controlDirectory, withIntermediateDirectories: true)
        let server = AppControlServer(path: path) { _, _ in .success(true) }
        try server.start()
        defer { server.stop() }

        let reply = try await Task.detached { () -> AppControlResponse in
            let descriptor = try AppControlSocket.connect(path: path, timeout: 5)
            defer { Darwin.close(descriptor) }
            try AppControlSocket.writeAll(descriptor, Data("not json\n".utf8))
            return try JSONDecoder().decode(AppControlResponse.self, from: AppControlSocket.readLine(descriptor))
        }.value
        XCTAssertEqual(reply.error?.code, "invalid_request")
    }

    func testStoppingRemovesTheSocket() throws {
        let root = makeRoot()
        let control = SettingsControlGate(root: root).controlDirectory
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        let path = AppControlSocket.path(controlDirectory: control)
        let server = AppControlServer(path: path) { _, _ in .success(true) }
        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try AppControlSocket.connect(path: path, timeout: 1))
    }
}

@MainActor
final class AppControlHandlerTests: XCTestCase {
    private var app: AppState!
    private var gate: SettingsControlGate!
    private var handler: AppControlHandler!

    override func setUp() async throws {
        app = AppState()
        gate = SettingsControlGate(root: app.storage.rootURL)
        handler = AppControlHandler(app: app, gate: gate)
    }

    override func tearDown() async throws {
        gate.disable()
        app.settings = AppSettings()
        handler = nil
        gate = nil
        app = nil
    }

    private func call(_ method: AppControlProtocol.Method,
                      _ params: [String: JSONValue]? = nil) async -> AppControlResponse {
        await handler.handle(AppControlRequest(method: method, params: params))
    }

    func testRefusesWhileSettingsAccessIsOff() async {
        let response = await call(.hello)
        XCTAssertEqual(response.error?.code, "settings_access_disabled")
    }

    func testReadsLiveSettingsAsTokens() async throws {
        try gate.enable()
        var settings = app.settings
        settings.appTheme = .dark
        app.settings = settings

        let list = await call(.settingsList)
        guard case .array(let entries)? = list.result else { return XCTFail("no list: \(list)") }
        XCTAssertEqual(entries.count, SettingRegistry.all.count)

        let get = await call(.settingsGet, ["keys": ["appTheme"]])
        XCTAssertEqual(get.result, [[
            "key": "appTheme", "title": "Theme", "category": "general", "tier": "preference",
            "type": "choice", "value": "dark", "default": "system", "changed": true,
        ]])

        let privacy = await call(.settingsList, ["category": "privacy"])
        guard case .array(let privacyEntries)? = privacy.result else { return XCTFail("no list") }
        XCTAssertEqual(privacyEntries.count, 4)
    }

    func testReportsStableErrors() async throws {
        try gate.enable()
        let unknownKey = await call(.settingsGet, ["keys": ["noSuchSetting"]])
        XCTAssertEqual(unknownKey.error?.code, "unknown_key")
        let missingKeys = await call(.settingsGet)
        XCTAssertEqual(missingKeys.error?.code, "invalid_request")
        let unknownMethod = await handler.handle(AppControlRequest(
            protocolVersion: AppControlProtocol.version, method: "settings.delete", params: nil))
        XCTAssertEqual(unknownMethod.error?.code, "unknown_method")
        let future = await handler.handle(AppControlRequest(
            protocolVersion: AppControlProtocol.version + 1, method: "hello", params: nil))
        XCTAssertEqual(future.error?.code, "app_outdated")
        let badTarget = await call(.open, ["target": "meeting"])
        XCTAssertEqual(badTarget.error?.code, "invalid_request")
        let badKey = await call(.open, ["target": "settings", "key": "noSuchSetting"])
        XCTAssertEqual(badKey.error?.code, "unknown_key")
    }

    func testStatusReportsAccessAndRecordingState() async throws {
        try gate.enable()
        let status = await call(.status)
        let result = try XCTUnwrap(status.result)
        XCTAssertEqual(result["recording"]?["active"], .bool(app.isRecording))
        XCTAssertEqual(result["access"]?["settings"], true)
        XCTAssertEqual(result["library"]?["root"]?.stringValue, app.storage.rootURL.path)
        XCTAssertEqual(result["app"]?["protocol"]?.intValue, AppControlProtocol.version)
    }
}
