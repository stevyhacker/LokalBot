import Foundation
import SQLite3

/// Persists the post-meeting processing queue in lokalbotv3.sqlite so a crash,
/// force-quit, or reboot mid-transcription doesn't silently drop the job — the
/// in-memory queue in `ProcessingPipeline` used to be the only record of what
/// still needed processing.
///
/// Own connection to the shared database file, same pattern as `SearchIndex` /
/// `ActivityStore` / `EmbeddingIndex`. A row lives for the duration of a job:
/// inserted on enqueue, deleted on success. `attempts` counts processing
/// *starts* (not failures), so a job that crashes the app mid-flight still
/// burns an attempt and a poison-pill meeting can't crash-loop launch resume
/// forever.
final class PipelineJobStore {

    struct PendingJob: Equatable {
        let meetingID: UUID
        let transcribe: Bool
        /// True only after this durable job committed its requested transcript.
        /// A transcript left by an older job does not satisfy this phase.
        let transcriptionCompleted: Bool
        let summarize: Bool
        /// Automatic summary intent follows the current setting when a job is
        /// restored. Explicit toolbar/headless intent survives unchanged.
        let summaryFollowsSetting: Bool
        let attempts: Int
    }

    /// Launch auto-resume gives up after this many processing starts; an
    /// explicit user re-enqueue resets the counter and tries again.
    static let maxAutoResumeAttempts = 3

