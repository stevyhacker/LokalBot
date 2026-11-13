import XCTest
@testable import LokalBot

final class GraniteTurboTests: XCTestCase {
    func testCTCCollapsePreservesRepeatsSeparatedByBlank() {
        XCTAssertEqual(GraniteTurboTokenizer.collapse([0, 4, 4, 0, 4, 7, 7, 0]), [4, 4, 7])
        XCTAssertEqual(GraniteTurboTokenizer.collapse([]), [])
        XCTAssertEqual(GraniteTurboTokenizer.collapse([0, 0]), [])
    }

    func testByteLevelDecodeIncludesSpacesAndMultibyteCharacters() throws {
        var vocabulary = Dictionary(uniqueKeysWithValues: (0..<16_384).map { ("unused\($0)", $0) })
        for (name, id) in [("<|blank|>", 0), ("Ġhello", 1), ("ĠcafÃ©", 2)] {
            vocabulary.removeValue(forKey: "unused\(id)")
            vocabulary[name] = id
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "model": ["vocab": vocabulary], "decoder": ["type": "ByteLevel"],
        ])
        let tokenizer = try GraniteTurboTokenizer(data: data)
        XCTAssertEqual(try tokenizer.decode([0, 1, 1, 0, 2, 2]), "hello café")
        XCTAssertThrowsError(try tokenizer.decode([16_384]))
    }

    func testInvalidTokenizerFailsBeforeInference() throws {
        XCTAssertThrowsError(try GraniteTurboTokenizer(data: Data("{}".utf8)))
    }

    func testFastModeLanguageBoundaryAndDefault() throws {
        for language: String? in [nil, "auto", "en", "English"] {
            XCTAssertTrue(GraniteTurboEngine.accepts(language: language))
        }
        for language in ["fr", "sr", "zh", "de"] {
            XCTAssertFalse(GraniteTurboEngine.accepts(language: language))
        }
        XCTAssertEqual(TranscriptionModelChoice.recommended, .qwenASR17B)
        let data = try JSONEncoder().encode(TranscriptionModelChoice.graniteTurbo)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionModelChoice.self, from: data), .graniteTurbo)
    }

    func testFastModeRequiresBothCompleteArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = GraniteTurboEngine.modelRoot(appSupport: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(GraniteTurboEngine.isDownloaded(appSupport: root))
        for artifact in GraniteTurboEngine.artifacts {
            let path = directory.appendingPathComponent(artifact.name)
            FileManager.default.createFile(atPath: path.path, contents: nil)
            let handle = try FileHandle(forWritingTo: path)
            try handle.truncate(atOffset: UInt64(artifact.bytes))
            try handle.close()
        }
        XCTAssertTrue(GraniteTurboEngine.isDownloaded(appSupport: root))
        try Data("incomplete".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        XCTAssertFalse(GraniteTurboEngine.isDownloaded(appSupport: root))
    }

    /// Optional non-UI integration gate. The fixture is generated from public
    /// audio by Benchmarks/think/ModelAlternatives/2026-09-08/prepare-native-parity.py;
    /// regular unit runs never fetch weights or read a user's meeting library.
    func testNativeInferenceMatchesReferenceWhenFixtureProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LOKALBOT_GRANITE5_REFERENCE"] else {
            throw XCTSkip("Set LOKALBOT_GRANITE5_REFERENCE to a prepared public-audio parity manifest.")
        }
        struct Clip: Decodable {
            let id: String
            let samples: String
            let audio: String
            let text: String
        }
        struct Fixture: Decodable {
            let modelDirectory: String
            let clips: [Clip]
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(fixture.clips.isEmpty)
        let model = try GraniteTurboModel(directory: URL(fileURLWithPath: fixture.modelDirectory))
        var rows: [[String: Any]] = []
        for clip in fixture.clips {
            try autoreleasepool {
                let data = try Data(contentsOf: URL(fileURLWithPath: clip.samples))
                let samples = data.withUnsafeBytes { bytes in
                    stride(from: 0, to: bytes.count, by: 4).map {
                        bytes.loadUnaligned(fromByteOffset: $0, as: Float.self)
                    }
                }
                let start = Date()
                let text = try model.transcribe(samples)
                rows.append(["id": clip.id, "text": text, "reference": clip.text,
                             "seconds": Date().timeIntervalSince(start)])
                XCTAssertEqual(text, clip.text, clip.id)
            }
        }
        if let report = environment["LOKALBOT_GRANITE5_REPORT"] {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: report))
        }
    }

    func testNativeEnginePreparesAndTranscribesPublicAudioWhenFixtureProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_GRANITE5_REFERENCE"] else {
            throw XCTSkip("Set LOKALBOT_GRANITE5_REFERENCE to exercise native speech model preparation.")
        }
        struct Clip: Decodable { let audio: String }
        struct Fixture: Decodable {
            let modelDirectory: String
            let clips: [Clip]
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let clip = try XCTUnwrap(fixture.clips.first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("granite-engine-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = GraniteTurboEngine.modelRoot(appSupport: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for artifact in GraniteTurboEngine.artifacts {
            let source = URL(fileURLWithPath: fixture.modelDirectory).appendingPathComponent(artifact.name)
            try FileManager.default.linkItem(at: source, to: directory.appendingPathComponent(artifact.name))
        }
        let engine = GraniteTurboEngine(appSupport: root)
        try await engine.prepare()
        for artifact in GraniteTurboEngine.artifacts {
            let marker = directory.appendingPathComponent(artifact.name).appendingPathExtension("sha256")
            XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), artifact.sha256)
        }
        let transcript = try await engine.transcribe(audio: URL(fileURLWithPath: clip.audio), language: "en")
        XCTAssertFalse(transcript.segments.isEmpty)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.end > $0.start && !$0.text.isEmpty })
        XCTAssertTrue(transcript.engine.contains(GraniteTurboEngine.repository))
    }
}
