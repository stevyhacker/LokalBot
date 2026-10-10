import XCTest
@testable import LokalBot

final class FunASRNanoModelTests: XCTestCase {
    func testInt8DirectoryAndArgumentsPreserveSpacesAndChinesePaths() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try FunASRNanoModel.load(directory: root.path)
        let args = model.arguments(language: "zh")
        XCTAssertTrue(args.contains("--funasr-nano-llm=\(root.path)/llm.int8.onnx"))
        XCTAssertTrue(args.contains("--funasr-nano-tokenizer=\(root.path)/Qwen3-0.6B"))
        XCTAssertTrue(args.contains("--funasr-nano-language=中文"))
        XCTAssertFalse(args.contains { $0.hasPrefix("--tokens=") })
        XCTAssertFalse(model.arguments(language: nil).contains { $0.hasPrefix("--funasr-nano-language=") })
        XCTAssertFalse(model.arguments(language: "de").contains { $0.hasPrefix("--funasr-nano-language=") })
        XCTAssertEqual(model.weights.count, 3)
    }

    func testFp16AndFp32ExportsRequireExternalFp32Data() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.moveItem(at: root.appendingPathComponent("llm.int8.onnx"), to: root.appendingPathComponent("llm.fp16.onnx"))
        XCTAssertEqual(try FunASRNanoModel.load(directory: root.path).decoder.lastPathComponent, "llm.fp16.onnx")
        try fm.moveItem(at: root.appendingPathComponent("llm.fp16.onnx"), to: root.appendingPathComponent("llm.fp32.onnx"))
        try fm.moveItem(at: root.appendingPathComponent("encoder_adaptor.int8.onnx"), to: root.appendingPathComponent("encoder_adaptor.onnx"))
        try fm.moveItem(at: root.appendingPathComponent("embedding.int8.onnx"), to: root.appendingPathComponent("embedding.onnx"))
        XCTAssertThrowsError(try FunASRNanoModel.load(directory: root.path))
        try Data([1]).write(to: root.appendingPathComponent("llm.fp32.data"))
        let model = try FunASRNanoModel.load(directory: root.path)
        XCTAssertEqual(model.externalData?.lastPathComponent, "llm.fp32.data")
        XCTAssertEqual(model.encoder.lastPathComponent, "encoder_adaptor.onnx")
        XCTAssertEqual(model.embedding.lastPathComponent, "embedding.onnx")
        XCTAssertEqual(model.weights.count, 4)
    }

    func testMissingTokenizerEmptyWeightsAndLFSPointersAreRejected() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let weights = root.appendingPathComponent("llm.int8.onnx")
        try Data().write(to: weights)
        XCTAssertThrowsError(try FunASRNanoModel.load(directory: root.path))
        try Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 123".utf8).write(to: weights)
        XCTAssertThrowsError(try FunASRNanoModel.load(directory: root.path))
        try Data([1]).write(to: weights)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Qwen3-0.6B/merges.txt"))
        XCTAssertThrowsError(try FunASRNanoModel.load(directory: root.path))
    }

    func testOriginalPyTorchAndNonDirectoriesAreRejected() throws {
        XCTAssertThrowsError(try FunASRNanoModel.load(directory: ""))
        XCTAssertThrowsError(try FunASRNanoModel.load(directory: "relative/model"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("model.pt"))
        XCTAssertThrowsError(try FunASRNanoModel.load(directory: root.path))
        XCTAssertThrowsError(try FunASRNanoModel.load(directory: root.appendingPathComponent("model.pt").path))
    }

    func testValidationDoesNotModifyUserOwnedFilesAndAllowsCacheSymlinks() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let original = root.appendingPathComponent("llm.int8.onnx")
        let target = root.appendingPathComponent("cached-weights")
        try fm.moveItem(at: original, to: target)
        try fm.createSymbolicLink(at: original, withDestinationURL: target)
        let before = try fm.contentsOfDirectory(atPath: root.path).sorted()
        _ = try FunASRNanoModel.load(directory: root.path)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).sorted(), before)
        XCTAssertEqual(try Data(contentsOf: target), Data([1]))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Fun ASR 中文 \(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Qwen3-0.6B"), withIntermediateDirectories: true)
        for name in ["encoder_adaptor.int8.onnx", "embedding.int8.onnx", "llm.int8.onnx",
                     "Qwen3-0.6B/tokenizer.json", "Qwen3-0.6B/vocab.json", "Qwen3-0.6B/merges.txt"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        return root
    }
}
