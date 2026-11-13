import XCTest
@testable import LokalBot

final class OnnxModelValidationTests: XCTestCase {
    func testInterruptedOrCorruptModelNeverCountsAsPrepared() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("onnx-install-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let weights = directory.appendingPathComponent("model.int8.onnx")
        try Data().write(to: weights)
        XCTAssertFalse(OnnxTranscriptionEngine.isModelInstalled(in: directory, model: .senseVoice))
        try Data("weights".utf8).write(to: weights)
        XCTAssertThrowsError(try OnnxTranscriptionEngine.markInstalled(in: directory, model: .senseVoice))
        try Data("tokens".utf8).write(to: directory.appendingPathComponent("tokens.txt"))
        try OnnxTranscriptionEngine.markInstalled(in: directory, model: .senseVoice)
        XCTAssertTrue(OnnxTranscriptionEngine.isModelInstalled(in: directory, model: .senseVoice))
        XCTAssertFalse(OnnxTranscriptionEngine.isModelInstalled(in: directory, model: .gigaamRussian))
        try Data("corrupt".utf8).write(to: weights)
        XCTAssertFalse(OnnxTranscriptionEngine.isModelInstalled(in: directory, model: .senseVoice))
    }
}
