import XCTest
@testable import LokalBot

@MainActor
final class ProcessingPipelineModelPreparationTests: XCTestCase {

    func testMeetingRowStageLabelsStayCompact() {
        XCTAssertEqual(ProcessingPipeline.Stage.queued.rowLabel, "Queued")
        XCTAssertEqual(
            ProcessingPipeline.Stage.preparingTranscriptionModel.rowLabel,
            "Preparing speech model")
        XCTAssertEqual(ProcessingPipeline.Stage.diarizing.rowLabel, "Identifying speakers")
        XCTAssertEqual(ProcessingPipeline.Stage.failed("network").rowLabel, "Failed")
        XCTAssertTrue(ProcessingPipeline.Stage.failed("network").isFailure)
        XCTAssertFalse(ProcessingPipeline.Stage.summarizing.isFailure)
    }
    func testFirstBuiltInSummaryPreparesMissingSelectedModel() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let storage = StorageManager(rootURL: root)
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn
        settings.builtInModelID = ModelCatalog.compactFallbackID
        var preparationCount = 0
        let pipeline = ProcessingPipeline(
            storage: storage,
            settings: { settings },
            builtInModelPreparer: { entry, storage in
                let url = storage.rootURL.appendingPathComponent("models/\(entry.fileName)")
                if ModelFileValidator.looksLikeGGUF(url) { return url }
                preparationCount += 1
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("GGUF".utf8).write(to: url)
                return url
            })

        _ = try await pipeline.thinkExecution.makeTextEngine(settings)
        _ = try await pipeline.thinkExecution.makeTextEngine(settings)

        XCTAssertEqual(preparationCount, 1,
                       "first use downloads once; later summaries reuse the validated model")
        let entry = try XCTUnwrap(ModelCatalog.entry(id: settings.builtInModelID))
        XCTAssertNotNil(ModelCatalog.localURL(for: entry, storage: storage))
    }

    func testResumePendingSurfacesParkedJobsAsFailedStages() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let storage = StorageManager(rootURL: root)
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let meeting = Meeting(id: UUID(), title: "Standup", appName: "Zoom",
                              startedAt: Date(), endedAt: Date(),
                              relativePath: "meetings/2026/07/17-standup")
        jobStore.enqueue(meetingID: meeting.id, transcribe: true, summarize: true)
        for _ in 0..<PipelineJobStore.maxAutoResumeAttempts {
            jobStore.markStarted(meetingID: meeting.id)
        }
        jobStore.markFailed(meetingID: meeting.id,
                            message: "The selected model is not downloaded.")

        let pipeline = ProcessingPipeline(storage: storage, jobStore: jobStore) {
            AppSettings()
        }
        pipeline.resumePending(meetings: [meeting])

        guard case .failed(let message)? = pipeline.stages[meeting.id] else {
            return XCTFail("parked job did not surface as a failed stage")
        }
        XCTAssertEqual(message, "The selected model is not downloaded.")
    }

    func testResumePendingParkedFallbackMessageWhenNoneRecorded() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let storage = StorageManager(rootURL: root)
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let meeting = Meeting(id: UUID(), title: "Standup", appName: "Zoom",
                              startedAt: Date(), endedAt: Date(),
                              relativePath: "meetings/2026/07/17-standup")
        jobStore.enqueue(meetingID: meeting.id, transcribe: true, summarize: true)
        for _ in 0..<PipelineJobStore.maxAutoResumeAttempts {
            jobStore.markStarted(meetingID: meeting.id)
        }

        let pipeline = ProcessingPipeline(storage: storage, jobStore: jobStore) {
            AppSettings()
        }
        pipeline.resumePending(meetings: [meeting])

        guard case .failed(let message)? = pipeline.stages[meeting.id] else {
            return XCTFail("parked job without a recorded error did not surface")
        }
        XCTAssertEqual(message, "Processing didn't finish after several attempts.")
    }
}
