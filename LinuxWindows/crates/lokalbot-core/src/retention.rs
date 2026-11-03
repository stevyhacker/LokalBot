//! Screen and activity retention (`ScreenshotService.performRetentionPrune`,
//! `ActivityStore.retentionReview`, `clearRetainedText`), and the reviews a
//! person sees before anything is deleted (`RetentionReview.swift`,
//! `CaptureDeletionReview.swift`).
//!
//! Older than the cutoff and not saved: pixels are deleted; unless text is
//! kept forever, screen text, vectors, window titles, URLs, document names
//! and coding-agent sessions are removed. Activity window titles are always
//! cleared; app names and durations stay. Meetings are never touched.
//!
//! A pass deletes only what its own review listed, so a broad cutoff can never
//! remove evidence nobody looked at.

use std::collections::{HashMap, HashSet};

use anyhow::{Context as _, Result, bail};
use chrono::{DateTime, Local, Utc};
use rusqlite::params;

use crate::evidence::{self, EvidenceChange};
use crate::library::Library;
use crate::screen::resolve_capture_path;
use crate::settings::Settings;
use crate::time::{from_epoch, to_epoch};
use crate::timeline::table_exists;

/// What one retention pass removed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RetentionReport {
    pub pixels_removed: usize,
    pub texts_removed: usize,
    pub activity_titles_cleared: usize,
    pub agent_sessions_removed: usize,
    pub orphans_removed: usize,
    /// One date per evidence day the pass touched.
    pub days: Vec<DateTime<Utc>>,
    /// What could not be cleaned up; it stays listed and is retried.
    pub failures: Vec<String>,
}

/// Marker file with the time of the last pass.
pub const LAST_PASS_FILE: &str = ".screen-retention-last-pass";

/// A capture a review would change.
#[derive(Clone, Debug, PartialEq)]
pub struct RetentionCandidate {
    pub id: i64,
    pub timestamp: DateTime<Utc>,
    pub path: String,
    pub remove_text: bool,
    pub remove_vector: bool,
    pub remove_metadata: bool,
}

/// An activity block whose window title a review would clear. Its times are
/// the stored values, so clearing it matches exactly the row that was reviewed.
#[derive(Clone, Debug)]
pub struct RetentionActivityTitle {
    pub id: i64,
    pub start: f64,
    pub end: f64,
    pub title: String,
}

impl PartialEq for RetentionActivityTitle {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
            && self.start.to_bits() == other.start.to_bits()
            && self.end.to_bits() == other.end.to_bits()
            && self.title == other.title
    }
}

impl Eq for RetentionActivityTitle {}

impl std::hash::Hash for RetentionActivityTitle {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.id.hash(state);
        self.start.to_bits().hash(state);
        self.end.to_bits().hash(state);
        self.title.hash(state);
    }
}

impl RetentionActivityTitle {
    /// The block's edges and each local midnight it crosses.
    fn evidence_dates(&self) -> Vec<DateTime<Utc>> {
        let (start, end) = (from_epoch(self.start), from_epoch(self.end));
        let mut dates = vec![start, end];
        let mut day = crate::time::local_day(start);
        while let Some(next) = day.succ_opt() {
            let (next_start, _) = crate::time::local_day_bounds(next);
            if next_start >= end {
                break;
            }
            dates.push(next_start);
            day = next;
        }
        dates
    }
}

/// The counts behind "Review expired context…": exactly what applying it
/// removes. Building one changes nothing.
#[derive(Clone, Debug, PartialEq)]
pub struct RetentionReview {
    pub days: u32,
    pub keep_text_forever: bool,
    pub reviewed_at: DateTime<Utc>,
    pub candidates: Vec<RetentionCandidate>,
    pub saved_count: usize,
    pub bytes: u64,
    pub activity_titles: Vec<RetentionActivityTitle>,
    /// Agent requests and reports are text, so they expire with screen text.
    pub coding_agent_bursts: Vec<(String, DateTime<Utc>)>,
}

#[derive(Debug, thiserror::Error)]
pub enum RetentionReviewError {
    #[error("The cleanup scope changed. Review the updated counts before applying it.")]
    ScopeChanged,
}

impl RetentionReview {
    pub fn pixel_count(&self) -> usize {
        self.candidates
            .iter()
            .filter(|c| !c.path.is_empty())
            .count()
    }

    pub fn text_count(&self) -> usize {
        self.candidates.iter().filter(|c| c.remove_text).count()
    }

    pub fn vector_count(&self) -> usize {
        self.candidates.iter().filter(|c| c.remove_vector).count()
    }

    pub fn metadata_count(&self) -> usize {
        self.candidates.iter().filter(|c| c.remove_metadata).count()
    }

    pub fn is_empty(&self) -> bool {
        self.candidates.is_empty()
            && self.activity_titles.is_empty()
            && self.coding_agent_bursts.is_empty()
    }

