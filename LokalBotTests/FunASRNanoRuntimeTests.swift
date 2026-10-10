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

    private func run(_ root: URL, count: Int) async throws -> [String] {
        try await OnnxTranscriptionEngine.runBatch(
            runtime: (root.appendingPathComponent("runtime"), root), arguments: [], weights: [],
            modelID: "funasr-test", label: "Fun-ASR test", wavs: (0..<count).map { root.appendingPathComponent("\($0).wav") },
            requireAllResults: true)
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
