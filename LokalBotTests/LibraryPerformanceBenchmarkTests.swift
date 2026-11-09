import AVFoundation
import AppKit
import CryptoKit
import FluidAudio
import SQLite3
import XCTest
@testable import LokalBot

/// Opt-in timings on copies of a real library and real models. Each test is
/// skipped unless its variable is set (`TEST_RUNNER_` prefix in the runner):
/// `LOKALBOT_PERF_DB` is a copy of `lokalbotv3.sqlite`, and
/// `LOKALBOT_NEMOTRON_MODEL_DIR` a copy of the Nemotron diarization folder.
final class LibraryPerformanceBenchmarkTests: XCTestCase {
    private func libraryCopy() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_PERF_DB"], !path.isEmpty else {
            throw XCTSkip("Set LOKALBOT_PERF_DB to a copy of a library database")
        }
        return URL(fileURLWithPath: path)
    }

    /// Stored vectors serve as queries, so no embedding model runs.
    func testSemanticRetrievalTimings() throws {
        let url = try libraryCopy()
        let database = try XCTUnwrap(SQLiteDatabase(url: url, readOnly: true))
        let screenQueries = Self.vectors(in: database, table: "screen_embeddings")
        let meetingQueries = Self.vectors(in: database, table: "embeddings")
        XCTAssertFalse(screenQueries.isEmpty)

        var screenSeconds: [Double] = []
        var livenessSeconds: [Double] = []
        var screenHitCount = 0
        for query in screenQueries {
            let started = DispatchTime.now().uptimeNanoseconds
            let hits = EmbeddingIndex.screenHits(in: database, filter: .all, queryVector: query, limit: 200)
            screenSeconds.append(Self.seconds(since: started))
            screenHitCount += hits.count
            XCTAssertEqual(hits.first.map { $0.score > 0.99 }, true, "a stored vector finds itself first")
            // The app runs this check on the main actor after ranking.
            let checked = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(EmbeddingIndex.liveScreenHits(hits, in: database).count, hits.count)
            livenessSeconds.append(Self.seconds(since: checked))
        }
        var meetingSeconds: [Double] = []
        for query in meetingQueries {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = EmbeddingIndex.meetingHits(in: database, meetingIDs: nil, queryVector: query, limit: 200)
            meetingSeconds.append(Self.seconds(since: started))
        }
        print("SEMANTIC_BENCHMARK screen queries=\(screenSeconds.count) \(Self.summary(screenSeconds)) "
              + "hits=\(screenHitCount)")
        print("SEMANTIC_BENCHMARK screen-liveness \(Self.summary(livenessSeconds))")
        print("SEMANTIC_BENCHMARK meeting queries=\(meetingSeconds.count) \(Self.summary(meetingSeconds))")
    }

    /// Ask and Quick Recall's keyword screen stage (2,000 ranked hits, grouped
    /// into 41 sessions) and the Ask chat tool's grouped search (12 rows).
    func testKeywordScreenSearchTimings() throws {
        let store = ActivityStore(databaseURL: try libraryCopy(), readOnly: true)
        var recall: [Double] = []
        var chat: [Double] = []
        for _ in 0..<3 {
            for query in ["claude", "meeting", "release", "lokalbot", "search", "github", "python"] {
                let started = DispatchTime.now().uptimeNanoseconds
                let groups = store.withReadSnapshot {
                    RecallSearch.keywordScreenGroups(in: store, query: query, filter: .all)
                }
                recall.append(Self.seconds(since: started))
                XCTAssertFalse(groups.isEmpty, query)
                let chatStarted = DispatchTime.now().uptimeNanoseconds
                XCTAssertFalse(store.searchOCR(query, limit: 12).isEmpty)
                chat.append(Self.seconds(since: chatStarted))
            }
        }
        print("KEYWORD_BENCHMARK recall-screens \(Self.summary(recall))")
        print("KEYWORD_BENCHMARK chat-tool \(Self.summary(chat))")
    }

    /// The activity store and embedding index open on the main actor at
    /// launch. "upgrade" is the first open after updating (one-time schema
    /// work), "cold" a fresh file afterwards, "warm" the same file again.
    @MainActor
    func testLaunchDatabaseOpenTimings() throws {
        let source = try libraryCopy()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-benchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var url = root.appendingPathComponent("upgrade.sqlite")
        try FileManager.default.copyItem(at: source, to: url)
        for pass in ["upgrade", "cold", "warm"] {
            if pass == "cold" {
                let fresh = root.appendingPathComponent("cold.sqlite")
                try FileManager.default.copyItem(at: url, to: fresh)
                url = fresh
            }
            let started = DispatchTime.now().uptimeNanoseconds
            let store = ActivityStore(databaseURL: url)
            let storeSeconds = Self.seconds(since: started)
            let indexStarted = DispatchTime.now().uptimeNanoseconds
            let index = EmbeddingIndex(databaseURL: url, storage: StorageManager(rootURL: root),
                                       embedder: { texts, _, _ in texts.map { _ in [] } })
            let indexSeconds = Self.seconds(since: indexStarted)
            withExtendedLifetime((store, index)) {}
            print(String(format: "LAUNCH_DB_BENCHMARK pass=%@ activityStore=%.1fms embeddingIndex=%.1fms",
                         pass, storeSeconds * 1000, indexSeconds * 1000))
        }
    }

    /// Screen capture processing for one window's frames that differ only
    /// by a blinking caret, with real hashing and HEIC encoding.
    func testCaptureProcessingTimings() async throws {
        _ = try libraryCopy()
        let frames = [try XCTUnwrap(SyntheticWindowImage.make(caret: true)),
                      try XCTUnwrap(SyntheticWindowImage.make(caret: false))]
        let worker = ScreenshotProcessingWorker()
        let key = SymmetricKey(size: .bits256)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).heic.enc")
        let text = String(repeating: "Quarterly planning notes for the design review. ", count: 4)
        var seconds: [Double] = []
        var stored = 0
        for index in 0..<20 {
            let started = DispatchTime.now().uptimeNanoseconds
            let outcome = try await worker.process(ScreenshotProcessingRequest(
                image: frames[index % 2], trigger: .typingPause, key: key, fileURL: url,
                accessibleText: text, stageOnly: true, source: "Notes\u{1f}Plan"))
            seconds.append(Self.seconds(since: started))
            if case .stored = outcome { stored += 1 }
        }
        var hashSeconds: [Double] = []
        for _ in 0..<20 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = ScreenshotImageProcessing.contentHash(of: frames[0])
            hashSeconds.append(Self.seconds(since: started))
        }
        print(String(format: "CAPTURE_BENCHMARK frames=20 stored=%d total=%.0fms ", stored, seconds.reduce(0, +) * 1000)
              + Self.summary(seconds) + " contentHash " + Self.summary(hashSeconds))
    }

    /// One autocomplete reread of an unchanged window: text recognition
    /// before, the image fingerprint after.
    func testWindowTextRereadTimings() async throws {
        _ = try libraryCopy()
        let image = try XCTUnwrap(SyntheticWindowImage.rendered())
        let window = CGRect(x: 0, y: 0, width: 750, height: 500)
        // The first recognition loads Vision's models.
        _ = await CotypingWindowTextCapture.recognizeLines(in: image, windowFrame: window)
        var recognition: [Double] = []
        var lineCount = 0
        for _ in 0..<5 {
            let started = DispatchTime.now().uptimeNanoseconds
            lineCount = await CotypingWindowTextCapture.recognizeLines(in: image, windowFrame: window).count
            recognition.append(Self.seconds(since: started))
        }
        print("WINDOW_TEXT_BENCHMARK recognition lines=\(lineCount) \(Self.summary(recognition))")
    }

    /// What an unchanged reread costs now: fingerprinting the window image.
    func testWindowTextFingerprintTimings() throws {
        _ = try libraryCopy()
        let image = try XCTUnwrap(SyntheticWindowImage.rendered())
        let window = CGRect(x: 0, y: 0, width: 750, height: 500)
        let field = CGRect(x: 40, y: 440, width: 600, height: 40)
        var seconds: [Double] = []
        for _ in 0..<20 {
            let started = DispatchTime.now().uptimeNanoseconds
            XCTAssertNotNil(CotypingWindowText.fingerprint(of: image, windowFrame: window, fieldFrame: field))
            seconds.append(Self.seconds(since: started))
        }
        print("WINDOW_TEXT_BENCHMARK fingerprint \(Self.summary(seconds))")
    }

    /// One day of expired captures, cleared the way the daily retention pass
    /// does on the main actor.
    func testRetentionPathClearTimings() throws {
        let source = try libraryCopy()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-benchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lokalbotv3.sqlite")
        try FileManager.default.copyItem(at: source, to: url)
        let opened = DispatchTime.now().uptimeNanoseconds
        let store = ActivityStore(databaseURL: url)
        let openSeconds = Self.seconds(since: opened)
        let reader = try XCTUnwrap(SQLiteDatabase(url: url, readOnly: true))
        let paths: [String] = reader.query(
            "SELECT path FROM screenshots WHERE path != '' ORDER BY ts LIMIT 900") { statement in
            sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        XCTAssertEqual(paths.count, 900)
        var seconds: [Double] = []
        for path in paths {
            let started = DispatchTime.now().uptimeNanoseconds
            try store.clearScreenshotPath(path)
            seconds.append(Self.seconds(since: started))
        }
        XCTAssertFalse(reader.hasRow("SELECT 1 FROM screenshots WHERE path = ?1", bind: [paths[0]]))
        print(String(format: "RETENTION_BENCHMARK clears=%d total=%.0fms ", seconds.count, seconds.reduce(0, +) * 1000)
              + Self.summary(seconds) + String(format: " storeOpen=%.0fms", openSeconds * 1000))
    }

    /// Memory the Nemotron speaker model holds while loaded, and whether the
    /// engine releases it once processing has been idle.
    func testDiarizationModelMemoryIsReleasedWhenIdle() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_NEMOTRON_MODEL_DIR"], !path.isEmpty else {
            throw XCTSkip("Set LOKALBOT_NEMOTRON_MODEL_DIR to a copy of the Nemotron diarization folder")
        }
        let directory = URL(fileURLWithPath: path)
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("diarization-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        try Self.writeTone(to: audio, seconds: 20)
        let engine = NeuralDiarizationEngine(idleSeconds: 3, communityLoader: {
            throw CocoaError(.fileNoSuchFile)
        }, nemotronLoader: {
            try await Nemotron3Models.load(config: .offline, directory: directory)
        })
        let baseline = Self.footprint()
        _ = try await engine.diarizeDetailed(url: audio, model: .nemotron3, includeVoiceSamples: false)
        let loaded = Self.footprint()
        let heldAfterUse = await engine.hasLoadedModels
        XCTAssertTrue(heldAfterUse)
        try await Task.sleep(for: .seconds(6))
        let heldAfterIdle = await engine.hasLoadedModels
        XCTAssertFalse(heldAfterIdle, "the engine releases its models after the idle period")
        let released = Self.footprint()
        print(String(format: "DIARIZATION_MEMORY_BENCHMARK baseline=%.0fMB loaded=%.0fMB afterIdle=%.0fMB",
                     baseline, loaded, released))
    }

    /// Twenty stored vectors spread across the table.
    private static func vectors(in database: SQLiteDatabase, table: String) -> [[Float]] {
        database.query("SELECT vec FROM \(table) WHERE rowid % 97 = 0 LIMIT 20") { statement in
            guard let blob = sqlite3_column_blob(statement, 0) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, 0)) / MemoryLayout<Float>.stride
            return Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: count))
        }
    }

    private static func writeTone(to url: URL, seconds: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = 0.1 * sin(2 * .pi * 220 * Float(index) / 16_000)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// Physical footprint in MB, as Activity Monitor reports it.
    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    private static func summary(_ seconds: [Double]) -> String {
        let sorted = seconds.sorted()
        guard !sorted.isEmpty else { return "empty" }
        let median = sorted[sorted.count / 2] * 1000
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))] * 1000
        return String(format: "median=%.2fms p90=%.2fms", median, p90)
    }
}

/// A light window with dark text lines and an optional text caret, the way
/// an editor looks between two blinks.
enum SyntheticWindowImage {
    static func make(width: Int = 1_500, height: Int = 1_000, caret: Bool, lineCount: Int = 12) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        for line in 0..<lineCount {
            var x = 60
            let y = height - 80 - line * 60
            for word in 0..<14 {
                let length = 30 + (line * 7 + word * 13) % 70
                context.fill(CGRect(x: x, y: y, width: length, height: 18))
                x += length + 14
            }
        }
        if caret {
            context.fill(CGRect(x: 640, y: height - 80 - lineCount * 60, width: 2, height: 22))
        }
        return context.makeImage()
    }

    /// A 1,500 × 1,000 window of real text lines, as text recognition sees one.
    static func rendered(width: Int = 1_500, height: Int = 1_000) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26),
                                                         .foregroundColor: NSColor.black]
        for line in 0..<22 {
            let text = "Line \(line + 1): the design review moved to Thursday; budget notes and launch checklist"
            NSAttributedString(string: text, attributes: attributes)
                .draw(at: CGPoint(x: 40, y: height - 60 - line * 42))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
