import XCTest
@testable import LokalBot

final class MCPServerIntegrationTests: XCTestCase {
    private var root: URL!

    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lokalbot-cli")
    }

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw XCTSkip("no embedded lokalbot-cli in this build")
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpserver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AgentAccessGate(root: root).enable()

        try MeetingFixture.write([
            .init(
                id: UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!,
                title: "Cache planning",
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                summary: "We chose Redis for the caching layer.",
                transcriptLines: ["Redis wins because of pub sub."]),
        ], under: root)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func runSession(_ lines: [String]) throws -> [String] {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["LOKALBOT_STORAGE_ROOT"] = root.path
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        stdin.fileHandleForWriting.write(Data(
            (lines.joined(separator: "\n") + "\n").utf8))
        stdin.fileHandleForWriting.closeFile()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: output, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    func testGoldenSessionInitializeListCall() throws {
        let output = try runSession([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"xctest","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"redis"}}}"#,
        ])
        XCTAssertEqual(output.count, 3)
        XCTAssertTrue(output[0].contains(#""protocolVersion":"2025-06-18""#))
        XCTAssertTrue(output[0].contains(#""name":"lokalbot""#))
        for tool in [
            "list_meetings", "get_meeting", "search_meetings", "ask_library",
            "search_screen", "get_timeline", "get_recent_activity", "get_app_usage",
            "get_screenshot_detail",
        ] {
            XCTAssertTrue(output[1].contains("\"\(tool)\""), tool)
        }
        XCTAssertTrue(output[2].lowercased().contains("redis"))
        XCTAssertTrue(output[2].contains(#""isError":false"#))
    }

    func testToolsRefusedWithoutMarker() throws {
        AgentAccessGate(root: root).disable()
        let output = try runSession([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"xctest","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#,
        ])
        XCTAssertEqual(output.count, 2)
        XCTAssertTrue(output[1].contains("[access_disabled]"))
        XCTAssertTrue(output[1].contains(#""isError":true"#))
    }

    func testScreenToolsRequireTheirOwnMarker() throws {
        let output = try runSession([
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_screen","arguments":{"query":"redis"}}}"#,
        ])
        XCTAssertEqual(output.count, 2)
        XCTAssertTrue(output[0].contains(#""isError":false"#))
        XCTAssertTrue(output[1].contains("[screen_access_disabled]"))

        try ScreenMemoryAccessGate(root: root).enable()
        AgentAccessGate(root: root).disable()
        let inverse = try runSession([
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_screenshot_detail","arguments":{}}}"#,
        ])
        XCTAssertTrue(inverse[0].contains("[access_disabled]"))
        XCTAssertTrue(inverse[1].contains("[invalid_arguments]"), inverse[1])
    }

    func testInitializeRespondsWhileClientKeepsStdinOpen() throws {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["mcp"]
        process.environment = ["LOKALBOT_STORAGE_ROOT": root.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let responseArrived = expectation(description: "initialize answered before EOF")
        let output = MCPOutputProbe(expectation: responseArrived)
        stdout.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        try process.run()
        defer {
            stdin.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            stdout.fileHandleForReading.readabilityHandler = nil
        }
        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"xctest","version":"1"}}}"#
        stdin.fileHandleForWriting.write(Data((request + "\n").utf8))
        XCTAssertEqual(XCTWaiter.wait(for: [responseArrived], timeout: 2), .completed)
        XCTAssertTrue(output.text.contains(#""protocolVersion":"2025-06-18""#))
    }

    func testUnterminatedOversizedRecordIsRejectedBeforeEOF() throws {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["LOKALBOT_STORAGE_ROOT"] = root.path
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let responseArrived = expectation(description: "oversized record rejected before EOF")
        let output = MCPOutputProbe(expectation: responseArrived)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }

        try process.run()
        let payload = Data(
            repeating: 0x78,
            count: MCPRequest.maximumLineBytes + 2 * 1_024 * 1_024)
        stdin.fileHandleForWriting.write(payload)

        let result = XCTWaiter.wait(for: [responseArrived], timeout: 2)
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.text.contains(#""code":-32600"#))
        XCTAssertTrue(output.text.contains("1 MiB"))
    }
}

private final class MCPOutputProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var data = Data()
    private var fulfilled = false

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        let shouldFulfill = !fulfilled && data.contains(0x0A)
        if shouldFulfill { fulfilled = true }
        lock.unlock()
        if shouldFulfill { expectation.fulfill() }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
