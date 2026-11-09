import XCTest
@testable import LokalBot

final class FunASRNanoRuntimeTests: XCTestCase {
    func testRuntimeResultsKeepEmptyRegionsInOrder() async throws {
        let root = try helper(stdout: "{\"text\":\"你好\"}\n{\"text\":\"\"}\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await run(root, count: 2)
        XCTAssertEqual(result, ["你好", ""])
    }

    func testMissingRuntimeResultIsAnErrorInsteadOfDroppingAudio() async throws {
        let root = try helper(stdout: "{\"text\":\"first region\"}\n")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await run(root, count: 2)
            XCTFail("Partial results must not become a successful Fun-ASR transcript")
        } catch OnnxTranscriptionEngine.EngineError.incompleteResults {
            // Expected: the caller retains the recording for a retry.
        }
    }

    func testRealLocalModelWhenFixturesAreProvided() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["LOKALBOT_FUNASR_TEST_MODEL_DIR"],
              let audio = env["LOKALBOT_FUNASR_TEST_WAV"] else {
            throw XCTSkip("Provide a local sherpa-onnx Fun-ASR model and public/synthetic speech WAV.")
        }
        let engine = FunASRNanoEngine(directory: directory)
        try await engine.prepare(progress: nil)
        let transcript = try await engine.transcribe(audio: URL(fileURLWithPath: audio), language: nil)
        XCTAssertFalse(transcript.segments.isEmpty)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.end > $0.start && !$0.text.isEmpty })
        XCTAssertTrue(transcript.engine.contains("Fun-ASR-Nano-2512"))
    }

    func testRepeatedRunsAllReturn() async throws {
        // Each await in runBatch may resume on another thread. While the exit
        // wait depended on the launching thread's run loop, a few dozen runs
        // were enough to strand one forever.
        let root = try helper(stdout: "{\"text\":\"你好\"}\n{\"text\":\"\"}\n")
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<40 {
            let result = try await run(root, count: 2)
            XCTAssertEqual(result, ["你好", ""])
        }
    }

    /// A stuck runtime fails the test within `timeout` instead of stalling CI
    /// until the job's time limit.
    private func run(_ root: URL, count: Int, timeout: TimeInterval = 30) async throws -> [String] {
        let returned = XCTestExpectation(description: "Fun-ASR runtime returned")
        let batch = Task {
            defer { returned.fulfill() }
            return try await OnnxTranscriptionEngine.runBatch(
                runtime: (root.appendingPathComponent("runtime"), root), arguments: [], weights: [],
                modelID: "funasr-test", label: "Fun-ASR test", wavs: (0..<count).map { root.appendingPathComponent("\($0).wav") },
                requireAllResults: true)
        }
        guard await XCTWaiter.fulfillment(of: [returned], timeout: timeout) == .completed else {
            batch.cancel()
            throw RuntimeTimeout(seconds: timeout)
        }
        return try await batch.value
    }

    private struct RuntimeTimeout: Error, CustomStringConvertible {
        let seconds: TimeInterval
        var description: String {
            "OnnxTranscriptionEngine.runBatch did not return within \(Int(seconds)) s."
        }
    }

    private func helper(stdout: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("funasr-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("runtime")
        try Data("#!/bin/sh\ncat <<'RESULTS'\n\(stdout)RESULTS\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return root
    }
}