    pub fn evidence_dates(&self) -> Vec<DateTime<Utc>> {
        self.candidates
            .iter()
            .map(|c| c.timestamp)
            .chain(
                self.activity_titles
                    .iter()
                    .flat_map(RetentionActivityTitle::evidence_dates),
            )
            .chain(self.coding_agent_bursts.iter().map(|(_, start)| *start))
            .collect()
    }

    pub fn oldest(&self) -> Option<DateTime<Utc>> {
        self.evidence_dates().into_iter().min()
    }

    pub fn newest(&self) -> Option<DateTime<Utc>> {
        self.evidence_dates().into_iter().max()
    }

    /// Evidence dates reduced to one per distinct pair of local day and UTC
    /// day, sorted. Consumers key only on those days; a pass after a long gap
    /// would otherwise hand them a date per row.
    pub fn distinct_evidence_days(&self, extra: &[DateTime<Utc>]) -> Vec<DateTime<Utc>> {
        let mut seen = HashSet::new();
        let mut dates: Vec<DateTime<Utc>> = self
            .evidence_dates()
            .into_iter()
            .chain(extra.iter().copied())
            .filter(|date| {
                seen.insert((date.date_naive(), date.with_timezone(&Local).date_naive()))
            })
            .collect();
        dates.sort();
        dates
    }

    /// A disappearing file or newly saved moment may shrink a review safely.
    /// Additional data, changed paths or new text require a fresh review.
    pub fn covers(&self, current: &RetentionReview) -> bool {
        let approved: HashMap<i64, &RetentionCandidate> =
            self.candidates.iter().map(|c| (c.id, c)).collect();
        let titles: HashSet<&RetentionActivityTitle> = self.activity_titles.iter().collect();
        let bursts: HashSet<&(String, DateTime<Utc>)> = self.coding_agent_bursts.iter().collect();
        self.days == current.days
            && self.keep_text_forever == current.keep_text_forever
            && current.activity_titles.iter().all(|t| titles.contains(t))
            && current
                .coding_agent_bursts
                .iter()
                .all(|b| bursts.contains(b))
            && current.candidates.iter().all(|candidate| {
                approved.get(&candidate.id).is_some_and(|old| {
                    candidate.timestamp == old.timestamp
                        && (candidate.path.is_empty() || candidate.path == old.path)
                        && (!candidate.remove_text || old.remove_text)
                        && (!candidate.remove_vector || old.remove_vector)
                        && (!candidate.remove_metadata || old.remove_metadata)
                })
            })
    }
}

/// One moment in a reviewed time range.
#[derive(Clone, Debug, PartialEq)]
pub struct ReviewedCapture {
    pub id: i64,
    pub ts: DateTime<Utc>,
    pub path: String,
    pub app: String,
    pub is_saved: bool,
}

/// Exactly what deleting a time range removes (`CaptureDeletionReview`).
#[derive(Clone, Debug, PartialEq)]
pub struct CaptureDeletionReview {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub includes_saved: bool,
    pub captures: Vec<ReviewedCapture>,
    pub saved_excluded: usize,
}

impl CaptureDeletionReview {
    pub fn pixel_count(&self) -> usize {
        self.captures.iter().filter(|c| !c.path.is_empty()).count()
    }

    pub fn saved_included(&self) -> usize {
        self.captures.iter().filter(|c| c.is_saved).count()
    }

    pub fn covers(&self, current: &CaptureDeletionReview) -> bool {
        if self.start != current.start
            || self.end != current.end
            || self.includes_saved != current.includes_saved
        {
            return false;
        }
        let approved: HashMap<i64, &ReviewedCapture> =
            self.captures.iter().map(|c| (c.id, c)).collect();
        current.captures.iter().all(|item| {
            approved.get(&item.id).is_some_and(|original| {
                item.ts == original.ts && (item.path.is_empty() || item.path == original.path)
            })
        })
    }
}

/// Text and vectors whose capture row is gone. Their own timestamps establish
/// the evidence day, and exact row identities mean a pass never needs a broad
/// cutoff (`ActivityStore.OrphanedScreenEvidence`).
#[derive(Clone, Debug, Default)]
struct OrphanedEvidence {
    text: Vec<(i64, i64, f64)>,
    vectors: Vec<(i64, f64)>,
}

impl OrphanedEvidence {
    fn is_empty(&self) -> bool {
        self.text.is_empty() && self.vectors.is_empty()
    }

    fn timestamps(&self) -> Vec<DateTime<Utc>> {
        self.text
            .iter()
            .map(|row| from_epoch(row.2))
            .chain(self.vectors.iter().map(|row| from_epoch(row.1)))
            .collect()
    }
}

