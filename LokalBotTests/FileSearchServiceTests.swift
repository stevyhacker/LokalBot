import CoreGraphics
import DigUpKit
import SQLite3
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LokalBot

/// Files end to end with DigUp's real crawler, readers, index and search, and
/// a deterministic embedder in place of the media llama-server.
@MainActor
final class FileSearchServiceTests: XCTestCase {
    private var root: URL!
    private var chosen: URL!
    private var starts = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)")
        chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        starts = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testIndexesTheChosenFolderAndFindsAFileByItsWords() async throws {
        try write("budget.txt", """
            The quarterly budget review moved to Thursday afternoon. Finance wants the travel costs split by team, \
            and the hiring plan needs a second pass before the board sees it. Bring the updated forecast.
            """)
        try write("garden.md", """
            # Garden notes
            Tomatoes need watering twice a week in summer. The basil went to seed early this year, so plant it \
            later next spring and keep it in partial shade near the fence.
            """)
        try writePicture("harbour.png", width: 640, height: 480)
        let service = makeService()

        service.apply(.init(enabled: true, folders: [chosen.path]))
        await service.waitUntilIdle()

        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(service.totals.searchable, 3)
        XCTAssertEqual(service.totals.pending, 0)
        XCTAssertEqual(starts, 1)
        XCTAssertGreaterThan(service.totals.indexBytes, 0)
        XCTAssertEqual(service.lastPass?.filesRead, 3)

        let hits = await service.search("budget review", queryVector: FakeFileEmbedder.vector(
            for: "task: search result | query: budget review"))
        XCTAssertEqual(hits.first?.name, "budget.txt")
        XCTAssertEqual(hits.first?.kind, .doc)
        let passage = await service.passage(of: try XCTUnwrap(hits.first))
        XCTAssertTrue(passage?.contains("quarterly budget review") == true)

        let wordsOnly = await service.search("basil", queryVector: nil)
        XCTAssertEqual(wordsOnly.map(\.name), ["garden.md"])
        XCTAssertTrue(wordsOnly[0].excerpt?.contains("«basil»") == true)
        let cited = await service.hit(segment: wordsOnly[0].id)
        XCTAssertEqual(cited?.path, wordsOnly[0].path)
    }

    func testAnUnchangedFolderNeverStartsTheModelAgain() async throws {
        try write("notes.txt", String(repeating: "Planning the offsite agenda with the design team. ", count: 8))
        let service = makeService()
        service.apply(.init(enabled: true, folders: [chosen.path]))
        await service.waitUntilIdle()
        XCTAssertEqual(starts, 1)

        service.requestPass()
        await service.waitUntilIdle()

        XCTAssertEqual(starts, 1, "a pass with nothing new must not load the image and text model")
        XCTAssertEqual(service.state, .ready)
    }

    func testARecordingPausesIndexingBeforeTheModelStarts() async throws {
        try write("notes.txt", String(repeating: "Customer interview notes about onboarding friction. ", count: 8))
        let service = makeService()
        var recording = true
        service.isRecording = { recording }

        service.apply(.init(enabled: true, folders: [chosen.path]))
        await service.waitUntilIdle()

        XCTAssertEqual(service.state, .paused(.recording))
        XCTAssertEqual(starts, 0)

        recording = false
        service.conditionsDidChange()
        await service.waitUntilIdle()
        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(service.totals.searchable, 1)
    }

    func testRemovingAFolderDropsItsFilesAndTurningOffDeletesTheIndex() async throws {
        try write("notes.txt", String(repeating: "Invoice INV-2041 was paid late in October. ", count: 8))
        let service = makeService()
        service.apply(.init(enabled: true, folders: [chosen.path]))
        await service.waitUntilIdle()
        let found = await service.search("INV-2041", queryVector: nil)
        XCTAssertEqual(found.count, 1)

        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        service.apply(.init(enabled: true, folders: [other.path]))
        await service.waitUntilIdle()
        let afterRemoval = await service.search("INV-2041", queryVector: nil)
        XCTAssertTrue(afterRemoval.isEmpty)
        XCTAssertEqual(service.totals.searchable, 0)

        service.apply(.init(enabled: false, folders: [other.path]))
        await service.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.state, .off)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(FileSearchService.indexFolderName).path))
    }

    func testTheDateScopeFiltersByTheFilesDate() async throws {
        try write("old.txt", String(repeating: "Roadmap draft for the mobile release planning. ", count: 8))
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: past], ofItemAtPath: chosen.appendingPathComponent("old.txt").path)
        let service = makeService()
        service.apply(.init(enabled: true, folders: [chosen.path]))
        await service.waitUntilIdle()

        let today = DateInterval(start: Calendar.current.startOfDay(for: Date()), duration: 86_400)
        let none = await service.search("roadmap", queryVector: nil, interval: today)
        XCTAssertTrue(none.isEmpty)
        let then = DateInterval(start: past.addingTimeInterval(-3_600), duration: 7_200)
        let found = await service.search("roadmap", queryVector: nil, interval: then)
        XCTAssertEqual(found.map(\.name), ["old.txt"])
    }

    func testRecordingsAndVideoAreReadUnlessTurnedOff() {
        XCTAssertTrue(FileSearchService.indexOptions().excludedExtensions.isEmpty)
        XCTAssertTrue(FileSearchService.Configuration().includesMedia)
        let off = FileSearchService.indexOptions(includesMedia: false)
        for ext in ["mp3", "m4a", "wav", "mov", "mp4", "mkv"] {
            XCTAssertTrue(off.excludedExtensions.contains(ext), ext)
        }
        for ext in ["pdf", "png", "jpg", "heic", "txt", "md", "docx"] {
            XCTAssertFalse(off.excludedExtensions.contains(ext), ext)
        }
        XCTAssertFalse(off.includeCode)
    }

    func testARecordingIsReadInOverlappingWindowsAndLeavesWhenMediaIsTurnedOff() async throws {
        try writeTone("podcast-episode.wav", seconds: 40)
        try write("notes.txt", String(repeating: "Episode notes about sleep and morning routines. ", count: 8))
        let service = makeService()

        service.apply(.init(enabled: true, folders: [chosen.path]))
        await service.waitUntilIdle()

        XCTAssertEqual(service.totals.byKind["audio"], 1)
        // DigUp reads 30 s windows every 25 s: 0–30 s and 25–40 s.
        XCTAssertEqual(try segmentStarts(kind: "audio"), [0, 25])
        let byName = await service.search("podcast episode", queryVector: nil)
        XCTAssertEqual(byName.first?.name, "podcast-episode.wav")
        XCTAssertEqual(byName.first?.kind, .audio)

        service.apply(.init(enabled: true, folders: [chosen.path], includesMedia: false))
        await service.waitUntilIdle()
        XCTAssertNil(service.totals.byKind["audio"])
        XCTAssertEqual(service.totals.byKind["doc"], 1)
    }

    // MARK: - Helpers

    private func makeService() -> FileSearchService {
        FileSearchService(
            indexFolder: root.appendingPathComponent(FileSearchService.indexFolderName, isDirectory: true),
            startEmbedder: { [weak self] _ in
                self?.starts += 1
                return .init(source: FakeFileEmbedder.workerInfo.vectorSource,
                             makeEmbedder: { FakeFileEmbedder() }, end: {})
            })
    }

    /// A 16 kHz mono tone: DigUp drops silent windows.
    private func writeTone(_ name: String, seconds: Int) throws {
        let rate = 16_000
        var samples = Data(capacity: rate * seconds * 2)
        for index in 0..<(rate * seconds) {
            let value = Int16(sin(Double(index) * 2 * .pi * 440 / Double(rate)) * 9_000)
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append(UInt32(36 + samples.count))
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate))
        append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8))
        append(UInt32(samples.count))
        wav.append(samples)
        try wav.write(to: chosen.appendingPathComponent(name))
    }

    private func segmentStarts(kind: String) throws -> [Double] {
        let file = root.appendingPathComponent(FileSearchService.indexFolderName).appendingPathComponent(IndexStore.mainFile)
        let database = try XCTUnwrap(SQLiteDatabase(url: file, readOnly: true))
        return database.query("SELECT loc FROM segments WHERE kind = ?1 ORDER BY loc", bind: [kind]) {
            sqlite3_column_double($0, 0)
        }
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: chosen.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func writePicture(_ name: String, width: Int, height: Int) throws {
        let rgb = (0..<(width * height * 3)).map { UInt8(($0 / 3) % 251) }
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: Data(rgb) as CFData)),
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            chosen.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

/// Bag-of-words vectors: texts that share words point the same way. Pictures
/// and sound get one fixed direction.
private final class FakeFileEmbedder: Embedder {
    static let workerInfo = WorkerInfo(model: "test/fake", revision: "0000000", runtime: "fake", dtype: "f32",
                                 dim: 768, textOnly: false, loadSeconds: nil)
    let info = FakeFileEmbedder.workerInfo

    static func vector(for text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: 768)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var hash: UInt64 = 1_469_598_103_934_665_603
            for byte in word.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            vector[Int(hash % 768)] += 1
        }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    func embedTexts(_ texts: [String]) throws -> [[Float]] { texts.map(Self.vector) }

    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
        paths.map { _ in Embedding(vector: Self.vector(for: "picture"), error: nil) }
    }

    func embedAudio(_ paths: [String]) throws -> [Embedding] {
        paths.map { _ in Embedding(vector: Self.vector(for: "sound"), error: nil) }
    }

    func close() {}
}
