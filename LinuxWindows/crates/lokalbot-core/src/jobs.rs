//! The durable post-meeting processing queue (`PipelineJobStore.swift`):
//! a row per job, deleted on success; `attempts` counts starts so a meeting
//! that crashes processing cannot loop forever on launch.

use anyhow::Result;
use rusqlite::params;
use uuid::Uuid;

use crate::library::Library;

/// Launch auto-resume gives up after this many starts.
pub const MAX_AUTO_RESUME_ATTEMPTS: u32 = 3;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PipelineJob {
    pub meeting_id: Uuid,
    pub transcribe: bool,
    /// True only after this job committed its transcript.
    pub transcription_completed: bool,
    pub summarize: bool,
    pub attempts: u32,
    pub last_error: Option<String>,
}

const COLUMNS: &str =
    "meeting_id, transcribe, transcription_completed, summarize, attempts, last_error";

fn job_from_row(row: &rusqlite::Row) -> rusqlite::Result<Option<PipelineJob>> {
    let id: String = row.get(0)?;
    let Ok(meeting_id) = Uuid::parse_str(&id) else {
        return Ok(None);
    };
    Ok(Some(PipelineJob {
        meeting_id,
        transcribe: row.get::<_, i64>(1)? != 0,
        transcription_completed: row.get::<_, i64>(2)? != 0,
        summarize: row.get::<_, i64>(3)? != 0,
        attempts: row.get::<_, i64>(4)?.max(0) as u32,
        last_error: row.get(5)?,
    }))
}

impl Library {
    /// Records a job. A user-initiated enqueue is a deliberate retry: it
    /// resets `attempts` and the last error. An automatic one keeps the
    /// attempt count of an existing row and lets the summary follow the
    /// current setting when the job is restored.
    pub fn enqueue_job(
        &self,
        meeting_id: Uuid,
        transcribe: bool,
        summarize: bool,
        user_initiated: bool,
    ) -> Result<()> {
        let id = crate::ids::uuid_upper(&meeting_id);
        let now = crate::time::to_epoch(chrono::Utc::now());
        self.with_db(|db| {
            let sql = if user_initiated {
                "INSERT INTO pipeline_jobs (meeting_id, transcribe, transcription_completed, summarize, \
                 summary_follows_setting, attempts, enqueued_at) VALUES (?1, ?2, 0, ?3, ?4, 0, ?5) \
                 ON CONFLICT(meeting_id) DO UPDATE SET transcribe = excluded.transcribe, transcription_completed = 0, \
                 summarize = excluded.summarize, summary_follows_setting = excluded.summary_follows_setting, \
                 attempts = 0, last_error = NULL, enqueued_at = excluded.enqueued_at"
            } else {
                "INSERT INTO pipeline_jobs (meeting_id, transcribe, transcription_completed, summarize, \
                 summary_follows_setting, attempts, enqueued_at) VALUES (?1, ?2, 0, ?3, ?4, 0, ?5) \
                 ON CONFLICT(meeting_id) DO UPDATE SET transcribe = excluded.transcribe, \
                 transcription_completed = CASE WHEN excluded.transcribe != 0 THEN 0 ELSE transcription_completed END, \
                 summarize = excluded.summarize, summary_follows_setting = excluded.summary_follows_setting"
            };
            db.execute(sql, params![id, transcribe as i64, summarize as i64, (!user_initiated) as i64, now])?;
            Ok(())
        })
    }

    /// Jobs eligible for launch auto-resume, oldest first.
    pub fn pending_jobs(&self) -> Result<Vec<PipelineJob>> {
        self.query_jobs("attempts < ?1", MAX_AUTO_RESUME_ATTEMPTS)
    }

    /// Jobs that used up their automatic attempts; shown as failed rows.
    pub fn parked_jobs(&self) -> Result<Vec<PipelineJob>> {
        self.query_jobs("attempts >= ?1", MAX_AUTO_RESUME_ATTEMPTS)
    }

    /// One job regardless of its attempts.
    pub fn job(&self, meeting_id: Uuid) -> Result<Option<PipelineJob>> {
        let id = crate::ids::uuid_upper(&meeting_id);
        self.with_db(|db| {
            if !crate::timeline::table_exists(db, "pipeline_jobs")? {
                return Ok(None);
            }
            let mut statement = db.prepare(&format!(
                "SELECT {COLUMNS} FROM pipeline_jobs WHERE meeting_id = ?1"
            ))?;
            let mut rows = statement.query([id])?;
            match rows.next()? {
                Some(row) => Ok(job_from_row(row)?),
                None => Ok(None),
            }
        })
    }