impl Library {
    /// The dry run: what a retention window of `days` removes as of `now`.
    /// `measuring_bytes` stats every candidate file for "space recovered".
    pub fn retention_review(
        &self,
        days: u32,
        keep_text_forever: bool,
        now: DateTime<Utc>,
        measuring_bytes: bool,
    ) -> Result<RetentionReview> {
        let cutoff = to_epoch(now) - f64::from(days.max(1)) * 86_400.0;
        let root = self.paths().root().to_path_buf();
        self.with_db(|db| {
            // A read-only library may predate these tables.
            for table in ["screenshots", "ocr_metadata", "screen_bookmarks", "activity_blocks"] {
                if !table_exists(db, table)? {
                    return Ok(RetentionReview {
                        days,
                        keep_text_forever,
                        reviewed_at: now,
                        candidates: Vec::new(),
                        saved_count: 0,
                        bytes: 0,
                        activity_titles: Vec::new(),
                        coding_agent_bursts: Vec::new(),
                    });
                }
            }
            let vector_query = if table_exists(db, "screen_embeddings")? {
                "EXISTS(SELECT 1 FROM screen_embeddings WHERE snapshot_id = shot.id)"
            } else {
                "0"
            };
            let mut statement = db.prepare(&format!(
                "SELECT shot.id, shot.ts, shot.path, \
                 EXISTS(SELECT 1 FROM ocr_metadata WHERE snapshot_id = shot.id), \
                 {vector_query}, \
                 (shot.window_title != '' OR shot.source_url != '' OR shot.document_name != '') \
                 FROM screenshots AS shot \
                 WHERE shot.ts < ?1 AND shot.id NOT IN (SELECT snapshot_id FROM screen_bookmarks) \
                 ORDER BY shot.ts"
            ))?;
            let candidates: Vec<RetentionCandidate> = statement
                .query_map([cutoff], |row| {
                    Ok(RetentionCandidate {
                        id: row.get(0)?,
                        timestamp: from_epoch(row.get(1)?),
                        path: row.get(2)?,
                        remove_text: !keep_text_forever && row.get(3)?,
                        remove_vector: !keep_text_forever && row.get(4)?,
                        remove_metadata: !keep_text_forever && row.get(5)?,
                    })
                })?
                .filter(|candidate| {
                    candidate.as_ref().map_or(true, |c: &RetentionCandidate| {
                        !c.path.is_empty() || c.remove_text || c.remove_vector || c.remove_metadata
                    })
                })
                .collect::<rusqlite::Result<_>>()?;
            // App names and durations remain useful aggregate history. Window
            // titles are content and expire even with the text exception.
            let mut statement = db.prepare(
                "SELECT id, start, end, title FROM activity_blocks \
                 WHERE end < ?1 AND title != '' ORDER BY start",
            )?;
            let activity_titles: Vec<RetentionActivityTitle> = statement
                .query_map([cutoff], |row| {
                    Ok(RetentionActivityTitle {
                        id: row.get(0)?,
                        start: row.get(1)?,
                        end: row.get(2)?,
                        title: row.get(3)?,
                    })
                })?
                .collect::<rusqlite::Result<_>>()?;
            let saved_count: i64 = db.query_row(
                "SELECT COUNT(*) FROM screen_bookmarks JOIN screenshots ON screenshots.id = snapshot_id \
                 WHERE screenshots.ts < ?1",
                [cutoff],
                |row| row.get(0),
            )?;
            let bytes = if measuring_bytes {
                candidates
                    .iter()
                    .filter_map(|c| resolve_capture_path(&root, &c.path))
                    .filter_map(|file| std::fs::metadata(file).ok())
                    .map(|meta| meta.len())
                    .sum()
            } else {
                0
            };
            // Agent requests and reports are text: they follow the text rule.
            let coding_agent_bursts = if keep_text_forever
                || !table_exists(db, "coding_agent_bursts")?
            {
                Vec::new()
            } else {
                let mut statement = db.prepare(
                    "SELECT id, start FROM coding_agent_bursts WHERE end < ?1 ORDER BY start, id",
                )?;
                statement
                    .query_map([cutoff], |row| {
                        Ok((row.get::<_, String>(0)?, from_epoch(row.get(1)?)))
                    })?
                    .collect::<rusqlite::Result<_>>()?
            };
            Ok(RetentionReview {
                days,
                keep_text_forever,
                reviewed_at: now,
                candidates,
                saved_count: saved_count.max(0) as usize,
                bytes,
                activity_titles,
                coding_agent_bursts,
            })
        })
    }

