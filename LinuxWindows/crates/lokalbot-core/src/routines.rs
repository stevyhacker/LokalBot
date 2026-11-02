//! The audit trail for every routine attempt (`MemoryRoutineRunStore`). A
//! `running` row left by a crash is intentionally not success, so the scheduler
//! can retry it after the next launch instead of silently losing a due output.

use anyhow::{Context as _, Result, bail};
use chrono::{DateTime, Utc};
use rusqlite::{OptionalExtension as _, params};
use uuid::Uuid;

use crate::library::Library;
use crate::settings::MemoryRoutineKind;
use crate::time::{from_epoch, to_epoch};
use crate::timeline::table_exists;

impl MemoryRoutineKind {
    /// The stored raw value, shared with the Mac.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::PostMeetingFollowUp => "postMeetingFollowUp",
            Self::DailyStandup => "dailyStandup",
            Self::WeeklyWorkLog => "weeklyWorkLog",
            Self::UnfinishedActions => "unfinishedActions",
            Self::LocalJournal => "localJournal",
        }
    }

    pub fn from_raw_value(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.raw_value() == raw)
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::PostMeetingFollowUp => "Post-meeting follow-up",
            Self::DailyStandup => "Daily stand-up",
            Self::WeeklyWorkLog => "Weekly work log",
            Self::UnfinishedActions => "Unfinished actions",
            Self::LocalJournal => "Local journal",
        }
    }

    pub fn detail(self) -> &'static str {
        match self {
            Self::PostMeetingFollowUp => {
                "After processing, drafts a local follow-up from that meeting's summary and outcomes."
            }
            Self::DailyStandup => {
                "Builds a morning brief from yesterday's meetings, activity totals, and open action candidates."
            }
            Self::WeeklyWorkLog => {
                "Collects the last seven days of meetings, decisions, actions, and app-time totals."
            }
            Self::UnfinishedActions => {
                "Rolls up extracted action items from the last fourteen days without sending or assigning them."
            }
            Self::LocalJournal => {
                "Writes a private daily note from the local digest, meetings, app usage, and saved moments."
            }
        }
    }

    pub fn is_event_driven(self) -> bool {
        self == Self::PostMeetingFollowUp
    }

    pub fn is_weekly(self) -> bool {
        self == Self::WeeklyWorkLog
    }
}

/// One row of `memory_routine_runs`.
#[derive(Clone, Debug, PartialEq)]
pub struct RoutineRun {
    pub id: i64,
    pub kind: MemoryRoutineKind,
    pub run_token: String,
    pub started_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
    /// `running`, `succeeded`, `failed` or `cancelled`.
    pub status: String,
    pub output_path: Option<String>,
    pub error: Option<String>,
    pub meeting_id: Option<Uuid>,
}

fn optional(text: String) -> Option<String> {
    (!text.is_empty()).then_some(text)
}

impl Library {
    /// A scheduled token is terminal after either success or failure, so a bad
    /// destination or malformed source never becomes a tight retry loop. Manual
    /// runs use unique tokens and stay available. A stale `running` row is
    /// deliberately not terminal, so launch recovery can retry.
    pub fn routine_has_finished(&self, run_token: &str) -> Result<bool> {
        self.with_db(|db| {
            if !table_exists(db, "memory_routine_runs")? {
                return Ok(false);
            }
            Ok(db
                .query_row(
                    "SELECT 1 FROM memory_routine_runs \
                     WHERE run_token = ?1 AND status IN ('succeeded', 'failed') LIMIT 1",
                    [run_token],
                    |_| Ok(()),
                )
                .optional()?
                .is_some())
        })
    }