    fn query_jobs(&self, condition: &str, attempts: u32) -> Result<Vec<PipelineJob>> {
        self.with_db(|db| {
            if !crate::timeline::table_exists(db, "pipeline_jobs")? {
                return Ok(Vec::new());
            }
            let mut statement = db.prepare(&format!(
                "SELECT {COLUMNS} FROM pipeline_jobs WHERE {condition} ORDER BY enqueued_at"
            ))?;
            let rows = statement.query_map([attempts], job_from_row)?;
            Ok(rows
                .filter_map(|r| r.transpose())
                .collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    /// Burns one attempt as processing starts.
    pub fn mark_job_started(&self, meeting_id: Uuid) -> Result<()> {
        self.update_job(
            "UPDATE pipeline_jobs SET attempts = attempts + 1 WHERE meeting_id = ?1",
            meeting_id,
        )
    }

    pub fn mark_transcription_completed(&self, meeting_id: Uuid) -> Result<()> {
        self.update_job(
            "UPDATE pipeline_jobs SET transcription_completed = 1 WHERE meeting_id = ?1",
            meeting_id,
        )
    }

    /// Deletes the finished job.
    pub fn mark_job_completed(&self, meeting_id: Uuid) -> Result<()> {
        self.update_job(
            "DELETE FROM pipeline_jobs WHERE meeting_id = ?1",
            meeting_id,
        )
    }

    pub fn mark_job_failed(&self, meeting_id: Uuid, error: &str) -> Result<()> {
        let id = crate::ids::uuid_upper(&meeting_id);
        self.with_db(|db| {
            db.execute(
                "UPDATE pipeline_jobs SET last_error = ?2 WHERE meeting_id = ?1",
                params![id, error],
            )?;
            Ok(())
        })
    }

    /// Drops jobs whose meeting no longer exists.
    pub fn prune_jobs(&self, existing: &[Uuid]) -> Result<usize> {
        let keep: std::collections::HashSet<String> =
            existing.iter().map(crate::ids::uuid_upper).collect();
        self.with_db(|db| {
            let mut statement = db.prepare("SELECT meeting_id FROM pipeline_jobs")?;
            let ids: Vec<String> = statement
                .query_map([], |row| row.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            let mut removed = 0;
            for id in ids {
                let known = Uuid::parse_str(&id)
                    .ok()
                    .map(|u| crate::ids::uuid_upper(&u));
                if known.is_none_or(|k| !keep.contains(&k)) {
                    removed +=
                        db.execute("DELETE FROM pipeline_jobs WHERE meeting_id = ?1", [&id])?;
                }
            }
            Ok(removed)
        })
    }

    fn update_job(&self, sql: &str, meeting_id: Uuid) -> Result<()> {
        let id = crate::ids::uuid_upper(&meeting_id);
        self.with_db(|db| {
            db.execute(sql, [id])?;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn job_lifecycle_and_parking() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let id = Uuid::new_v4();
        library.enqueue_job(id, true, true, false).unwrap();
        for _ in 0..3 {
            library.mark_job_started(id).unwrap();
            library.enqueue_job(id, true, true, false).unwrap();
        }
        assert!(
            library.pending_jobs().unwrap().is_empty(),
            "automatic enqueues keep the attempt count"
        );
        library.mark_job_failed(id, "model crashed").unwrap();
        let parked = library.parked_jobs().unwrap();
        assert_eq!(parked[0].last_error.as_deref(), Some("model crashed"));
        library.enqueue_job(id, true, false, true).unwrap();
        let pending = library.pending_jobs().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].attempts, 0);
        assert!(!pending[0].summarize);
        assert_eq!(pending[0].last_error, None);
        library.mark_transcription_completed(id).unwrap();
        assert!(library.job(id).unwrap().unwrap().transcription_completed);
        let stored: String = library
            .with_db(|db| {
                Ok(db.query_row("SELECT meeting_id FROM pipeline_jobs", [], |r| r.get(0))?)
            })
            .unwrap();
        assert_eq!(stored, crate::ids::uuid_upper(&id));
        library.mark_job_completed(id).unwrap();
        assert!(library.job(id).unwrap().is_none());
        library.enqueue_job(id, true, true, true).unwrap();
        assert_eq!(library.prune_jobs(&[]).unwrap(), 1);
    }
}