    /// Runs a reviewed cleanup (`ScreenshotService.applyRetentionReview`). It
    /// counts as the person deleting the source: dependent overnight memory and
    /// unedited generated journals go first. A review that no longer covers
    /// what is there fails with [`RetentionReviewError::ScopeChanged`] and
    /// nothing is deleted. The caller sets the new policy once this returns.
    pub fn apply_retention_review(
        &self,
        review: &RetentionReview,
        now: DateTime<Utc>,
    ) -> Result<RetentionReport> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        let current = self.retention_review(review.days, review.keep_text_forever, now, false)?;
        if !review.covers(&current) {
            return Err(RetentionReviewError::ScopeChanged.into());
        }
        let dates = review.distinct_evidence_days(&[]);
        let mut report = evidence::with_screen_mutation(
            self.paths().root(),
            &dates,
            EvidenceChange::Removal,
            || self.execute_retention(&current, &OrphanedEvidence::default()),
        )?;
        report.days = dates;
        self.record_retention_pass(now);
        Ok(report)
    }

    /// Applies the retention window of `settings` as of `now`. Scheduled
    /// retention expires evidence on its own clock; nobody deleted or
    /// corrected it, so day digests and overnight memory stay
    /// (`AppState.withScheduledRetention`).
    pub fn apply_retention(
        &self,
        settings: &Settings,
        now: DateTime<Utc>,
    ) -> Result<RetentionReport> {
        let days = settings.retention_days.max(1);
        let keep_text = settings.keep_ocr_text_forever;
        // Establish the exact sources before removing anything. A failed read
        // must never look empty.
        let review = self.retention_review(days, keep_text, now, false)?;
        let orphaned = if keep_text {
            OrphanedEvidence::default()
        } else {
            self.orphaned_evidence(to_epoch(now) - f64::from(days) * 86_400.0)?
        };
        let mut report = if review.is_empty() && orphaned.is_empty() {
            RetentionReport::default()
        } else {
            self.execute_retention(&review, &orphaned)?
        };
        report.days = review.distinct_evidence_days(&orphaned.timestamps());
        if !self.is_read_only() {
            self.record_retention_pass(now);
        }
        Ok(report)
    }

    /// Removes exactly what `review` lists, re-reading saved moments right
    /// before the irreversible file steps. A file that can't be removed keeps
    /// its reference, so the cleanup can be retried.
    fn execute_retention(
        &self,
        review: &RetentionReview,
        orphaned: &OrphanedEvidence,
    ) -> Result<RetentionReport> {
        let root = self.paths().root().to_path_buf();
        let mut report = RetentionReport::default();
        let saved: HashSet<i64> = match self.saved_moment_ids() {
            Ok(saved) => saved,
            Err(err) => {
                report.failures.push(format!("Saved moments: {err:#}"));
                review.candidates.iter().map(|c| c.id).collect()
            }
        };
        let mut retained_text_ids = Vec::new();
        for candidate in review.candidates.iter().filter(|c| !saved.contains(&c.id)) {
            if !candidate.path.is_empty() {
                match clear_pixels(self, &root, candidate) {
                    Ok(()) => report.pixels_removed += 1,
                    Err(err) => report
                        .failures
                        .push(format!("Moment {}: {err:#}", candidate.id)),
                }
            }
            if candidate.remove_text || candidate.remove_vector || candidate.remove_metadata {
                retained_text_ids.push(candidate.id);
            }
        }
        report.texts_removed = review
            .candidates
            .iter()
            .filter(|c| c.remove_text && !saved.contains(&c.id))
            .count();
        if let Err(err) = self.clear_retained_text(&retained_text_ids) {
            report.texts_removed = 0;
            report
                .failures
                .push(format!("Screen text and metadata: {err:#}"));
        }
        match self.clear_activity_titles(&review.activity_titles) {
            Ok(cleared) => report.activity_titles_cleared = cleared,
            Err(err) => report.failures.push(format!("Activity titles: {err:#}")),
        }
        let burst_ids: Vec<String> = review
            .coding_agent_bursts
            .iter()
            .map(|(id, _)| id.clone())
            .collect();
        match self.delete_coding_agent_bursts(&burst_ids) {
            Ok(()) => report.agent_sessions_removed = burst_ids.len(),
            Err(err) => report
                .failures
                .push(format!("Coding agent sessions: {err:#}")),
        }
        match self.clear_orphaned_evidence(orphaned) {
            Ok(removed) => report.orphans_removed = removed,
            Err(err) => report.failures.push(format!("Screen text: {err:#}")),
        }
        Ok(report)
    }

    fn record_retention_pass(&self, now: DateTime<Utc>) {
        let stamp = now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let file = self.paths().root().join(LAST_PASS_FILE);
        if let Err(err) = crate::library::write_atomic(&file, stamp.as_bytes()) {
            log::warn!("could not record the retention pass: {err}");
        }
    }

    /// When retention last ran, from its marker file.
    pub fn last_retention_pass(&self) -> Option<DateTime<Utc>> {
        let stamp = std::fs::read_to_string(self.paths().root().join(LAST_PASS_FILE)).ok()?;
        crate::time::parse_iso(&stamp)
    }

    fn saved_moment_ids(&self) -> Result<HashSet<i64>> {
        self.with_db(|db| {
            let mut statement = db.prepare("SELECT snapshot_id FROM screen_bookmarks")?;
            let rows = statement.query_map([], |row| row.get(0))?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    /// Bookmark-aware at execution time (`ActivityStore.clearRetainedText`).
    /// FTS5 can't index its unindexed `snapshot_id`, so the exact rowids come
    /// through the metadata index, in bounded chunks.
    fn clear_retained_text(&self, ids: &[i64]) -> Result<()> {
        let mut snapshots: Vec<i64> = ids.iter().copied().filter(|id| *id > 0).collect();
        snapshots.sort_unstable();
        snapshots.dedup();
        if snapshots.is_empty() {
            return Ok(());
        }
        self.with_db(|db| {
            let tx = db.unchecked_transaction()?;
            let has_vectors = table_exists(&tx, "screen_embeddings")?;
            let unsaved = |column: &str| {
                format!(
                    "NOT EXISTS (SELECT 1 FROM screen_bookmarks AS bookmark \
                     WHERE bookmark.snapshot_id = {column})"
                )
            };
            for chunk in snapshots.chunks(400) {
                let placeholders = (1..=chunk.len())
                    .map(|index| format!("?{index}"))
                    .collect::<Vec<_>>()
                    .join(", ");
                let bindings = rusqlite::params_from_iter(chunk.iter());
                tx.execute(
                    &format!(
                        "DELETE FROM ocr_fts WHERE rowid IN (SELECT meta.rowid FROM ocr_metadata AS meta \
                         WHERE meta.snapshot_id IN ({placeholders}) AND {})",
                        unsaved("meta.snapshot_id")
                    ),
                    bindings.clone(),
                )?;
                if has_vectors {
                    tx.execute(
                        &format!(
                            "DELETE FROM screen_embeddings WHERE snapshot_id IN ({placeholders}) AND {}",
                            unsaved("screen_embeddings.snapshot_id")
                        ),
                        bindings.clone(),
                    )?;
                }
                tx.execute(
                    &format!(
                        "UPDATE screenshots SET window_title = '', source_url = '', document_name = '' \
                         WHERE id IN ({placeholders}) AND {}",
                        unsaved("screenshots.id")
                    ),
                    bindings.clone(),
                )?;
                tx.execute(
                    &format!(
                        "DELETE FROM ocr_metadata WHERE snapshot_id IN ({placeholders}) AND {}",
                        unsaved("ocr_metadata.snapshot_id")
                    ),
                    bindings,
                )?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    fn clear_activity_titles(&self, reviewed: &[RetentionActivityTitle]) -> Result<usize> {
        if reviewed.is_empty() {
            return Ok(0);
        }
        self.with_db(|db| {
            let tx = db.unchecked_transaction()?;
            let mut cleared = 0;
            for row in reviewed {
                cleared += tx.execute(
                    "UPDATE activity_blocks SET title = '' \
                     WHERE id = ?1 AND start = ?2 AND end = ?3 AND title = ?4",
                    params![row.id, row.start, row.end, row.title],
                )?;
            }
            tx.commit()?;
            Ok(cleared)
        })
    }

    fn orphaned_evidence(&self, cutoff: f64) -> Result<OrphanedEvidence> {
        self.with_db(|db| {
            let mut statement = db.prepare(
                "SELECT rowid, COALESCE(CAST(snapshot_id AS INTEGER), 0), CAST(ts AS REAL) FROM ocr_fts AS ocr \
                 WHERE CAST(ocr.ts AS REAL) < ?1 \
                 AND NOT EXISTS (SELECT 1 FROM screenshots WHERE id = CAST(ocr.snapshot_id AS INTEGER)) \
                 AND NOT EXISTS (SELECT 1 FROM screen_bookmarks WHERE snapshot_id = CAST(ocr.snapshot_id AS INTEGER))",
            )?;
            let text = statement
                .query_map([cutoff], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
                .collect::<rusqlite::Result<_>>()?;
            let vectors = if table_exists(db, "screen_embeddings")? {
                let mut statement = db.prepare(
                    "SELECT snapshot_id, ts FROM screen_embeddings AS vector WHERE ts < ?1 \
                 AND NOT EXISTS (SELECT 1 FROM screenshots WHERE id = vector.snapshot_id) \
                 AND NOT EXISTS (SELECT 1 FROM screen_bookmarks WHERE snapshot_id = vector.snapshot_id)",
                )?;
                statement
                    .query_map([cutoff], |row| Ok((row.get(0)?, row.get(1)?)))?
                    .collect::<rusqlite::Result<_>>()?
            } else {
                Vec::new()
            };
            Ok(OrphanedEvidence { text, vectors })
        })
    }

    /// New screenshots and bookmarks can make a reviewed orphan live again, so
    /// each is checked once more before it goes.
    fn clear_orphaned_evidence(&self, orphaned: &OrphanedEvidence) -> Result<usize> {
        if orphaned.is_empty() {
            return Ok(0);
        }
        self.with_db(|db| {
            let tx = db.unchecked_transaction()?;
            let mut removed = 0;
            for &(row_id, snapshot_id, ts) in &orphaned.text {
                let deleted = tx.execute(
                    "DELETE FROM ocr_fts WHERE rowid = ?1 \
                 AND COALESCE(CAST(snapshot_id AS INTEGER), 0) = ?2 AND CAST(ts AS REAL) = ?3 \
                 AND NOT EXISTS (SELECT 1 FROM screenshots WHERE id = CAST(ocr_fts.snapshot_id AS INTEGER)) \
                 AND NOT EXISTS (SELECT 1 FROM screen_bookmarks WHERE snapshot_id = CAST(ocr_fts.snapshot_id AS INTEGER))",
                    params![row_id, snapshot_id, ts],
                )?;
                if deleted > 0 {
                    tx.execute("DELETE FROM ocr_metadata WHERE rowid = ?1", [row_id])?;
                    removed += deleted;
                }
            }
            for &(snapshot_id, ts) in &orphaned.vectors {
                removed += tx.execute(
                    "DELETE FROM screen_embeddings WHERE snapshot_id = ?1 AND ts = ?2 \
                 AND NOT EXISTS (SELECT 1 FROM screenshots WHERE id = screen_embeddings.snapshot_id) \
                 AND NOT EXISTS (SELECT 1 FROM screen_bookmarks WHERE snapshot_id = screen_embeddings.snapshot_id)",
                    params![snapshot_id, ts],
                )?;
            }
            tx.commit()?;
            Ok(removed)
        })
    }

    /// The dry run for "Delete Captures in a Time Range…": every moment in
    /// `[start, end)`, saved ones left out unless they were chosen. A failed
    /// read is an error, never an empty scope.
    pub fn capture_deletion_review(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        includes_saved: bool,
    ) -> Result<CaptureDeletionReview> {
        self.with_db(|db| {
            let mut statement = db.prepare(
                "SELECT shot.id, shot.ts, shot.path, shot.app, bookmark.snapshot_id IS NOT NULL \
                 FROM screenshots AS shot \
                 LEFT JOIN screen_bookmarks AS bookmark ON bookmark.snapshot_id = shot.id \
                 WHERE shot.ts >= ?1 AND shot.ts < ?2 ORDER BY shot.ts, shot.id",
            )?;
            let all: Vec<ReviewedCapture> = statement
                .query_map(params![to_epoch(start), to_epoch(end)], |row| {
                    Ok(ReviewedCapture {
                        id: row.get(0)?,
                        ts: from_epoch(row.get(1)?),
                        path: row.get(2)?,
                        app: row.get(3)?,
                        is_saved: row.get(4)?,
                    })
                })?
                .collect::<rusqlite::Result<_>>()?;
            let saved_excluded = if includes_saved {
                0
            } else {
                all.iter().filter(|c| c.is_saved).count()
            };
            Ok(CaptureDeletionReview {
                start,
                end,
                includes_saved,
                captures: all
                    .into_iter()
                    .filter(|c| includes_saved || !c.is_saved)
                    .collect(),
                saved_excluded,
            })
        })
    }

    /// Deletes a reviewed range one moment at a time, so successful deletions
    /// stay consistent even if another fails, and returns what failed
    /// (`ScreenshotService.applyCaptureDeletionReview`). A moment saved since
    /// the review stays unless saved moments were chosen.
    pub fn apply_capture_deletion_review(
        &self,
        review: &CaptureDeletionReview,
    ) -> Result<Vec<String>> {
        let current =
            self.capture_deletion_review(review.start, review.end, review.includes_saved)?;
        if !review.covers(&current) {
            return Err(RetentionReviewError::ScopeChanged.into());
        }
        let dates: Vec<DateTime<Utc>> = current.captures.iter().map(|c| c.ts).collect();
        evidence::with_screen_mutation(self.paths().root(), &dates, EvidenceChange::Removal, || {
            let mut failures = Vec::new();
            for capture in &current.captures {
                let result = (|| {
                    if !review.includes_saved && self.is_moment_saved(capture.id)? {
                        return Ok(());
                    }
                    self.remove_screen_moments(&[capture.id]).map(|_| ())
                })();
                if let Err(err) = result {
                    let at = capture.ts.with_timezone(&Local).format("%H:%M:%S");
                    failures.push(format!("{} · {at}: {err:#}", capture.app));
                }
            }
            Ok(failures)
        })
    }

    fn is_moment_saved(&self, id: i64) -> Result<bool> {
        self.with_db(|db| {
            let count: i64 = db.query_row(
                "SELECT COUNT(*) FROM screen_bookmarks WHERE snapshot_id = ?1",
                [id],
                |row| row.get(0),
            )?;
            Ok(count > 0)
        })
    }
}

/// Removes the file, then every reference to it. Each picture vector goes
/// before its path: it was made from these pixels and must not outlive them
/// (`ActivityStore.clearScreenshotPath`).
fn clear_pixels(
    library: &Library,
    root: &std::path::Path,
    candidate: &RetentionCandidate,
) -> Result<()> {
    if let Some(file) = resolve_capture_path(root, &candidate.path) {
        match std::fs::remove_file(&file) {
            Ok(()) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(err) => return Err(err).context("could not delete a screen capture"),
        }
    }
    library.with_db(|db| {
        if table_exists(db, "screen_image_embeddings")? {
            db.execute(
                "DELETE FROM screen_image_embeddings \
                 WHERE snapshot_id IN (SELECT id FROM screenshots WHERE path = ?1 AND path != '')",
                [&candidate.path],
            )?;
        }
        db.execute(
            "UPDATE screenshots SET path = '' WHERE path = ?1 AND path != ''",
            [&candidate.path],
        )?;
        Ok(())
    })
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

    /// The table a Mac creates for picture vectors (`ScreenImageEmbeddings`).
    fn mac_image_vectors(library: &Library) {
        library
            .with_db(|db| {
                db.execute_batch(
                    "CREATE TABLE IF NOT EXISTS screen_image_embeddings (snapshot_id INTEGER PRIMARY KEY \
                 REFERENCES screenshots(id) ON DELETE CASCADE, vec BLOB NOT NULL, model_id TEXT NOT NULL)",
                )?;
                Ok(())
            })
            .unwrap();
    }

    fn image_vector_count(library: &Library) -> i64 {
        library
            .with_db(|db| {
                Ok(
                    db.query_row("SELECT COUNT(*) FROM screen_image_embeddings", [], |row| {
                        row.get(0)
                    })?,
                )
            })
            .unwrap()
    }

    fn sealed_moment(
        library: &Library,
        dir: &std::path::Path,
        ts: DateTime<Utc>,
        name: &str,
    ) -> i64 {
        let file = dir.join("activity/2026-01-01/shots").join(name);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, b"sealed").unwrap();
        library
            .record_screen_moment(&NewScreenMoment {
                ts,
                app: "Firefox".into(),
                window_title: "Page".into(),
                text: "some text".into(),
                path: file.display().to_string(),
                ..Default::default()
            })
            .unwrap()
    }

    #[test]
    fn expired_pixels_take_their_picture_vector_with_them() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        mac_image_vectors(&library);
        let now = Utc::now();
        let old = now - chrono::Duration::days(20);
        let expired = sealed_moment(&library, dir.path(), old, "a.heic.enc");
        let saved = sealed_moment(&library, dir.path(), old, "b.heic.enc");
        library.save_moment(saved, "keep").unwrap();
        library
            .with_db(|db| {
                for id in [expired, saved] {
                    db.execute(
                        "INSERT INTO screen_image_embeddings (snapshot_id, vec, model_id) VALUES (?1, x'00', 'm')",
                        [id],
                    )?;
                }
                Ok(())
            })
            .unwrap();
        let keep = Settings {
            keep_ocr_text_forever: true,
            ..Settings::default()
        };
        let report = library.apply_retention(&keep, now).unwrap();
        assert_eq!(report.pixels_removed, 1);
        assert_eq!(library.screen_moment(expired).unwrap().unwrap().path, "");
        assert!(
            !dir.path()
                .join("activity/2026-01-01/shots/a.heic.enc")
                .exists()
        );
        assert!(
            dir.path()
                .join("activity/2026-01-01/shots/b.heic.enc")
                .exists()
        );
        // Only the saved moment still has pixels, and only it keeps a vector.
        assert_eq!(image_vector_count(&library), 1);
    }

    #[test]
    fn a_review_counts_without_deleting_and_saved_moments_stay_out() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let now = Utc::now();
        let old = now - chrono::Duration::days(20);
        let expired = sealed_moment(&library, dir.path(), old, "a.heic.enc");
        let saved = sealed_moment(&library, dir.path(), old, "b.heic.enc");
        library.save_moment(saved, "keep").unwrap();
        library
            .append_activity(
                "Firefox",
                "Old page",
                old,
                old + chrono::Duration::minutes(5),
            )
            .unwrap();
        let review = library.retention_review(7, false, now, true).unwrap();
        assert_eq!(review.pixel_count(), 1);
        assert_eq!(review.text_count(), 1);
        assert_eq!(review.metadata_count(), 1);
        assert_eq!(review.activity_titles.len(), 1);
        assert_eq!(review.saved_count, 1);
        assert_eq!(review.bytes, 6);
        // The dry run removed nothing.
        assert!(
            library
                .screen_moment(expired)
                .unwrap()
                .unwrap()
                .text
                .is_some()
        );
        assert_eq!(
            library.retention_review(7, false, now, true).unwrap(),
            review
        );

        let keep = library.retention_review(7, true, now, false).unwrap();
        assert_eq!(keep.text_count(), 0);
        assert_eq!(keep.metadata_count(), 0);
        assert_eq!(keep.pixel_count(), 1);

        // Nothing within the longer window is listed.
        let none = library.retention_review(30, false, now, false).unwrap();
        assert!(none.is_empty());
    }

    #[test]
    fn a_review_covers_shrinking_but_not_growing_scope() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let now = Utc::now();
        let old = now - chrono::Duration::days(20);
        let first = sealed_moment(&library, dir.path(), old, "a.heic.enc");
        let review = library.retention_review(7, false, now, false).unwrap();
        // More data than was reviewed: nothing is deleted.
        let second = sealed_moment(&library, dir.path(), old, "b.heic.enc");
        let error = library.apply_retention_review(&review, now).unwrap_err();
        assert!(error.downcast_ref::<RetentionReviewError>().is_some());
        assert!(
            library
                .screen_moment(first)
                .unwrap()
                .unwrap()
                .text
                .is_some()
        );
        // Newly saved moments may shrink it.
        library.save_moment(second, "keep").unwrap();
        let report = library.apply_retention_review(&review, now).unwrap();
        assert_eq!(report.pixels_removed, 1);
        assert_eq!(library.screen_moment(first).unwrap().unwrap().text, None);
        assert!(
            library
                .screen_moment(second)
                .unwrap()
                .unwrap()
                .text
                .is_some()
        );
    }

    #[test]
    fn a_reviewed_cleanup_retracts_journals_but_a_scheduled_pass_does_not() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let now = Utc::now();
        let old = now - chrono::Duration::days(20);
        let day = crate::time::local_day(old);
        let meta = serde_json::from_value(serde_json::json!({
            "version": 2,
            "quality": "complete",
            "generatedAt": 800_000_000.0,
        }))
        .unwrap();
        library.save_digest(day, "the digest", &meta).unwrap();
        sealed_moment(&library, dir.path(), old, "a.heic.enc");

        // Retention expires evidence; the digest and overnight memory stay.
        library.apply_retention(&Settings::default(), now).unwrap();
        assert!(library.journal_path(day).exists());
        assert_eq!(evidence::read_state(dir.path()).unwrap().revision, 0);

        sealed_moment(&library, dir.path(), old, "b.heic.enc");
        let review = library.retention_review(7, false, now, false).unwrap();
        library.apply_retention_review(&review, now).unwrap();
        assert!(!library.journal_path(day).exists());
        assert_eq!(evidence::read_state(dir.path()).unwrap().revision, 1);
    }

    #[test]
    fn range_deletion_reviews_first_and_keeps_saved_moments_unless_chosen() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let now = Utc::now();
        let start = now - chrono::Duration::hours(2);
        let first = sealed_moment(&library, dir.path(), start, "a.heic.enc");
        let saved = sealed_moment(
            &library,
            dir.path(),
            start + chrono::Duration::minutes(1),
            "b.heic.enc",
        );
        let outside = sealed_moment(&library, dir.path(), now, "c.heic.enc");
        library.save_moment(saved, "keep").unwrap();
        let end = start + chrono::Duration::minutes(2);

        let review = library.capture_deletion_review(start, end, false).unwrap();
        assert_eq!(review.captures.len(), 1);
        assert_eq!(review.pixel_count(), 1);
        assert_eq!(review.saved_excluded, 1);
        assert_eq!(review.saved_included(), 0);
        // Nothing went yet.
        assert!(library.screen_moment(first).unwrap().is_some());

        assert!(
            library
                .apply_capture_deletion_review(&review)
                .unwrap()
                .is_empty()
        );
        assert!(library.screen_moment(first).unwrap().is_none());
        assert!(library.screen_moment(saved).unwrap().is_some());
        assert!(library.screen_moment(outside).unwrap().is_some());
        assert!(
            evidence::read_state(dir.path())
                .unwrap()
                .invalidated_activity_days
                .is_some()
        );

        let with_saved = library.capture_deletion_review(start, end, true).unwrap();
        assert_eq!(with_saved.saved_included(), 1);
        library.apply_capture_deletion_review(&with_saved).unwrap();
        assert!(library.screen_moment(saved).unwrap().is_none());
    }

    #[test]
    fn a_range_review_refuses_moments_added_since() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let now = Utc::now();
        let start = now - chrono::Duration::hours(2);
        let end = start + chrono::Duration::minutes(5);
        let first = sealed_moment(&library, dir.path(), start, "a.heic.enc");
        let review = library.capture_deletion_review(start, end, false).unwrap();
        sealed_moment(
            &library,
            dir.path(),
            start + chrono::Duration::minutes(1),
            "b.heic.enc",
        );
        let error = library.apply_capture_deletion_review(&review).unwrap_err();
        assert!(error.downcast_ref::<RetentionReviewError>().is_some());
        assert!(library.screen_moment(first).unwrap().is_some());
    }
}
