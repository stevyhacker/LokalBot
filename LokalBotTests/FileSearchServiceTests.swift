import CoreGraphics
import CoreServices
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
    private var passes = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)")
        chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        starts = 0
        passes = 0
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

    func testOnlyAChangeThatCanAlterTheIndexStartsAPass() async throws {
        try write("notes.txt", String(repeating: "Planning the offsite agenda with the design team. ", count: 8))
        try makeFolder("node_modules/left-pad")
        try makeFolder("Site/.git")
        try makeFolder("Site/dist")
        let service = makeService()
        service.changeDelay = .milliseconds(50)
        // Asked once as each pass begins.
        service.isRecording = { [weak self] in
            self?.passes += 1
            return false
        }
        service.apply(.init(enabled: true, folders: [chosen.path]))
        await service.waitUntilIdle()
        XCTAssertEqual(passes, 1)

        let text = String(repeating: "The venue for the offsite moved to the harbour. ", count: 8)
        try write("node_modules/left-pad/readme.md", text)
        try write("Site/dist/index.html", text)
        try write("build.log", text)
        try await Task.sleep(for: .seconds(1))
        await service.waitUntilIdle()
        XCTAssertEqual(passes, 1, "these changes can't alter the index")

        try write("venue.txt", text)
        let deadline = Date().addingTimeInterval(20)
        while passes < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        await service.waitUntilIdle()
        XCTAssertEqual(passes, 2)
        XCTAssertEqual(service.totals.searchable, 2)
        service.stop()
    }

    func testTheWatcherPassesOverSkippedChangesToReportOneThatCounts() async throws {
        try makeFolder("node_modules/left-pad")
        try makeFolder("Cache.noindex")
        try makeFolder("Site/.git")
        try makeFolder("Site/dist")
        let reported = expectation(description: "a change that counts")
        let paths = ReportedPaths()
        let watcher = try XCTUnwrap(FileFolderWatcher(
            folders: [chosen.path], options: FileSearchService.indexOptions(), latency: 0.1) { path in
                if paths.append(path) == 1 { reported.fulfill() }
            })
        defer { watcher.stop() }

        try write("node_modules/left-pad/readme.md", "skipped folder")
        try write("Cache.noindex/notes.md", "skipped folder")
        try write(".notes.md", "hidden")
        try write("build.log", "a type that is never read")
        try write("Site/dist/index.html", "inside a code project")
        try write("Site/Screenshot 2026-11-02 at 10.00.00.png", "the one thing a code project keeps")
        await fulfillment(of: [reported], timeout: 20)

        XCTAssertEqual(paths.first?.hasSuffix("/Site/Screenshot 2026-11-02 at 10.00.00.png"), true, paths.first ?? "")
    }

    func testAChangeCountsOnlyWhereTheCrawlWouldKeepIt() throws {
        try makeFolder("node_modules/left-pad")
        try makeFolder("Work/Site/.git")
        try makeFolder("Work/Site/assets")
        try makeFolder("Work/App")
        try makeFolder("Work/Notes")
        try write("Work/App/package.json", "{}")
        try write("Work/App/plain.png", "")
        try write("Work/Site/assets/marked.png", "")
        try write("Work/Site/assets/plain.png", "")
        XCTAssertEqual(setxattr(chosen.path + "/Work/Site/assets/marked.png",
                                "com.apple.metadata:kMDItemIsScreenCapture", "1", 1, 0, 0), 0)
        let file = kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated
        let folder = kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated
        let moved = kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed
        let cloned = kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCloned
        let counts = { (name: String, flags: Int) in self.counts(name, flags) }

        // What can be indexed, here or gone.
        for name in ["notes.md", "Work/Notes/gone.txt", "report.pdf", "photo.heic", "clip.mov"] {
            XCTAssertTrue(counts(name, file), name)
            XCTAssertTrue(counts(name, kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRemoved), name)
        }
        XCTAssertFalse(self.counts("clip.mov", file, includesMedia: false), "recordings and video are off")
        XCTAssertTrue(self.counts("notes.md", file, includesMedia: false))

        // Where the crawl doesn't go, and what it never reads.
        for name in [".DS_Store", ".hidden/notes.md", "node_modules/left-pad/readme.md", "Cache.noindex/notes.md",
                     "Work/Notes/server.log", "Work/Notes/data.json", "Work/Notes/no-extension"] {
            XCTAssertFalse(counts(name, file), name)
        }

        // Inside a code project: screenshots, and nothing else.
        for name in ["Work/Site/readme.md", "Work/Site/assets/plain.png", "Work/Site/assets/gone.png",
                     "Work/App/plain.png", "Work/Site/Screenshots/notes.md", "Work/Site/report.pdf"] {
            XCTAssertFalse(counts(name, file), name)
        }
        for name in ["Work/Site/assets/marked.png", "Work/Site/Screenshot 2026-11-02 at 10.00.00.png",
                     "Work/Site/Screenshots/2026-11-02.png"] {
            XCTAssertTrue(counts(name, file), name)
        }

        // A folder's only marker decides what's kept around it. Editing it, or another beside it, changes nothing.
        XCTAssertTrue(counts("Work/App/package.json", kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRemoved))
        XCTAssertTrue(counts("Work/Notes/Cargo.toml", file))
        XCTAssertFalse(counts("Work/App/package.json", kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified))
        XCTAssertFalse(counts("Work/Site/package.json", file), "the folder has .git")
        XCTAssertFalse(counts("Work/App/sub/Cargo.toml", file), "a project above it already decides")

        // A new folder's contents report themselves; one that moved or was cloned says only this.
        XCTAssertFalse(counts("Work/Notes/New", folder))
        XCTAssertFalse(counts("Work/Site/dist", folder))
        for flags in [moved, cloned] {
            XCTAssertTrue(counts("Work/Notes/Trip", flags))
            XCTAssertTrue(counts("Work/Site/Trip", flags), "it could hold screenshots")
            XCTAssertFalse(counts("node_modules/left-pad/lib", flags))
        }

        // FSEvents lost track, or the path can't be placed: only a sync can tell.
        XCTAssertTrue(counts("node_modules/left-pad", kFSEventStreamEventFlagMustScanSubDirs))
        XCTAssertTrue(counts("Work/Notes", kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagItemIsDir))
        XCTAssertTrue(counts("Work/Notes/server.log", kFSEventStreamEventFlagNone))
        let filter = FileChangeFilter(folders: [chosen.path], options: FileSearchService.indexOptions())
        XCTAssertEqual(filter.firstThatMatters([
            .init(path: "/Volumes/Elsewhere/server.log", flags: FSEventStreamEventFlags(file)),
        ]), "/Volumes/Elsewhere/server.log")
    }

    func testAChosenFolderIsReadWholeWhateverHoldsIt() throws {
        // Chosen on purpose: its own markers don't make it a project, and a hidden or skipped folder above it doesn't
        // count. FSEvents reports the real path, /private/var where the chosen one says /var.
        let inner = chosen.appendingPathComponent(".hidden/node_modules/Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: inner.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated)
        let filter = FileChangeFilter(folders: [inner.path], options: FileSearchService.indexOptions())
        for spelling in [inner.path, FolderSelection.realPath(inner.path)] {
            let notes = spelling + "/notes.md"
            XCTAssertEqual(filter.firstThatMatters([.init(path: notes, flags: flags)]), notes)
            XCTAssertNil(filter.firstThatMatters([.init(path: spelling + "/server.log", flags: flags)]))
            XCTAssertNil(filter.firstThatMatters([.init(path: spelling + "/.notes.md", flags: flags)]))
        }

        // Another chosen folder can still reach what this one skips.
        let both = FileChangeFilter(folders: [chosen.path, inner.path], options: FileSearchService.indexOptions())
        XCTAssertNotNil(both.firstThatMatters([.init(path: inner.path + "/notes.md", flags: flags)]))
        XCTAssertNil(both.firstThatMatters([.init(path: chosen.path + "/node_modules/notes.md", flags: flags)]))

        // Nested folders answer separately within a batch: a project to the outer one is whole to the inner one.
        let site = chosen.appendingPathComponent("Site", isDirectory: true)
        try FileManager.default.createDirectory(at: site.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let nested = FileChangeFilter(folders: [chosen.path, site.path], options: FileSearchService.indexOptions())
        let notes = site.path + "/notes.md"
        XCTAssertEqual(nested.firstThatMatters([.init(path: notes, flags: flags)]), notes)
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

    func testOnBatteryAFoldersFirstReadWaitsForAChargerButNewFilesAreReadRightAway() async throws {
        let many = FileSearchService.newFilesLimit + 1
        for index in 0..<many {
            try write("note-\(index).txt", "Meeting note number \(index) about the spring launch plan and its budget.")
        }
        let service = makeService()
        let onBattery = BatteryFlag(true)
        service.isOnBattery = { onBattery.value }

        service.apply(.init(enabled: true, folders: [chosen.path]))
        await service.waitUntilIdle()

        XCTAssertEqual(service.state, .waitingForPower(left: many))
        XCTAssertEqual(starts, 0, "a big read on battery never loads the model")

        try write("fresh.txt", "A new file saved while on battery: the offsite moved to Lisbon.")
        service.requestPass()
        await service.waitUntilIdle()

        XCTAssertEqual(service.state, .waitingForPower(left: many))
        XCTAssertEqual(service.totals.searchable, 1)
        let fresh = await service.search("Lisbon", queryVector: nil)
        XCTAssertEqual(fresh.map(\.name), ["fresh.txt"])

        onBattery.value = false
        service.conditionsDidChange()
        await service.waitUntilIdle()

        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(service.totals.searchable, many + 1)
    }

    func testReadingOnBatteryReadsAFoldersFirstPassRightAway() async throws {
        for index in 0...FileSearchService.newFilesLimit {
            try write("note-\(index).txt", "Research note \(index) on battery chemistry and charging curves.")
        }
        let service = makeService()
        service.isOnBattery = { true }

        service.apply(.init(enabled: true, folders: [chosen.path], readsOnBattery: true))
        await service.waitUntilIdle()

        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(service.totals.searchable, FileSearchService.newFilesLimit + 1)
    }

    func testTheEstimateCountsWhatAFolderHoldsAndLeavesOutFilesAlreadyChosen() throws {
        let more = root.appendingPathComponent("More", isDirectory: true)
        try FileManager.default.createDirectory(at: more, withIntermediateDirectories: true)
        try "Packing list for the trip: passport, chargers, the blue jacket."
            .write(to: more.appendingPathComponent("packing.txt"), atomically: true, encoding: .utf8)
        try writePicture("../More/beach.png", width: 640, height: 480)
        try writePicture("../More/hills.png", width: 640, height: 480)
        try write("already.txt", "This folder is chosen already.")
        let options = FileSearchService.indexOptions()
        let costs = root.appendingPathComponent("costs", isDirectory: true)

        let estimate = FileSearchService.estimate(of: [more.path], excluding: [chosen.path], options: options,
                                                  costsFolder: costs, checksSpeed: false)

        XCTAssertEqual(estimate.files, 3)
        XCTAssertEqual(estimate.pictures, 2)
        XCTAssertEqual(estimate.documents, 1)
        XCTAssertEqual(estimate.recordings, 0)
        XCTAssertGreaterThan(estimate.seconds, 0)

        let inside = FileSearchService.estimate(of: [chosen.path], excluding: [root.path], options: options,
                                                costsFolder: costs, checksSpeed: false)
        XCTAssertEqual(inside.files, 0, "files under a chosen folder are read already")
    }

    func testTheSuggestedFoldersAreDocumentsDesktopAndDownloadsNotChosenYet() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let all = FileSearchService.suggestedFolders(excluding: [])
        try XCTSkipIf(all.isEmpty, "this account has no Documents, Desktop or Downloads folder")
        XCTAssertTrue(all.allSatisfy { ["Documents", "Desktop", "Downloads"].contains($0.name) })
        XCTAssertEqual(all.map(\.name), ["Documents", "Desktop", "Downloads"].filter { name in
            all.contains { $0.name == name }
        }, "in the order they are offered")
        XCTAssertTrue(all.allSatisfy { $0.path.hasPrefix(home + "/") })

        let first = try XCTUnwrap(all.first)
        XCTAssertFalse(FileSearchService.suggestedFolders(excluding: [first.path]).contains(first))
        XCTAssertEqual(FileSearchService.suggestedFolders(excluding: [home]), [], "a chosen home folder holds them all")
    }

    func testTheEstimateSaysWhenAFolderCannotBeOpened() {
        let missing = root.appendingPathComponent("Gone", isDirectory: true).path
        let estimate = FileSearchService.estimate(of: [missing], excluding: [], options: FileSearchService.indexOptions(),
                                                  costsFolder: root.appendingPathComponent("costs"), checksSpeed: false)
        XCTAssertEqual(estimate.unreadable, [missing])
        XCTAssertEqual(estimate.files, 0)
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

    private func makeFolder(_ name: String) throws {
        try FileManager.default.createDirectory(at: chosen.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    private func counts(_ name: String, _ flags: Int, includesMedia: Bool = true) -> Bool {
        let path = chosen.appendingPathComponent(name).path
        let filter = FileChangeFilter(folders: [chosen.path], options: FileSearchService.indexOptions(includesMedia: includesMedia))
        return filter.firstThatMatters([.init(path: path, flags: FSEventStreamEventFlags(flags))]) == path
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

private final class ReportedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    var first: String? { lock.withLock { paths.first } }

    /// How many there are now.
    func append(_ path: String) -> Int {
        lock.withLock {
            paths.append(path)
            return paths.count
        }
    }
}

private final class BatteryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool

    init(_ on: Bool) { self.on = on }

    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
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
