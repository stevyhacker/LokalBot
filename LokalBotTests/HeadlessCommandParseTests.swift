import XCTest
@testable import LokalBot

final class HeadlessCommandParseTests: XCTestCase {
    func testDictationReplayRequiresExplicitFixtureAndServer() {
        XCTAssertEqual(HeadlessCommand.parse(["app", "--dictation-replay", "/tmp/input.json", "--server-url", "http://127.0.0.1:18973/v1"]),
                       .dictationReplay(input: URL(fileURLWithPath: "/tmp/input.json"), endpoint: URL(string: "http://127.0.0.1:18973/v1")!))
        XCTAssertNil(HeadlessCommand.parse(["app", "--dictation-replay", "/tmp/input.json"]))
    }
    func testCotypingReplayRequiresExplicitFixtureAndModel() {
        XCTAssertEqual(
            HeadlessCommand.parse(["LokalBot", "--cotyping-replay", "/tmp/fixture.json", "--model-path", "/tmp/model.gguf"]),
            .cotypingReplay(input: URL(fileURLWithPath: "/tmp/fixture.json"),
                            engine: .local(model: URL(fileURLWithPath: "/tmp/model.gguf"))))
        XCTAssertNil(HeadlessCommand.parse(["LokalBot", "--cotyping-replay", "/tmp/fixture.json"]))
    }

    func testCotypingReplayAcceptsOnlyEncryptedOrLoopbackRemoteEndpoints() {
        let base = ["LokalBot", "--cotyping-replay", "/tmp/fixture.json", "--completions-model", "qwen-3.8-27b"]
        XCTAssertEqual(
            HeadlessCommand.parse(base + ["--completions-url", "https://api.cerebras.ai/v1",
                                          "--completions-extra-body", #"{"top_k":20}"#]),
            .cotypingReplay(input: URL(fileURLWithPath: "/tmp/fixture.json"),
                            engine: .remote(baseURL: URL(string: "https://api.cerebras.ai/v1")!,
                                            model: "qwen-3.8-27b", extraBodyJSON: #"{"top_k":20}"#)))
        XCTAssertEqual(
            HeadlessCommand.parse(base + ["--completions-url", "http://127.0.0.1:18080/v1"]),
            .cotypingReplay(input: URL(fileURLWithPath: "/tmp/fixture.json"),
                            engine: .remote(baseURL: URL(string: "http://127.0.0.1:18080/v1")!,
                                            model: "qwen-3.8-27b", extraBodyJSON: nil)))
        XCTAssertEqual(
            HeadlessCommand.parse(base + ["--completions-url", "https://openrouter.ai/api/v1", "--completions-chat"]),
            .cotypingReplay(input: URL(fileURLWithPath: "/tmp/fixture.json"),
                            engine: .remote(baseURL: URL(string: "https://openrouter.ai/api/v1")!,
                                            model: "qwen-3.8-27b", extraBodyJSON: nil, chat: true)))
        XCTAssertNil(HeadlessCommand.parse(base + ["--completions-url", "http://api.example.com/v1"]))
        XCTAssertNil(HeadlessCommand.parse(["LokalBot", "--cotyping-replay", "/tmp/fixture.json",
                                            "--completions-url", "https://api.cerebras.ai/v1"]))
    }

    func testRemoteReplayRetriesOnlyTransientFailures() {
        func status(_ code: Int, retryAfter: TimeInterval? = nil) -> Error {
            TextEngineError.httpStatus(code: code, detail: "", retryAfter: retryAfter)
        }
        XCTAssertEqual(CotypingQualityReplay.retryDelay(after: status(429, retryAfter: 3), attempt: 1), 3)
        XCTAssertEqual(CotypingQualityReplay.retryDelay(after: status(503), attempt: 3), 4)
        XCTAssertNil(CotypingQualityReplay.retryDelay(after: status(401), attempt: 1))
        XCTAssertNil(CotypingQualityReplay.retryDelay(after: status(400), attempt: 1))
        XCTAssertEqual(CotypingQualityReplay.extraBody(from: #"{"top_k":20}"#)?["top_k"] as? Int, 20)
        XCTAssertEqual(CotypingQualityReplay.extraBody(from: nil)?.isEmpty, true)
        XCTAssertNil(CotypingQualityReplay.extraBody(from: "[1]"))
    }

    func testParsesExportDiagnostics() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--export-diagnostics", "/tmp/d.zip"]),
                       .exportDiagnostics(destination: URL(fileURLWithPath: "/tmp/d.zip")))
    }

    func testParsesHealthWithDayAndJSON() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--health"]), .health(dayKey: nil, json: false))
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--health", "--day", "2026-09-29", "--json"]),
                       .health(dayKey: "2026-09-29", json: true))
    }

    func testParsesRecordCaptureWithAnOptionalScenario() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--record-capture", "30"]),
                       .recordCapture(seconds: 30, scenario: "real"))
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--record-capture", "45", "--scenario", "meet-join"]),
                       .recordCapture(seconds: 45, scenario: "meet-join"))
        XCTAssertNil(HeadlessCommand.parse(["LokalBot", "--record-capture", "soon"]))
    }
}
