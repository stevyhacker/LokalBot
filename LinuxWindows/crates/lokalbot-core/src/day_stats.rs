//! What exports and routines read about a stretch of screen memory
//! (`SQLiteScreenMemoryReader.savedMoments`, `daySummary`, `appUsage`).

use anyhow::Result;
use chrono::{DateTime, Utc};
use rusqlite::params;

use crate::library::Library;
use crate::time::{from_epoch, to_epoch};
use crate::timeline::table_exists;

/// A saved moment with its note and the start of its captured text.
#[derive(Clone, Debug, PartialEq)]
pub struct SavedMoment {
    pub snapshot_id: i64,
    pub captured_at: DateTime<Utc>,
    pub app: String,
    pub window_title: String,
    pub note: String,
    pub ocr_excerpt: String,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct DaySummary {
    pub tracked_seconds: f64,
    pub app_count: usize,
    pub activity_block_count: usize,
    pub screenshot_count: usize,
    pub saved_moment_count: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AppTime {
    pub app: String,
    pub duration_seconds: f64,
}

const OCR_EXCERPT_CHARACTERS: usize = 280;

impl Library {
    pub fn saved_moments_between(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        limit: usize,
    ) -> Result<Vec<SavedMoment>> {
        self.with_db(|db| {
            if !table_exists(db, "screen_bookmarks")? {
                return Ok(Vec::new());
            }
            let mut statement = db.prepare(
                "SELECT b.snapshot_id, s.ts, s.app, s.window_title, b.note, \
                 COALESCE((SELECT o.text FROM ocr_fts o \
                           WHERE CAST(o.snapshot_id AS INTEGER) = s.id \
                           ORDER BY o.rowid LIMIT 1), '') \
                 FROM screen_bookmarks b JOIN screenshots s ON s.id = b.snapshot_id \
                 WHERE s.ts >= ?1 AND s.ts < ?2 ORDER BY s.ts LIMIT ?3",
            )?;
            let rows = statement.query_map(
                params![to_epoch(start), to_epoch(end), limit as i64],
                |row| {
                    Ok(SavedMoment {
                        snapshot_id: row.get(0)?,
                        captured_at: from_epoch(row.get(1)?),
                        app: row.get(2)?,
                        window_title: row.get(3)?,
                        note: row.get(4)?,
                        ocr_excerpt: row
                            .get::<_, String>(5)?
                            .chars()
                            .take(OCR_EXCERPT_CHARACTERS)
                            .collect(),
                    })
                },
            )?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    pub fn day_summary(&self, start: DateTime<Utc>, end: DateTime<Utc>) -> Result<DaySummary> {
        let (start, end) = (to_epoch(start), to_epoch(end));
        self.with_db(|db| {
            let mut summary = DaySummary::default();
            if table_exists(db, "activity_blocks")? {
                let (seconds, apps, blocks): (f64, i64, i64) = db.query_row(
                    "SELECT COALESCE(SUM(MIN(end, ?2) - MAX(start, ?1)), 0), \
                     COUNT(DISTINCT app), COUNT(*) \
                     FROM activity_blocks WHERE end > ?1 AND start < ?2",
                    params![start, end],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )?;
                summary.tracked_seconds = seconds;
                summary.app_count = apps.max(0) as usize;
                summary.activity_block_count = blocks.max(0) as usize;
            }
            if table_exists(db, "screenshots")? {
                let count: i64 = db.query_row(
                    "SELECT COUNT(*) FROM screenshots WHERE ts >= ?1 AND ts < ?2",
                    params![start, end],
                    |row| row.get(0),
                )?;
                summary.screenshot_count = count.max(0) as usize;
            }
            if table_exists(db, "screen_bookmarks")? {
                let count: i64 = db.query_row(
                    "SELECT COUNT(*) FROM screen_bookmarks b JOIN screenshots s ON s.id = b.snapshot_id \
                     WHERE s.ts >= ?1 AND s.ts < ?2",
                    params![start, end],
                    |row| row.get(0),
                )?;
                summary.saved_moment_count = count.max(0) as usize;
            }
            Ok(summary)
        })
    }

    pub fn app_time(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        limit: usize,
    ) -> Result<Vec<AppTime>> {
        self.with_db(|db| {
            if !table_exists(db, "activity_blocks")? {
                return Ok(Vec::new());
            }
            let mut statement = db.prepare(
                "SELECT app, SUM(MIN(end, ?2) - MAX(start, ?1)) AS duration \
                 FROM activity_blocks WHERE end > ?1 AND start < ?2 \
                 GROUP BY app HAVING duration > 0 \
                 ORDER BY duration DESC, app LIMIT ?3",
            )?;
            let rows = statement.query_map(
                params![to_epoch(start), to_epoch(end), limit as i64],
                |row| {
                    Ok(AppTime {
                        app: row.get(0)?,
                        duration_seconds: row.get(1)?,
                    })
                },
            )?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline::NewScreenMoment;
    use chrono::{Duration, TimeZone as _};

    #[test]
    fn counts_clip_to_the_interval_and_keep_order() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let start = Utc.with_ymd_and_hms(2026, 10, 15, 0, 0, 0).unwrap();
        let end = start + Duration::days(1);
        library
            .append_activity(
                "Editor",
                "main.rs",
                start - Duration::minutes(30),
                start + Duration::minutes(30),
            )
            .unwrap();
        library
            .append_activity(
                "Browser",
                "docs",
                start + Duration::hours(1),
                start + Duration::hours(2),
            )
            .unwrap();
        let moment = library
            .record_screen_moment(&NewScreenMoment {
                ts: start + Duration::hours(1),
                app: "Browser".into(),
                window_title: "docs".into(),
                text: "x".repeat(400),
                ..Default::default()
            })
            .unwrap();
        library.save_moment(moment, " worth keeping ").unwrap();
        library
            .record_screen_moment(&NewScreenMoment {
                ts: end + Duration::hours(1),
                app: "Browser".into(),
                ..Default::default()
            })
            .unwrap();

        let summary = library.day_summary(start, end).unwrap();
        assert_eq!(summary.tracked_seconds, 5_400.0);
        assert_eq!(summary.app_count, 2);
        assert_eq!(summary.activity_block_count, 2);
        assert_eq!(summary.screenshot_count, 1);
        assert_eq!(summary.saved_moment_count, 1);

        let usage = library.app_time(start, end, 100).unwrap();
        assert_eq!(usage[0].app, "Browser");
        assert_eq!(usage[0].duration_seconds, 3_600.0);
        assert_eq!(usage[1].app, "Editor");
        assert_eq!(library.app_time(start, end, 1).unwrap().len(), 1);

        let saved = library.saved_moments_between(start, end, 500).unwrap();
        assert_eq!(saved.len(), 1);
        assert_eq!(saved[0].note, "worth keeping");
        assert_eq!(saved[0].ocr_excerpt.chars().count(), OCR_EXCERPT_CHARACTERS);
    }
}
