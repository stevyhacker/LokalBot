//! Read-only screen memory for MCP (`ScreenMemoryReader.swift`): OCR text,
//! window titles and activity metadata from `lokalbotv3.sqlite`, opened
//! read-only for every request. Never pixels or screenshot file paths.

use std::path::{Path, PathBuf};

use anyhow::{Context as _, Result};
use chrono::{DateTime, Utc};
use rusqlite::{Connection, OpenFlags, OptionalExtension as _, params};
use serde::Serialize;

use crate::session::{epoch, iso8601};

fn iso<S: serde::Serializer>(value: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(&iso8601(*value))
}

fn iso_option<S: serde::Serializer>(
    value: &Option<DateTime<Utc>>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    match value {
        Some(value) => serializer.serialize_str(&iso8601(*value)),
        None => serializer.serialize_none(),
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SearchHit {
    pub snapshot_id: i64,
    #[serde(serialize_with = "iso")]
    pub captured_at: DateTime<Utc>,
    pub app: String,
    pub window_title: String,
    pub text_source: String,
    pub snippet: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ActivityBlock {
    pub id: i64,
    pub app: String,
    pub window_title: String,
    #[serde(serialize_with = "iso")]
    pub started_at: DateTime<Utc>,
    #[serde(serialize_with = "iso")]
    pub ended_at: DateTime<Utc>,
    pub duration_seconds: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ScreenshotSummary {
    pub snapshot_id: i64,
    #[serde(serialize_with = "iso")]
    pub captured_at: DateTime<Utc>,
    pub app: String,
    pub window_title: String,
    pub capture_trigger: String,
    pub has_ocr: bool,
    pub is_saved: bool,
    pub has_encrypted_pixels: bool,
    pub source_url: String,
    pub document_name: String,
    pub meeting_id: String,
    pub privacy_redaction_count: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Timeline {
    #[serde(serialize_with = "iso")]
    pub start: DateTime<Utc>,
    #[serde(serialize_with = "iso")]
    pub end: DateTime<Utc>,
    pub activity: Vec<ActivityBlock>,
    pub screenshots: Vec<ScreenshotSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub activity_truncated: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screenshots_truncated: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct AppUsage {
    pub app: String,
    pub duration_seconds: f64,
    pub block_count: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ScreenshotDetail {
    pub snapshot_id: i64,
    #[serde(serialize_with = "iso")]
    pub captured_at: DateTime<Utc>,
    pub app: String,
    pub window_title: String,
    pub capture_trigger: String,
    pub has_encrypted_pixels: bool,
    pub text_sources: Vec<String>,
    pub ocr_text: String,
    pub is_saved: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub saved_note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", serialize_with = "iso_option")]
    pub saved_at: Option<DateTime<Utc>>,
    pub source_url: String,
    pub document_name: String,
    pub meeting_id: String,
    pub privacy_redaction_count: i64,
}

/// One coding-agent session for the briefing: where and what came out, never
/// prompts, replies or file contents.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentSession {
    pub agent: String,
    pub project: String,
    pub title: String,
    pub start: DateTime<Utc>,
    pub session_id: String,
    pub pull_requests: Vec<String>,
    pub action_count: usize,
}

pub struct ScreenReader {
    database: PathBuf,
}

impl ScreenReader {
    pub fn new(root: &Path) -> Self {
        Self {
            database: root.join("lokalbotv3.sqlite"),
        }
    }

    fn connect(&self) -> Result<Connection> {
        let connection = Connection::open_with_flags(
            &self.database,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .with_context(|| {
            format!(
                "Screen-memory database is unavailable at {}",
                self.database.display()
            )
        })?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        Ok(connection)
    }

    fn table_exists(connection: &Connection, name: &str) -> Result<bool> {
        Ok(connection
            .query_row(
                "SELECT 1 FROM sqlite_master WHERE name = ?1",
                [name],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    /// OR of the quoted query words, best match first.
    pub fn search(
        &self,
        query: &str,
        start: Option<DateTime<Utc>>,
        end: Option<DateTime<Utc>>,
        app: Option<&str>,
        limit: usize,
    ) -> Result<Vec<SearchHit>> {
        let terms: Vec<&str> = query
            .split(|c: char| !c.is_alphanumeric())
            .filter(|t| !t.is_empty())
            .collect();
        if terms.is_empty() {
            return Ok(Vec::new());
        }
        let expression = terms
            .iter()
            .map(|t| format!("\"{}\"", t.replace('"', "\"\"")))
            .collect::<Vec<_>>()
            .join(" OR ");
        let connection = self.connect()?;
        if !Self::table_exists(&connection, "ocr_fts")? {
            return Ok(Vec::new());
        }
        let mut sql = String::from(
            "SELECT CAST(snapshot_id AS INTEGER), CAST(ts AS REAL), app, window_title, text_source, \
             snippet(ocr_fts, 0, '«', '»', '…', 14) FROM ocr_fts WHERE ocr_fts MATCH ?1 \
             AND CAST(snapshot_id AS INTEGER) > 0",
        );
        let mut values: Vec<rusqlite::types::Value> = vec![expression.into()];
        if let Some(start) = start {
            values.push(lokalbot_core::time::to_epoch(start).into());
            sql.push_str(&format!(" AND CAST(ts AS REAL) >= ?{}", values.len()));
        }
        if let Some(end) = end {
            values.push(lokalbot_core::time::to_epoch(end).into());
            sql.push_str(&format!(" AND CAST(ts AS REAL) < ?{}", values.len()));
        }
        if let Some(app) = app.filter(|a| !a.is_empty()) {
            values.push(app.to_string().into());
            sql.push_str(&format!(
                " AND instr(lower(app), lower(?{})) > 0",
                values.len()
            ));
        }
        values.push((limit as i64).into());
        sql.push_str(&format!(
            " ORDER BY bm25(ocr_fts), CAST(ts AS REAL) DESC LIMIT ?{}",
            values.len()
        ));
        let mut statement = connection.prepare(&sql)?;
        let rows = statement.query_map(rusqlite::params_from_iter(values.iter()), |row| {
            Ok(SearchHit {
                snapshot_id: row.get(0)?,
                captured_at: epoch(row.get(1)?),
                app: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                window_title: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                text_source: row.get::<_, Option<String>>(4)?.unwrap_or_default(),
                snippet: row.get::<_, Option<String>>(5)?.unwrap_or_default(),
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn timeline(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        limit: usize,
    ) -> Result<Timeline> {
        let connection = self.connect()?;
        let (s, e) = (
            lokalbot_core::time::to_epoch(start),
            lokalbot_core::time::to_epoch(end),
        );
        let fetch = limit as i64 + 1;
        let mut activity = Vec::new();
        if Self::table_exists(&connection, "activity_blocks")? {
            let mut statement = connection.prepare(
                "SELECT id, app, title, MAX(start, ?1), MIN(end, ?2) FROM activity_blocks \
                 WHERE end > ?1 AND start < ?2 ORDER BY start LIMIT ?3",
            )?;
            let rows = statement.query_map(params![s, e, fetch], activity_row)?;
            activity = rows.collect::<rusqlite::Result<Vec<_>>>()?;
        }
        let mut screenshots = Vec::new();
        if Self::table_exists(&connection, "screenshots")? {
            let saved = if Self::table_exists(&connection, "screen_bookmarks")? {
                "EXISTS(SELECT 1 FROM screen_bookmarks b WHERE b.snapshot_id = s.id)"
            } else {
                "0"
            };
            let has_ocr = if Self::table_exists(&connection, "ocr_fts")? {
                "EXISTS(SELECT 1 FROM ocr_fts o WHERE CAST(o.snapshot_id AS INTEGER) = s.id)"
            } else {
                "0"
            };
            let mut statement = connection.prepare(&format!(
                "SELECT s.id, s.ts, s.app, s.window_title, s.capture_trigger, {has_ocr}, {saved}, s.path != '', \
                 s.source_url, s.document_name, s.meeting_id, s.privacy_redactions \
                 FROM screenshots s WHERE s.ts >= ?1 AND s.ts < ?2 ORDER BY s.ts LIMIT ?3"
            ))?;
            let rows = statement.query_map(params![s, e, fetch], |row| {
                Ok(ScreenshotSummary {
                    snapshot_id: row.get(0)?,
                    captured_at: epoch(row.get(1)?),
                    app: row.get(2)?,
                    window_title: row.get(3)?,
                    capture_trigger: row.get(4)?,
                    has_ocr: row.get(5)?,
                    is_saved: row.get(6)?,
                    has_encrypted_pixels: row.get(7)?,
                    source_url: row.get(8)?,
                    document_name: row.get(9)?,
                    meeting_id: row.get(10)?,
                    privacy_redaction_count: row.get(11)?,
                })
            })?;
            screenshots = rows.collect::<rusqlite::Result<Vec<_>>>()?;
        }
        let activity_truncated = (activity.len() > limit).then_some(true);
        let screenshots_truncated = (screenshots.len() > limit).then_some(true);
        activity.truncate(limit);
        screenshots.truncate(limit);
        Ok(Timeline {
            start,
            end,
            activity,
            screenshots,
            activity_truncated,
            screenshots_truncated,
        })
    }

    pub fn recent_activity(
        &self,
        since: DateTime<Utc>,
        limit: usize,
    ) -> Result<Vec<ActivityBlock>> {
        let connection = self.connect()?;
        if !Self::table_exists(&connection, "activity_blocks")? {
            return Ok(Vec::new());
        }
        let mut statement = connection.prepare(
            "SELECT id, app, title, MAX(start, ?1), end FROM activity_blocks WHERE end > ?1 ORDER BY end DESC LIMIT ?2",
        )?;
        let rows = statement.query_map(
            params![lokalbot_core::time::to_epoch(since), limit as i64],
            activity_row,
        )?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn app_usage(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        limit: usize,
    ) -> Result<Vec<AppUsage>> {
        let connection = self.connect()?;
        if !Self::table_exists(&connection, "activity_blocks")? {
            return Ok(Vec::new());
        }
        let mut statement = connection.prepare(
            "SELECT app, SUM(MIN(end, ?2) - MAX(start, ?1)) AS duration, COUNT(*) FROM activity_blocks \
             WHERE end > ?1 AND start < ?2 GROUP BY app HAVING duration > 0 ORDER BY duration DESC, app LIMIT ?3",
        )?;
        let rows = statement.query_map(
            params![
                lokalbot_core::time::to_epoch(start),
                lokalbot_core::time::to_epoch(end),
                limit as i64
            ],
            |row| {
                Ok(AppUsage {
                    app: row.get(0)?,
                    duration_seconds: row.get(1)?,
                    block_count: row.get(2)?,
                })
            },
        )?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn screenshot_detail(&self, id: i64) -> Result<Option<ScreenshotDetail>> {
        let connection = self.connect()?;
        if !Self::table_exists(&connection, "screenshots")? {
            return Ok(None);
        }
        let saved = if Self::table_exists(&connection, "screen_bookmarks")? {
            "EXISTS(SELECT 1 FROM screen_bookmarks b WHERE b.snapshot_id = s.id), \
             COALESCE((SELECT b.note FROM screen_bookmarks b WHERE b.snapshot_id = s.id), ''), \
             (SELECT b.created_at FROM screen_bookmarks b WHERE b.snapshot_id = s.id)"
        } else {
            "0, '', NULL"
        };
        let ocr = if Self::table_exists(&connection, "ocr_fts")? {
            "COALESCE((SELECT GROUP_CONCAT(o.text_source, ',') FROM ocr_fts o WHERE CAST(o.snapshot_id AS INTEGER) = s.id), ''), \
             COALESCE((SELECT GROUP_CONCAT(o.text, char(10) || char(10)) FROM ocr_fts o WHERE CAST(o.snapshot_id AS INTEGER) = s.id), '')"
        } else {
            "'', ''"
        };
        let sql = format!(
            "SELECT s.id, s.ts, s.app, s.window_title, s.capture_trigger, s.path != '', {ocr}, {saved}, \
             s.source_url, s.document_name, s.meeting_id, s.privacy_redactions FROM screenshots s WHERE s.id = ?1 LIMIT 1"
        );
        let detail = connection
            .query_row(&sql, [id], |row| {
                let sources: String = row.get(6)?;
                let mut text_sources: Vec<String> = Vec::new();
                for source in sources.split(',').filter(|s| !s.is_empty()) {
                    if !text_sources.iter().any(|s| s == source) {
                        text_sources.push(source.to_string());
                    }
                }
                let is_saved: bool = row.get(8)?;
                let saved_at: Option<f64> = row.get(10)?;
                Ok(ScreenshotDetail {
                    snapshot_id: row.get(0)?,
                    captured_at: epoch(row.get(1)?),
                    app: row.get(2)?,
                    window_title: row.get(3)?,
                    capture_trigger: row.get(4)?,
                    has_encrypted_pixels: row.get(5)?,
                    text_sources,
                    ocr_text: row.get(7)?,
                    is_saved,
                    saved_note: if is_saved { Some(row.get(9)?) } else { None },
                    saved_at: saved_at.map(epoch),
                    source_url: row.get(11)?,
                    document_name: row.get(12)?,
                    meeting_id: row.get(13)?,
                    privacy_redaction_count: row.get(14)?,
                })
            })
            .optional()?;
        Ok(detail)
    }

    /// Coding-agent sessions that began in the interval, newest first;
    /// scheduled runs are not the person's work.
    pub fn agent_sessions(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        limit: usize,
    ) -> Result<Vec<AgentSession>> {
        let connection = self.connect()?;
        if !Self::table_exists(&connection, "coding_agent_bursts")? {
            return Ok(Vec::new());
        }
        let mut statement = connection.prepare(
            "SELECT start, payload FROM coding_agent_bursts WHERE start >= ?1 AND start < ?2 ORDER BY start DESC, id LIMIT ?3",
        )?;
        let rows = statement.query_map(
            params![
                lokalbot_core::time::to_epoch(start),
                lokalbot_core::time::to_epoch(end),
                limit as i64
            ],
            |row| Ok((row.get::<_, f64>(0)?, row.get::<_, String>(1)?)),
        )?;
        let mut out = Vec::new();
        for row in rows {
            let (start, payload) = row?;
            let Ok(value) = serde_json::from_str::<serde_json::Value>(&payload) else {
                continue;
            };
            let Some(raw_agent) = value["agent"].as_str() else {
                continue;
            };
            let prompts: Vec<&str> = value["prompts"]
                .as_array()
                .map(|p| p.iter().filter_map(|v| v.as_str()).collect())
                .unwrap_or_default();
            if !prompts.is_empty()
                && prompts.iter().all(|p| {
                    p.starts_with("Scheduled automation:") || p.starts_with("Scheduled task:")
                })
            {
                continue;
            }
            out.push(AgentSession {
                agent: match raw_agent {
                    "claude-code" => "Claude Code".into(),
                    "codex" => "Codex".into(),
                    other => other.into(),
                },
                project: value["project"].as_str().unwrap_or("").into(),
                title: value["title"].as_str().unwrap_or("").into(),
                start: epoch(start),
                session_id: value["sessionID"].as_str().unwrap_or("").into(),
                pull_requests: value["pullRequests"]
                    .as_array()
                    .map(|p| {
                        p.iter()
                            .filter_map(|v| v.as_str().map(str::to_string))
                            .collect()
                    })
                    .unwrap_or_default(),
                action_count: value["actions"].as_array().map_or(0, Vec::len),
            });
        }
        Ok(out)
    }
}

fn activity_row(row: &rusqlite::Row) -> rusqlite::Result<ActivityBlock> {
    let started = epoch(row.get(3)?);
    let ended = epoch(row.get(4)?);
    Ok(ActivityBlock {
        id: row.get(0)?,
        app: row.get(1)?,
        window_title: row.get(2)?,
        started_at: started,
        ended_at: ended,
        duration_seconds: ((ended - started).num_milliseconds() as f64 / 1000.0).max(0.0),
    })
}