    /// Reuses only the latest revision in this scope. A correction can be
    /// reverted (A -> B -> A), so an older success for A must not suppress it.
    pub fn routine_revision_token(&self, scope: &str, fingerprint: &str) -> Result<String> {
        let prefix = format!("{scope}:revision:");
        let latest: Option<String> = self.with_db(|db| {
            if !table_exists(db, "memory_routine_runs")? {
                return Ok(None);
            }
            Ok(db
                .query_row(
                    "SELECT run_token FROM memory_routine_runs \
                     WHERE substr(run_token, 1, length(?1)) = ?1 ORDER BY id DESC LIMIT 1",
                    [&prefix],
                    |row| row.get(0),
                )
                .optional()?)
        })?;
        Ok(match latest {
            Some(latest) if latest.ends_with(&format!(":{fingerprint}")) => latest,
            _ => format!(
                "{prefix}{}:{fingerprint}",
                Uuid::new_v4().hyphenated().to_string().to_uppercase()
            ),
        })
    }

    pub fn begin_routine_run(
        &self,
        kind: MemoryRoutineKind,
        run_token: &str,
        meeting_id: Option<Uuid>,
        at: DateTime<Utc>,
    ) -> Result<i64> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        self.with_db(|db| {
            db.execute(
                "INSERT INTO memory_routine_runs \
                 (kind, run_token, started_at, completed_at, status, output_path, error, meeting_id) \
                 VALUES (?1, ?2, ?3, NULL, 'running', '', '', ?4) \
                 ON CONFLICT(run_token) DO UPDATE SET \
                 started_at = excluded.started_at, completed_at = NULL, status = 'running', \
                 output_path = '', error = '', meeting_id = excluded.meeting_id",
                params![
                    kind.raw_value(),
                    run_token,
                    to_epoch(at),
                    meeting_id
                        .map(|id| id.hyphenated().to_string().to_uppercase())
                        .unwrap_or_default(),
                ],
            )?;
            db.query_row(
                "SELECT id FROM memory_routine_runs WHERE run_token = ?1 LIMIT 1",
                [run_token],
                |row| row.get(0),
            )
            .context("the routine run has no row")
        })
    }

    pub fn finish_routine_run(
        &self,
        id: i64,
        status: &str,
        output_path: Option<&str>,
        error: Option<&str>,
        at: DateTime<Utc>,
    ) -> Result<()> {
        self.with_db(|db| {
            db.execute(
                "UPDATE memory_routine_runs \
                 SET completed_at = ?1, status = ?2, output_path = ?3, error = ?4 WHERE id = ?5",
                params![
                    to_epoch(at),
                    status,
                    output_path.unwrap_or(""),
                    error.unwrap_or(""),
                    id
                ],
            )?;
            Ok(())
        })
    }

    pub fn recent_routine_runs(&self, limit: usize) -> Result<Vec<RoutineRun>> {
        self.with_db(|db| {
            if !table_exists(db, "memory_routine_runs")? {
                return Ok(Vec::new());
            }
            let mut statement = db.prepare(
                "SELECT id, kind, run_token, started_at, completed_at, status, output_path, error, meeting_id \
                 FROM memory_routine_runs ORDER BY started_at DESC, id DESC LIMIT ?1",
            )?;
            let rows = statement.query_map([limit.max(1) as i64], |row| {
                let kind: String = row.get(1)?;
                Ok((
                    MemoryRoutineKind::from_raw_value(&kind),
                    RoutineRun {
                        id: row.get(0)?,
                        kind: MemoryRoutineKind::DailyStandup,
                        run_token: row.get(2)?,
                        started_at: from_epoch(row.get(3)?),
                        completed_at: row.get::<_, Option<f64>>(4)?.map(from_epoch),
                        status: row.get(5)?,
                        output_path: optional(row.get(6)?),
                        error: optional(row.get(7)?),
                        meeting_id: optional(row.get(8)?)
                            .and_then(|id| Uuid::parse_str(&id).ok()),
                    },
                ))
            })?;
            let mut runs = Vec::new();
            for row in rows {
                let (kind, mut run) = row?;
                // A kind a newer app wrote stays out of this list.
                if let Some(kind) = kind {
                    run.kind = kind;
                    runs.push(run);
                }
            }
            Ok(runs)
        })
    }

    pub fn running_routine_count(&self) -> usize {
        self.with_db(|db| {
            if !table_exists(db, "memory_routine_runs")? {
                return Ok(0);
            }
            let count: i64 = db.query_row(
                "SELECT COUNT(*) FROM memory_routine_runs WHERE status = 'running'",
                [],
                |row| row.get(0),
            )?;
            Ok(count.max(0) as usize)
        })
        .unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn library() -> (tempfile::TempDir, Library) {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        (dir, library)
    }

    #[test]
    fn a_run_is_recorded_and_only_a_terminal_status_finishes_it() {
        let (_dir, library) = library();
        let now = Utc::now();
        let meeting = Uuid::new_v4();
        let id = library
            .begin_routine_run(
                MemoryRoutineKind::PostMeetingFollowUp,
                "token",
                Some(meeting),
                now,
            )
            .unwrap();
        assert!(!library.routine_has_finished("token").unwrap());
        assert_eq!(library.running_routine_count(), 1);
        library
            .finish_routine_run(id, "failed", None, Some("the folder is gone"), now)
            .unwrap();
        assert!(library.routine_has_finished("token").unwrap());
        assert_eq!(library.running_routine_count(), 0);
        let runs = library.recent_routine_runs(12).unwrap();
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].kind, MemoryRoutineKind::PostMeetingFollowUp);
        assert_eq!(runs[0].meeting_id, Some(meeting));
        assert_eq!(runs[0].error.as_deref(), Some("the folder is gone"));
        assert_eq!(runs[0].output_path, None);

        // Retrying the same token reuses its row.
        let again = library
            .begin_routine_run(MemoryRoutineKind::PostMeetingFollowUp, "token", None, now)
            .unwrap();
        assert_eq!(again, id);
        assert!(!library.routine_has_finished("token").unwrap());
        library
            .finish_routine_run(id, "cancelled", None, None, now)
            .unwrap();
        assert!(!library.routine_has_finished("token").unwrap());
    }

    #[test]
    fn a_reverted_revision_gets_a_new_token() {
        let (_dir, library) = library();
        let now = Utc::now();
        let first = library.routine_revision_token("scope", "aaa").unwrap();
        assert!(first.starts_with("scope:revision:") && first.ends_with(":aaa"));
        let id = library
            .begin_routine_run(MemoryRoutineKind::DailyStandup, &first, None, now)
            .unwrap();
        library
            .finish_routine_run(id, "succeeded", Some("/tmp/a.md"), None, now)
            .unwrap();
        // Unchanged bytes reuse the finished token, so nothing runs again.
        assert_eq!(
            library.routine_revision_token("scope", "aaa").unwrap(),
            first
        );
        let second = library.routine_revision_token("scope", "bbb").unwrap();
        assert_ne!(second, first);
        let id = library
            .begin_routine_run(MemoryRoutineKind::DailyStandup, &second, None, now)
            .unwrap();
        library
            .finish_routine_run(id, "succeeded", Some("/tmp/a.md"), None, now)
            .unwrap();
        // A -> B -> A writes again.
        let third = library.routine_revision_token("scope", "aaa").unwrap();
        assert_ne!(third, first);
        assert!(!library.routine_has_finished(&third).unwrap());
    }

    #[test]
    fn raw_values_match_the_settings_encoding() {
        for kind in MemoryRoutineKind::ALL {
            let encoded = serde_json::to_value(kind).unwrap();
            assert_eq!(encoded, serde_json::json!(kind.raw_value()));
            assert_eq!(
                MemoryRoutineKind::from_raw_value(kind.raw_value()),
                Some(kind)
            );
        }
        assert_eq!(MemoryRoutineKind::from_raw_value("other"), None);
    }
}
