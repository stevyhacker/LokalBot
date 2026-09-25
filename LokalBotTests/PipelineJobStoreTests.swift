import XCTest
@testable import LokalBot

final class PipelineJobStoreTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineJobStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        databaseURL = dir.appendingPathComponent("test.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    private func makeStore() -> PipelineJobStore {
        PipelineJobStore(databaseURL: databaseURL)
    }

    func testEnqueuedJobIsPendingWithItsFlags() {
        let store = makeStore()
        let id = UUID()

        store.enqueue(meetingID: id, transcribe: true, summarize: false)

        let pending = store.pendingJobs()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.meetingID, id)
        XCTAssertEqual(pending.first?.transcribe, true)
        XCTAssertEqual(pending.first?.transcriptionCompleted, false)
        XCTAssertEqual(pending.first?.summarize, false)
        XCTAssertEqual(pending.first?.summaryFollowsSetting, false)
        XCTAssertEqual(pending.first?.attempts, 0)
    }

    func testAutomaticSummaryPolicyIsPersisted() {
        let store = makeStore()
        let id = UUID()

        store.enqueue(
            meetingID: id,
            transcribe: true,
            summarize: true,
            summaryFollowsSetting: true)

        XCTAssertEqual(store.pendingJobs().first?.summaryFollowsSetting, true)
    }

    func testUpdatingActiveIntentDoesNotResetAttempts() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(
            meetingID: id,
            transcribe: true,
            summarize: true,
            summaryFollowsSetting: true)
        store.markStarted(meetingID: id)

        store.updateIntent(
            meetingID: id,
            transcribe: true,
            summarize: false,
            summaryFollowsSetting: false)

        let pending = store.pendingJobs().first
        XCTAssertEqual(pending?.attempts, 1)
        XCTAssertEqual(pending?.summarize, false)
        XCTAssertEqual(pending?.summaryFollowsSetting, false)
    }

    func testLegacyRowsFollowCurrentSummarySettingAfterSchemaMigration() throws {
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        try database.execute("""
            CREATE TABLE pipeline_jobs (
                meeting_id TEXT PRIMARY KEY,
                transcribe INTEGER NOT NULL,
                summarize INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                enqueued_at REAL NOT NULL
            );
            """)
        let id = UUID()
        try database.runChecked("""
            INSERT INTO pipeline_jobs (
                meeting_id, transcribe, summarize, attempts, enqueued_at
            ) VALUES (?1, 1, 1, 0, 1)
            """, bind: [id.uuidString])

        let pending = makeStore().pendingJobs().first

        XCTAssertEqual(pending?.meetingID, id)
        XCTAssertEqual(pending?.summaryFollowsSetting, true)
        XCTAssertEqual(pending?.transcriptionCompleted, false,
                       "legacy rows must conservatively redo requested ASR")
    }

    func testTranscriptionPhasePersistsAndFreshASRResetsIt() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(meetingID: id, transcribe: true, summarize: true)

        XCTAssertTrue(store.markTranscriptionCompleted(meetingID: id))
        XCTAssertEqual(makeStore().job(meetingID: id)?.transcriptionCompleted, true)

        store.enqueue(meetingID: id, transcribe: true, summarize: false)
        XCTAssertEqual(store.job(meetingID: id)?.transcriptionCompleted, false)
    }

    func testCompletedJobIsRemoved() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(meetingID: id, transcribe: true, summarize: true)

        store.markCompleted(meetingID: id)

        XCTAssertTrue(store.pendingJobs().isEmpty)
    }

    /// A crash mid-processing leaves the row with its attempt already burned,
    /// and once the cap is reached the job stops auto-resuming — a meeting
    /// that reliably kills the app must not crash-loop every launch.
    func testJobStopsResumingAfterAttemptCap() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(meetingID: id, transcribe: true, summarize: true)

        for attempt in 1...PipelineJobStore.maxAutoResumeAttempts {
            XCTAssertEqual(store.pendingJobs().count, 1, "attempt \(attempt) should still resume")
            store.markStarted(meetingID: id)
        }

        XCTAssertTrue(store.pendingJobs().isEmpty)
    }

    func testExactJobIntentRemainsReadableAfterAttemptCap() throws {
        let store = makeStore()
        let id = UUID()
        store.enqueue(
            meetingID: id,
            transcribe: true,
            summarize: true,
            summaryFollowsSetting: false)
        for _ in 0..<PipelineJobStore.maxAutoResumeAttempts {
            store.markStarted(meetingID: id)
        }

        let job = try XCTUnwrap(store.job(meetingID: id))

        XCTAssertEqual(job.meetingID, id)
        XCTAssertTrue(job.transcribe)
        XCTAssertTrue(job.summarize)
        XCTAssertFalse(job.summaryFollowsSetting)
        XCTAssertEqual(job.attempts, PipelineJobStore.maxAutoResumeAttempts)
    }

    /// An explicit user retry is a fresh decision — it resets the crash-loop
    /// counter instead of staying parked forever.
    func testExplicitReenqueueResetsAttempts() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(meetingID: id, transcribe: true, summarize: true)
        for _ in 1...PipelineJobStore.maxAutoResumeAttempts {
            store.markStarted(meetingID: id)
        }
        XCTAssertTrue(store.pendingJobs().isEmpty)

        store.enqueue(meetingID: id, transcribe: false, summarize: true)

        let pending = store.pendingJobs()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attempts, 0)
        XCTAssertEqual(pending.first?.transcribe, false)
        XCTAssertEqual(pending.first?.summarize, true)
    }

    func testPendingJobsAreOldestFirst() {
        let store = makeStore()
        let first = UUID(), second = UUID()
        store.enqueue(meetingID: second, transcribe: true, summarize: true,
                      at: Date(timeIntervalSince1970: 2_000))
        store.enqueue(meetingID: first, transcribe: true, summarize: true,
                      at: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(store.pendingJobs().map(\.meetingID), [first, second])
    }

    func testPruneDropsJobsForDeletedMeetings() {
        let store = makeStore()
        let kept = UUID(), deleted = UUID()
        store.enqueue(meetingID: kept, transcribe: true, summarize: true)
        store.enqueue(meetingID: deleted, transcribe: true, summarize: true)

        store.prune(existing: [kept])

        XCTAssertEqual(store.pendingJobs().map(\.meetingID), [kept])
    }

    /// The queue survives the connection — a new store over the same file
    /// (i.e. the next app launch) sees the unfinished job.
    func testJobsSurviveReopen() {
        let id = UUID()
        makeStore().enqueue(meetingID: id, transcribe: true, summarize: true)

        XCTAssertEqual(makeStore().pendingJobs().first?.meetingID, id)
    }

    func testEnqueueReportsUnavailableDatabaseInsteadOfSilentlyDroppingJob() {
        let missingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let store = PipelineJobStore(
            databaseURL: missingParent.appendingPathComponent("test.sqlite"))

        XCTAssertFalse(store.enqueue(
            meetingID: UUID(), transcribe: true, summarize: true))
        XCTAssertTrue(store.pendingJobs().isEmpty)
    }

    func testMarkFailedSurfacesParkedJobWithMessage() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(meetingID: id, transcribe: true, summarize: true)
        for _ in 0..<PipelineJobStore.maxAutoResumeAttempts {
            store.markStarted(meetingID: id)
        }
        store.markFailed(meetingID: id, message: "The selected model is not downloaded.")

        XCTAssertTrue(store.pendingJobs().isEmpty,
                      "a parked job must stay out of the auto-resume queue")
        let parked = store.parkedJobs()
        XCTAssertEqual(parked.count, 1)
        XCTAssertEqual(parked.first?.meetingID, id)
        XCTAssertEqual(parked.first?.lastError, "The selected model is not downloaded.")
    }

    func testParkedJobsExcludeJobsWithRemainingAttempts() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(meetingID: id, transcribe: true, summarize: true)
        store.markStarted(meetingID: id)
        store.markFailed(meetingID: id, message: "transient")

        XCTAssertTrue(store.parkedJobs().isEmpty,
                      "a job with attempts left auto-resumes; it is not parked")
        XCTAssertEqual(store.pendingJobs().count, 1)
    }

    func testEnqueueClearsLastError() {
        let store = makeStore()
        let id = UUID()
        store.enqueue(meetingID: id, transcribe: true, summarize: true)
        for _ in 0..<PipelineJobStore.maxAutoResumeAttempts {
            store.markStarted(meetingID: id)
        }
        store.markFailed(meetingID: id, message: "old failure")
        store.enqueue(meetingID: id, transcribe: true, summarize: true)

        XCTAssertTrue(store.parkedJobs().isEmpty,
                      "an explicit retry resets attempts, so nothing is parked")
        for _ in 0..<PipelineJobStore.maxAutoResumeAttempts {
            store.markStarted(meetingID: id)
        }
        XCTAssertEqual(store.parkedJobs().count, 1,
                       "re-exhausting attempts must park the job again")
        XCTAssertEqual(store.parkedJobs().first?.lastError, nil,
                       "an explicit retry must clear the stale failure message")
    }
}
