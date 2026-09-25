import XCTest
@testable import LokalBot

/// End-to-end: real Bun, real pinned pi runtime, our real extension, talking to a
/// stub OpenAI server. Skips when the vendored runtime isn't installed
/// (enable Agent Mode in the app once to install it).
final class PiIntegrationTests: XCTestCase {

    private var stub: Process?
    private var stubPort: Int = 0

    override func tearDown() async throws {
        stub?.terminate()
        stub = nil
    }

    private func requireRuntime() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["LOKALBOT_PINNED_RUNTIME_ROOT"],
           !path.isEmpty {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.isExecutableFile(
                atPath: AgentRuntimeLayout.bunBinary(under: root).path),
                FileManager.default.fileExists(
                    atPath: AgentRuntimeLayout.piCLI(under: root).path) else {
                throw XCTSkip("pinned agent runtime is incomplete at \(path)")
            }
            return root
        }
        let root = AgentRuntimeLayout.defaultRoot
        guard AgentRuntimeLayout.isInstalled(under: root) else {
            throw XCTSkip("agent runtime not installed; enable Agent Mode in the app once")
        }
        return root
    }

    private func startStub(bun: URL) throws {
        guard let script = Bundle(for: Self.self).url(forResource: "stub-openai",
                                                      withExtension: "ts",
                                                      subdirectory: "Fixtures") else {
            return XCTFail("stub-openai.ts missing from test bundle")
        }
        let process = Process()
        process.executableURL = bun
        process.arguments = [script.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        stub = process
        guard let first = out.fileHandleForReading.availableLine(timeout: 10),
              let port = Int(first.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return XCTFail("stub didn't print its port")
        }
        stubPort = port
    }

    func testPromptRoundTripsThroughRealPi() async throws {
        let root = try requireRuntime()
        let bun = AgentRuntimeLayout.bunBinary(under: root)
        try startStub(bun: bun)

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-itest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let repoRoot = URL(fileURLWithPath: #filePath)      // …/LokalBotTests/PiIntegrationTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
        let endpoint = AgentLLMEndpoint(
            baseURL: URL(string: "http://127.0.0.1:\(stubPort)/v1")!,
            model: "stub-model", contextTokens: 16_384, apiKey: nil)
        let plan = PiLaunchPlanner.plan(
            bun: bun,
            piCLI: AgentRuntimeLayout.piCLI(under: root),
            extensionDirectory: repoRoot.appendingPathComponent("LokalBot/Resources/pi/lokalbot-extension"),
            skillDirectory: nil,
            sessionDirectory: workspace.appendingPathComponent("sessions"),
            workspace: workspace,
            endpoint: endpoint,
            helpersDirectory: nil)

        let process = PiProcess(plan: plan)
        try await process.start()
        defer { Task { await process.stop() } }
        let client = PiRPCClient(transport: process)
        await client.run()

        // No mutable capture: the collector Task RETURNS the verdict.
        // If the reply never arrives, the deadline task cancels the collector,
        // the for-await loop ends, and `collector.value` resolves to false.
        let events = await client.events
        let collector = Task { () -> Bool in
            for await event in events {
                if case .messageEnd(let role, let text, _, _) = event,
                   role == "assistant", text.contains("STUB-REPLY") {
                    return true
                }
            }
            return false
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(30))
            collector.cancel()
        }

        let response = try await client.request(
            .prompt(id: "it1", message: "say hi", streamingBehavior: nil))
        XCTAssertTrue(response.success, response.error ?? "")

        let sawStubReply = await collector.value
        deadline.cancel()
        XCTAssertTrue(sawStubReply, "assistant message with stub content never arrived")
        await process.stop()
    }
}

// MARK: - Small helpers

private extension FileHandle {
    /// Blocking single-line read with a deadline; fine for test setup.
    func availableLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            let data = availableData
            if data.isEmpty { Thread.sleep(forTimeInterval: 0.05); continue }
            buffer.append(data)
            if let newline = buffer.firstIndex(of: 0x0A) {
                return String(data: buffer[..<newline], encoding: .utf8)
            }
        }
        return nil
    }
}
