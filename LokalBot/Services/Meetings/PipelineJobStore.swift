import Foundation
import SQLite3

final class PipelineJobStore {

    struct PendingJob: Equatable {
        let meetingID: UUID
        let transcribe: Bool
        let transcriptionCompleted: Bool
        let summarize: Bool
        let summaryFollowsSetting: Bool
        let attempts: Int
    }

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
                try database.runChecked(
                    "ALTER TABLE pipeline_jobs ADD COLUMN "
                        + "summary_follows_setting INTEGER NOT NULL DEFAULT 1")
            }
            if !columns.contains("transcription_completed") {
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

    @discardableResult
    func markStarted(meetingID: UUID) -> Bool {
        write("mark started") { database in
            try database.runChecked(
                "UPDATE pipeline_jobs SET attempts = attempts + 1 WHERE meeting_id = ?1",
                bind: [meetingID.uuidString])
        }
    }

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