    private let database: SQLiteDatabase?
    private let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
        database = SQLiteDatabase(url: databaseURL)
        do {
            let database = try requiredDatabase()
            try database.execute("""
                CREATE TABLE IF NOT EXISTS pipeline_jobs (
                    meeting_id TEXT PRIMARY KEY,
                    transcribe INTEGER NOT NULL,
                    transcription_completed INTEGER NOT NULL DEFAULT 0,
                    summarize INTEGER NOT NULL,
                    summary_follows_setting INTEGER NOT NULL DEFAULT 1,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    enqueued_at REAL NOT NULL
                );
                """)
            let columns: [String] = try database.queryChecked(
                "PRAGMA table_info(pipeline_jobs)") { statement in
                sqlite3_column_text(statement, 1).map { String(cString: $0) }
            }
            if !columns.contains("last_error") {
                try database.runChecked(
                    "ALTER TABLE pipeline_jobs ADD COLUMN last_error TEXT")
            }
            if !columns.contains("summary_follows_setting") {
                // Rows written by older builds had no provenance. Treat their
                // summary bit as automatic so a current opt-out takes effect.
                try database.runChecked(
                    "ALTER TABLE pipeline_jobs ADD COLUMN "
                        + "summary_follows_setting INTEGER NOT NULL DEFAULT 1")
            }
            if !columns.contains("transcription_completed") {
                // An older row cannot prove that this job produced the
                // transcript currently on disk. Conservatively resume ASR.
                try database.runChecked(
                    "ALTER TABLE pipeline_jobs ADD COLUMN "
                        + "transcription_completed INTEGER NOT NULL DEFAULT 0")
            }
        } catch {
            lokalbotLog("pipeline queue initialization failed: \(error.localizedDescription)")
        }
    }

    private func requiredDatabase() throws -> SQLiteDatabase {
        guard let database else {
            throw SQLiteDatabase.DatabaseError.unavailable(path: databaseURL.path)
        }
        return database
    }

    /// Record a fresh enqueue. Resets `attempts`: an explicit re-enqueue is a
    /// deliberate retry, not a crash-loop continuation.
    @discardableResult
    func enqueue(meetingID: UUID, transcribe: Bool, summarize: Bool,
                 summaryFollowsSetting: Bool = false,
                 at date: Date = Date()) -> Bool {
        write("enqueue") { database in
            try database.runChecked("""
                INSERT INTO pipeline_jobs (
                    meeting_id, transcribe, transcription_completed, summarize,
                    summary_follows_setting, attempts, enqueued_at
                )
                VALUES (?1, ?2, 0, ?3, ?4, 0, ?5)
                ON CONFLICT(meeting_id) DO UPDATE SET
                    transcribe = excluded.transcribe,
                    transcription_completed = 0,
                    summarize = excluded.summarize,
                    summary_follows_setting = excluded.summary_follows_setting,
                    attempts = 0,
                    last_error = NULL,
                    enqueued_at = excluded.enqueued_at
                """, bind: [
                    meetingID.uuidString,
                    transcribe ? 1 : 0,
                    summarize ? 1 : 0,
                    summaryFollowsSetting ? 1 : 0,
                    date.timeIntervalSince1970
                ])
        }
    }

    /// Update a job that is already running without resetting its crash-loop
    /// attempt count. This makes an active toolbar choice durable if the app
    /// quits before the current transcription reaches the summary boundary.
    @discardableResult
    func updateIntent(meetingID: UUID, transcribe: Bool, summarize: Bool,
                      summaryFollowsSetting: Bool) -> Bool {
        write("update intent") { database in
            try database.runChecked("""
                UPDATE pipeline_jobs SET
                    transcribe = ?2,
                    transcription_completed = CASE
                        WHEN ?2 != 0 THEN 0
                        ELSE transcription_completed
                    END,
                    summarize = ?3,
                    summary_follows_setting = ?4
                WHERE meeting_id = ?1
                """, bind: [
                    meetingID.uuidString,
                    transcribe ? 1 : 0,
                    summarize ? 1 : 0,
                    summaryFollowsSetting ? 1 : 0
                ])
        }
    }

    /// Burn one attempt the moment processing starts, so a crash mid-job is
    /// already counted when the row is read back on the next launch.
    @discardableResult
    func markStarted(meetingID: UUID) -> Bool {
        write("mark started") { database in
            try database.runChecked(
                "UPDATE pipeline_jobs SET attempts = attempts + 1 WHERE meeting_id = ?1",
                bind: [meetingID.uuidString])
        }
    }

    /// Persist the transcription phase immediately after the transcript
    /// commit. Crash recovery must use this marker rather than the existence of
    /// a transcript that may predate the current request.
    @discardableResult
    func markTranscriptionCompleted(meetingID: UUID) -> Bool {
        write("mark transcription completed") { database in
            try database.runChecked(
                "UPDATE pipeline_jobs SET transcription_completed = 1 WHERE meeting_id = ?1",
                bind: [meetingID.uuidString])
        }
    }

    @discardableResult
    func markCompleted(meetingID: UUID) -> Bool {
        write("mark completed") { database in
            try database.runChecked(
                "DELETE FROM pipeline_jobs WHERE meeting_id = ?1",
                bind: [meetingID.uuidString])
        }
    }

    /// Persist why the last processing attempt failed, so a job that ends up
    /// parked (attempts exhausted) can still explain itself after a relaunch.
    @discardableResult
    func markFailed(meetingID: UUID, message: String) -> Bool {
        write("mark failed") { database in
            try database.runChecked(
                "UPDATE pipeline_jobs SET last_error = ?2 WHERE meeting_id = ?1",
                bind: [meetingID.uuidString, message])
        }
    }

    struct ParkedJob {
        let meetingID: UUID
        let lastError: String?
    }

    /// Jobs that burned through the auto-resume attempt cap. They never
    /// re-enter the launch queue, but the UI surfaces them as failed rows so
    /// the user can retry explicitly.
    func parkedJobs() -> [ParkedJob] {
        do {
            return try requiredDatabase().queryChecked("""
                SELECT meeting_id, last_error FROM pipeline_jobs
                WHERE attempts >= ?1 ORDER BY enqueued_at
                """, bind: [Self.maxAutoResumeAttempts]) { statement -> ParkedJob? in
                guard let text = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: text)) else { return nil }
                let message = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                return ParkedJob(meetingID: id, lastError: message)
            }
        } catch {
            lokalbotLog("pipeline queue parked read failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Jobs eligible for launch auto-resume, oldest first.
    func pendingJobs() -> [PendingJob] {
        do {
            return try requiredDatabase().queryChecked("""
                SELECT meeting_id, transcribe, summarize,
                       summary_follows_setting, attempts, transcription_completed
                FROM pipeline_jobs
                WHERE attempts < ?1 ORDER BY enqueued_at
                """, bind: [Self.maxAutoResumeAttempts]) { statement -> PendingJob? in
                guard let text = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: text)) else { return nil }
                return PendingJob(meetingID: id,
                                  transcribe: sqlite3_column_int64(statement, 1) != 0,
                                  transcriptionCompleted:
                                      sqlite3_column_int64(statement, 5) != 0,
                                  summarize: sqlite3_column_int64(statement, 2) != 0,
                                  summaryFollowsSetting:
                                      sqlite3_column_int64(statement, 3) != 0,
                                  attempts: Int(sqlite3_column_int64(statement, 4)))
            }
        } catch {
            lokalbotLog("pipeline queue read failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Read one durable intent regardless of its automatic-resume attempt
    /// count. An explicit Retry must recover even a parked job's exact scope
    /// before `enqueue` resets that row.
    func job(meetingID: UUID) -> PendingJob? {
        do {
            return try requiredDatabase().queryChecked("""
                SELECT meeting_id, transcribe, summarize,
                       summary_follows_setting, attempts, transcription_completed
                FROM pipeline_jobs
                WHERE meeting_id = ?1
                LIMIT 1
                """, bind: [meetingID.uuidString]) { statement -> PendingJob? in
                guard let text = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: text)) else { return nil }
                return PendingJob(
                    meetingID: id,
                    transcribe: sqlite3_column_int64(statement, 1) != 0,
                    transcriptionCompleted: sqlite3_column_int64(statement, 5) != 0,
                    summarize: sqlite3_column_int64(statement, 2) != 0,
                    summaryFollowsSetting: sqlite3_column_int64(statement, 3) != 0,
                    attempts: Int(sqlite3_column_int64(statement, 4)))
            }.first
        } catch {
            lokalbotLog("pipeline queue job read failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Drop rows whose meeting no longer exists (deleted from the library
    /// between the crash and this launch).
    @discardableResult
    func prune(existing meetingIDs: Set<UUID>) -> Bool {
        do {
            let database = try requiredDatabase()
            let rows = try database.queryChecked(
                "SELECT meeting_id FROM pipeline_jobs") { statement -> String? in
                sqlite3_column_text(statement, 0).map { String(cString: $0) }
            }
            let staleIDs = rows.filter {
                UUID(uuidString: $0).map { !meetingIDs.contains($0) } ?? true
            }
            try database.withTransaction {
                for id in staleIDs {
                    try database.runChecked(
                        "DELETE FROM pipeline_jobs WHERE meeting_id = ?1", bind: [id])
                }
            }
            return true
        } catch {
            lokalbotLog("pipeline queue prune failed: \(error.localizedDescription)")
            return false
        }
    }

    private func write(_ operation: String,
                       body: (SQLiteDatabase) throws -> Void) -> Bool {
        do {
            try body(requiredDatabase())
            return true
        } catch {
            lokalbotLog("pipeline queue \(operation) failed: \(error.localizedDescription)")
            return false
        }
    }
}
