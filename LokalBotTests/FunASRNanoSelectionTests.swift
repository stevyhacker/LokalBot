import XCTest
@testable import LokalBot

final class FunASRNanoSelectionTests: XCTestCase {
    func testSettingsMigrationAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.funASRNanoModelDirectory, "")
        var settings = AppSettings()
        settings.transcriptionModel = .funASRNano
        settings.funASRNanoModelDirectory = "/tmp/我的模型"
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.transcriptionModel, .funASRNano)
        XCTAssertEqual(restored.funASRNanoModelDirectory, settings.funASRNanoModelDirectory)
        XCTAssertTrue(restored.transcriptionEngine() is FunASRNanoEngine)
    }

    func testDirectorySwitchCanBeUndoneAndInvalidatesReadinessAndChecks() {
        var old = AppSettings()
        old.transcriptionModel = .funASRNano
        old.funASRNanoModelDirectory = "/tmp/old"
        let patch = ModelSelectionPatch(transcription: .funASRNano, funASRNanoDirectory: "/tmp/new")
        let changed = patch.applying(to: old)
        XCTAssertTrue(ModelReadinessSnapshot.processingReadinessChanged(from: old, to: changed))
        XCTAssertNotEqual(ModelCheckIdentity(role: .transcribe, settings: old), ModelCheckIdentity(role: .transcribe, settings: changed))
        XCTAssertEqual(patch.inverse(in: old).applying(to: changed), old)
        XCTAssertFalse(patch.preparationContextMatches(changed, original: old))
        XCTAssertEqual(changed.transcriptionLanguage, old.transcriptionLanguage)
        XCTAssertEqual(changed.summaryLanguage, old.summaryLanguage)
    }

    func testMissingDirectoryNeverCountsAsAvailableAndDeleteDoesNotTouchIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("funasr-user-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("keep.txt")
        try Data("user model".utf8).write(to: marker)
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.funASRNano, funASRNanoDirectory: root.path))
        try TranscriptionModelStore.delete(.funASRNano)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "user model")
    }
}
