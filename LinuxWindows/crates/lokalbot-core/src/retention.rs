//! Screen and activity retention (`ScreenshotService.performRetentionPrune`,
//! `ActivityStore.retentionReview`, `clearRetainedText`).
//!
//! Older than the cutoff and not saved: pixels are deleted; unless text is
//! kept forever, screen text, vectors, window titles, URLs, document names
//! and coding-agent sessions are removed. Activity window titles are always
//! cleared; app names and durations stay. Meetings are never touched.

use anyhow::Result;
use chrono::{DateTime, Utc};
use rusqlite::params;

use crate::library::Library;
use crate::settings::Settings;
use crate::timeline::table_exists;

/// What one retention pass removed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RetentionReport {
    pub pixels_removed: usize,
    pub texts_removed: usize,
    pub activity_titles_cleared: usize,
    pub agent_sessions_removed: usize,
    pub orphans_removed: usize,
}

/// Marker file with the time of the last pass.
pub const LAST_PASS_FILE: &str = ".screen-retention-last-pass";

impl Library {
    /// Applies the retention window of `settings` as of `now`.
    pub fn apply_retention(
        &self,
        settings: &Settings,
        now: DateTime<Utc>,
    ) -> Result<RetentionReport> {
        let days = settings.retention_days.max(1);
        let cutoff = crate::time::to_epoch(now) - f64::from(days) * 86_400.0;
        let keep_text = settings.keep_ocr_text_forever;
        let root = self.paths().root().to_path_buf();
        let mut report = RetentionReport::default();

        let pixel_paths: Vec<(i64, String)> = self.with_db(|db| {
            if !table_exists(db, "screenshots")? {
                return Ok(Vec::new());
            }
            let mut statement = db.prepare(
                "SELECT id, path FROM screenshots WHERE ts < ?1 AND path != '' \
                 AND id NOT IN (SELECT snapshot_id FROM screen_bookmarks)",
            )?;
            let rows = statement.query_map([cutoff], |row| Ok((row.get(0)?, row.get(1)?)))?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })?;
        for (id, path) in pixel_paths {
            let file = std::path::PathBuf::from(&path);
            // Only files inside the library are ever deleted.
            let removable = file.starts_with(&root) || file.is_relative();
            let absolute = if file.is_relative() {
                root.join(&file)
            } else {
                file
            };
            if removable && absolute.exists() && std::fs::remove_file(&absolute).is_err() {
                log::warn!("retention could not delete a screen capture; keeping its reference");
                continue;
            }
            self.with_db(|db| {
                db.execute("UPDATE screenshots SET path = '' WHERE id = ?1", [id])?;
                Ok(())
            })?;
            report.pixels_removed += 1;
        }

        self.with_db(|db| {
            let tx = db.unchecked_transaction()?;
            if table_exists(&tx, "activity_blocks")? {
                report.activity_titles_cleared =
                    tx.execute("UPDATE activity_blocks SET title = '' WHERE end < ?1 AND title != ''", [cutoff])?;
            }
            if !keep_text && table_exists(&tx, "screenshots")? {
                let unsaved = "NOT EXISTS (SELECT 1 FROM screen_bookmarks AS bookmark WHERE bookmark.snapshot_id = {id})";
                if table_exists(&tx, "ocr_metadata")? && table_exists(&tx, "ocr_fts")? {
                    report.texts_removed = tx.execute(
                        &format!(
                            "DELETE FROM ocr_fts WHERE rowid IN (SELECT meta.rowid FROM ocr_metadata AS meta \
                             JOIN screenshots AS shot ON shot.id = meta.snapshot_id WHERE shot.ts < ?1 AND {})",
                            unsaved.replace("{id}", "meta.snapshot_id")
                        ),
                        [cutoff],
                    )?;
                    // Text whose capture row is gone.
                    report.orphans_removed += tx.execute(
                        "DELETE FROM ocr_fts WHERE CAST(ts AS REAL) < ?1 \
                         AND NOT EXISTS (SELECT 1 FROM screenshots WHERE id = CAST(ocr_fts.snapshot_id AS INTEGER)) \
                         AND NOT EXISTS (SELECT 1 FROM screen_bookmarks WHERE snapshot_id = CAST(ocr_fts.snapshot_id AS INTEGER))",
                        [cutoff],
                    )?;
                    tx.execute("DELETE FROM ocr_metadata WHERE rowid NOT IN (SELECT rowid FROM ocr_fts)", [])?;
                }
                if table_exists(&tx, "screen_embeddings")? {
                    tx.execute(
                        &format!(
                            "DELETE FROM screen_embeddings WHERE snapshot_id IN (SELECT id FROM screenshots WHERE ts < ?1) AND {}",
                            unsaved.replace("{id}", "screen_embeddings.snapshot_id")
                        ),
                        [cutoff],
                    )?;
                    report.orphans_removed += tx.execute(
                        "DELETE FROM screen_embeddings WHERE ts < ?1 \
                         AND NOT EXISTS (SELECT 1 FROM screenshots WHERE id = screen_embeddings.snapshot_id) \
                         AND NOT EXISTS (SELECT 1 FROM screen_bookmarks WHERE snapshot_id = screen_embeddings.snapshot_id)",
                        [cutoff],
                    )?;
                }
                tx.execute(
                    &format!(
                        "UPDATE screenshots SET window_title = '', source_url = '', document_name = '' \
                         WHERE ts < ?1 AND (window_title != '' OR source_url != '' OR document_name != '') AND {}",
                        unsaved.replace("{id}", "screenshots.id")
                    ),
                    [cutoff],
                )?;
                if table_exists(&tx, "coding_agent_bursts")? {
                    report.agent_sessions_removed =
                        tx.execute("DELETE FROM coding_agent_bursts WHERE end < ?1", params![cutoff])?;
                }
            }
            tx.commit()?;
            Ok(())
        })?;
        if !self.is_read_only() {
            let stamp = now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
            if let Err(err) =
                crate::library::write_atomic(&root.join(LAST_PASS_FILE), stamp.as_bytes())
            {
                log::warn!("could not record the retention pass: {err}");
            }
        }
        Ok(report)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline::NewScreenMoment;

    #[test]
    fn expires_old_context_but_keeps_saved_moments() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let now = Utc::now();
        let old = now - chrono::Duration::days(20);
        let moment = |ts, title: &str| NewScreenMoment {
            ts,
            app: "Firefox".into(),
            window_title: title.into(),
            text: format!("{title} secret plans"),
            ..Default::default()
        };
        let expired = library
            .record_screen_moment(&moment(old, "Old page"))
            .unwrap();
        let saved = library
            .record_screen_moment(&moment(old, "Saved page"))
            .unwrap();
        let fresh = library
            .record_screen_moment(&moment(now, "New page"))
            .unwrap();
        library.save_moment(saved, "keep").unwrap();
        library
            .append_activity(
                "Firefox",
                "Old page",
                old,
                old + chrono::Duration::minutes(5),
            )
            .unwrap();

        let report = library.apply_retention(&Settings::default(), now).unwrap();
        assert_eq!(report.texts_removed, 1);
        assert_eq!(report.activity_titles_cleared, 1);
        let expired = library.screen_moment(expired).unwrap().unwrap();
        assert_eq!(expired.text, None);
        assert_eq!(expired.window_title, "");
        assert!(
            library
                .screen_moment(saved)
                .unwrap()
                .unwrap()
                .text
                .is_some()
        );
        assert!(
            library
                .screen_moment(fresh)
                .unwrap()
                .unwrap()
                .text
                .is_some()
        );
        let blocks = library
            .activity_blocks(old - chrono::Duration::hours(1), now)
            .unwrap();
        assert_eq!(blocks[0].title, "");
        assert_eq!(blocks[0].app, "Firefox");
        assert!(dir.path().join(LAST_PASS_FILE).is_file());

        let keep = Settings {
            keep_ocr_text_forever: true,
            ..Settings::default()
        };
        let second = library
            .record_screen_moment(&moment(old, "Kept text"))
            .unwrap();
        library.apply_retention(&keep, now).unwrap();
        assert!(
            library
                .screen_moment(second)
                .unwrap()
                .unwrap()
                .text
                .is_some()
        );
    }
}
