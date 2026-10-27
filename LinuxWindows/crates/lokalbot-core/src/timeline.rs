//! Day memory reads and writes: activity blocks, screen moments, work
//! sessions and Timeline's session rail (`TimelineWorkSession.swift`), and
//! the per-day projection Today and Timeline share
//! (`DayActivityProjection.swift`).

use std::collections::{HashMap, HashSet};

use anyhow::{Result, bail};
use chrono::{DateTime, NaiveDate, Utc};
use rusqlite::{OptionalExtension as _, params};
use uuid::Uuid;

use crate::library::Library;
use crate::model::*;
use crate::time::{from_epoch, to_epoch};

/// Consecutive blocks at most this far apart belong to one session.
pub const SESSION_MAXIMUM_GAP_SECONDS: f64 = 5.0 * 60.0;
/// A session this long starts a new one at the next non-overlapping block.
pub const SESSION_MAXIMUM_DURATION_SECONDS: f64 = 45.0 * 60.0;

/// Shell, lock-screen and login processes that are never "work". The first
/// five are the macOS list; the rest are their Linux and Windows equivalents.
const SYSTEM_APPS: &[&str] = &[
    "loginwindow",
    "windowserver",
    "systemuiserver",
    "controlcenter",
    "notificationcenter",
    // Windows
    "lockapp",
    "logonui",
    "shellexperiencehost",
    "startmenuexperiencehost",
    "searchhost",
    "searchapp",
    "searchui",
    "windows shell experience host",
    "windows default lock screen",
    "task switching",
    "task view",
    // Linux
    "gnome-shell",
    "plasmashell",
    "kwin",
    "kwin_x11",
    "kwin_wayland",
    "xfwm4",
    "xfce4-panel",
    "xfdesktop",
    "gdm",
    "gdm-greeter",
    "lightdm",
    "sddm",
    "gnome-screensaver",
    "xscreensaver",
];

const GENERIC_TITLES: &[&str] = &[
    "",
    "home",
    "login",
    "login window",
    "new tab",
    "timeline",
    "today",
    "unknown",
];

/// Trailing title segments that are browser chrome, not page content.
const BROWSER_CHROME_MARKERS: &[&str] = &[
    "google chrome",
    "google chrome beta",
    "google chrome canary",
    "chromium",
    "microsoft edge",
    "microsoft\u{200b} edge",
    "brave",
    "vivaldi",
    "opera",
    "arc",
    "mozilla firefox",
    "firefox",
    "librewolf",
    "audio playing",
    "audio muted",
    "camera recording",
    "microphone recording",
    "camera and microphone recording",
    "high memory usage",
    "pinned",
    "bluetooth device connected",
    "usb device connected",
];

/// Whether `app` is a shell/system process rather than user work.
pub fn is_system_app(app: &str) -> bool {
    let normalized = app.trim().to_lowercase();
    SYSTEM_APPS.contains(&normalized.as_str())
}

fn is_browser_chrome_segment(segment: &str) -> bool {
    let lowered = segment.trim().to_lowercase();
    BROWSER_CHROME_MARKERS.contains(&lowered.as_str()) || lowered.starts_with("part of group ")
}

/// "Page - Audio playing - Google Chrome" → "Page"; "Page — Mozilla Firefox" → "Page".
pub fn strip_browser_chrome(title: &str) -> String {
    for separator in [" - ", " — "] {
        let parts: Vec<&str> = title.split(separator).collect();
        if parts.len() < 2 {
            continue;
        }
        if let Some(cut) = parts.iter().position(|p| is_browser_chrome_segment(p))
            && cut > 0
        {
            return parts[..cut].join(separator);
        }
    }
    title.to_string()
}

/// "Brief.odt - LibreOffice Writer" → "Brief.odt" when the app is
/// "LibreOffice Writer". Linux and Windows window titles usually end with the
/// app's name, which macOS titles do not.
pub fn strip_app_suffix(title: &str, app: &str) -> String {
    let app = app.trim();
    if app.is_empty() {
        return title.to_string();
    }
    for separator in [" - ", " — ", " – ", " | "] {
        if let Some(index) = title.rfind(separator) {
            let (head, tail) = (&title[..index], &title[index + separator.len()..]);
            if tail.trim().eq_ignore_ascii_case(app) && !head.trim().is_empty() {
                return head.trim().to_string();
            }
        }
    }
    title.to_string()
}

/// The grouping title of a block, or `None` for generic or app-named titles.
pub fn cleaned_title(raw: &str, app: &str) -> Option<String> {
    let compact = raw
        .replace('\n', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let compact = strip_app_suffix(&strip_browser_chrome(compact.trim()), app);
    let normalized = compact.to_lowercase();
    if GENERIC_TITLES.contains(&normalized.as_str()) || normalized == app.trim().to_lowercase() {
        return None;
    }
    Some(compact)
}

/// Union length of the blocks' intervals, in seconds.
pub fn merged_duration(blocks: &[&ActivityBlock]) -> f64 {
    let mut ordered: Vec<&&ActivityBlock> = blocks.iter().collect();
    ordered.sort_by_key(|b| b.start);
    let Some(first) = ordered.first() else {
        return 0.0;
    };
    let mut total = 0.0;
    let (mut start, mut end) = (first.start, first.end);
    for block in ordered.iter().skip(1) {
        if block.start <= end {
            end = end.max(block.end);
        } else {
            total += seconds(end - start);
            start = block.start;
            end = block.end;
        }
    }
    total += seconds(end - start);
    total.max(0.0)
}

fn seconds(delta: chrono::Duration) -> f64 {
    delta.num_milliseconds() as f64 / 1000.0
}

struct Titled<'a> {
    block: &'a ActivityBlock,
    title: Option<String>,
}

/// App activity grouped into human-scale sessions (`TimelineWorkSession.sessions`):
/// system apps dropped, gaps of at most 5 minutes merged, a new session after
/// 45 minutes or when a sustained unseen title appears after 10 minutes.
pub fn activity_sessions(source: &[ActivityBlock]) -> Vec<WorkSession> {
    let mut blocks: Vec<&ActivityBlock> = source
        .iter()
        .filter(|b| b.end > b.start && !is_system_app(&b.app))
        .collect();
    blocks.sort_by(|a, b| a.start.cmp(&b.start).then(a.id.cmp(&b.id)));
    let titled: Vec<Titled> = blocks
        .into_iter()
        .map(|block| Titled {
            block,
            title: cleaned_title(&block.title, &block.app),
        })
        .collect();
    let Some(first) = titled.first() else {
        return Vec::new();
    };

    let mut groups: Vec<Vec<&Titled>> = Vec::new();
    let mut current = vec![first];
    let mut current_end = first.block.end;
    let mut seen: HashSet<String> = first.title.iter().map(|t| t.to_lowercase()).collect();
    for observed in titled.iter().skip(1) {
        let block = observed.block;
        let title = observed.title.as_ref().map(|t| t.to_lowercase());
        let elapsed = seconds(block.start - current[0].block.start);
        // Short tool switches stay together; a sustained, unseen document
        // after ten minutes is a boundary. Overlapping blocks never split.
        let sustained_change = elapsed >= 600.0
            && block.duration_seconds() >= 180.0
            && title.as_ref().is_some_and(|t| !seen.contains(t));
        let new_segment = block.start >= current_end
            && (elapsed >= SESSION_MAXIMUM_DURATION_SECONDS.max(60.0) || sustained_change);
        if seconds(block.start - current_end) <= SESSION_MAXIMUM_GAP_SECONDS && !new_segment {
            current.push(observed);
            current_end = current_end.max(block.end);
        } else {
            groups.push(std::mem::take(&mut current));
            current = vec![observed];
            current_end = block.end;
            seen.clear();
        }
        if let Some(title) = title {
            seen.insert(title);
        }
    }
    groups.push(current);
    groups.iter().filter_map(|g| make_session(g)).collect()
}

fn make_session(group: &[&Titled]) -> Option<WorkSession> {
    let blocks: Vec<&ActivityBlock> = group.iter().map(|t| t.block).collect();
    let first = blocks.first()?;
    let end = blocks.iter().map(|b| b.end).max().unwrap_or(first.end);

    let mut by_app: HashMap<&str, Vec<&ActivityBlock>> = HashMap::new();
    let mut first_app_index: HashMap<&str, usize> = HashMap::new();
    for (index, block) in blocks.iter().enumerate() {
        by_app.entry(block.app.as_str()).or_default().push(block);
        first_app_index.entry(block.app.as_str()).or_insert(index);
    }
    let app_durations: HashMap<&str, f64> = by_app
        .iter()
        .map(|(app, b)| (*app, merged_duration(b)))
        .collect();
    let mut apps: Vec<&str> = app_durations.keys().copied().collect();
    apps.sort_by(|a, b| {
        app_durations[b]
            .partial_cmp(&app_durations[a])
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(first_app_index[a].cmp(&first_app_index[b]))
    });
    let active = merged_duration(&blocks);

    // Titles ranked by their own active time; ties keep first appearance.
    let mut by_title: HashMap<String, (String, usize, Vec<&ActivityBlock>)> = HashMap::new();
    for (index, observed) in group.iter().enumerate() {
        let Some(title) = &observed.title else {
            continue;
        };
        by_title
            .entry(title.to_lowercase())
            .or_insert_with(|| (title.clone(), index, Vec::new()))
            .2
            .push(observed.block);
    }
    let mut evidence: Vec<(String, usize, f64)> = by_title
        .into_values()
        .map(|(display, index, blocks)| (display, index, merged_duration(&blocks)))
        .collect();
    evidence.sort_by(|a, b| {
        b.2.partial_cmp(&a.2)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.1.cmp(&b.1))
    });
    let representative: Vec<&str> = evidence
        .iter()
        .filter(|(_, _, duration)| *duration >= active * 0.2)
        .map(|(title, _, _)| title.as_str())
        .collect();
    // Apps glanced at for seconds (a password prompt, a notification) stay in
    // `apps` but don't inflate the title's count.
    let used_apps: Vec<&str> = apps
        .iter()
        .copied()
        .filter(|app| app_durations[app] >= 60.0)
        .collect();
    let title = if representative.is_empty() {
        app_summary(if used_apps.is_empty() {
            &apps
        } else {
            &used_apps
        })
    } else {
        representative
            .iter()
            .take(2)
            .copied()
            .collect::<Vec<_>>()
            .join(" · ")
    };

    let mut switches = 0;
    let mut previous: Option<String> = None;
    for block in &blocks {
        let app = block.app.trim().to_lowercase();
        if previous.as_ref().is_some_and(|p| *p != app) {
            switches += 1;
        }
        previous = Some(app);
    }

    Some(WorkSession {
        id: format!("work-{}", first.id),
        title,
        title_names_apps: representative.is_empty(),
        start: first.start,
        end,
        active_seconds: active,
        primary_app: apps
            .first()
            .map_or_else(|| first.app.clone(), |a| a.to_string()),
        apps: apps.iter().map(|a| a.to_string()).collect(),
        block_ids: blocks.iter().map(|b| b.id).collect(),
        notable_titles: evidence.into_iter().map(|(title, _, _)| title).collect(),
        context_switch_count: switches,
        meeting_id: None,
    })
}

/// "Claude", "Claude, Firefox" or "Claude, Firefox +2": the two busiest
/// apps, then how many more (`TimelineWorkSession.appSummary`).
pub fn app_summary(apps: &[impl AsRef<str>]) -> String {
    let named = apps
        .iter()
        .take(2)
        .map(AsRef::as_ref)
        .collect::<Vec<_>>()
        .join(", ");
    if apps.len() > 2 {
        format!("{named} +{}", apps.len() - 2)
    } else {
        named
    }
}

/// Stretches with nothing recorded at least this long get an "Away" row.
pub const AWAY_MINIMUM_GAP_SECONDS: f64 = 30.0 * 60.0;

/// A row of Timeline's session rail (`TimelineRailRow`): a session or
/// meeting by its index in the day's sessions, or a long stretch with no
/// recorded activity between them.
#[derive(Clone, Debug, PartialEq)]
pub enum RailRow {
    Session(usize),
    Away {
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    },
}

/// The rail for `sessions`, ordered by start as `work_sessions` returns
/// them, with an away row wherever nothing was recorded for at least
/// `minimum_gap_seconds`. Sessions overlap (a meeting runs over the work
/// beside it), so a gap starts at the latest end seen so far.
pub fn rail_rows(sessions: &[WorkSession], minimum_gap_seconds: f64) -> Vec<RailRow> {
    let mut rows = Vec::with_capacity(sessions.len());
    let mut latest_end: Option<DateTime<Utc>> = None;
    for (index, session) in sessions.iter().enumerate() {
        if let Some(latest) = latest_end
            && seconds(session.start - latest) >= minimum_gap_seconds
        {
            rows.push(RailRow::Away {
                start: latest,
                end: session.start,
            });
        }
        rows.push(RailRow::Session(index));
        latest_end = Some(latest_end.map_or(session.end, |latest| latest.max(session.end)));
    }
    rows
}

/// When a meeting item ends on the timeline (`CaptureTrackItem.meetingEnd`).
pub fn meeting_end(meeting: &Meeting, now: DateTime<Utc>) -> DateTime<Utc> {
    if let Some(ended) = meeting.ended_at {
        return ended;
    }
    if let Some(recorded) = meeting.recorded_duration {
        return meeting.started_at + chrono::Duration::milliseconds((recorded * 1000.0) as i64);
    }
    now.max(meeting.started_at + chrono::Duration::seconds(60))
}

/// A recorded meeting as a timeline session.
pub fn meeting_session(meeting: &Meeting, now: DateTime<Utc>) -> WorkSession {
    let end = meeting_end(meeting, now);
    WorkSession {
        id: format!("meeting-{}", crate::ids::uuid_upper(&meeting.id)),
        title: meeting.display_title(),
        title_names_apps: false,
        start: meeting.started_at,
        end,
        active_seconds: seconds(end - meeting.started_at).max(0.0),
        primary_app: meeting.app_name.clone(),
        apps: vec![meeting.app_name.clone()],
        block_ids: Vec::new(),
        notable_titles: Vec::new(),
        context_switch_count: 0,
        meeting_id: Some(meeting.id),
    }
}

/// Work sessions from `blocks` interleaved with `meetings`, by start
/// (`TimelineDayItem.items`). Meeting sessions have `meeting_id` set.
pub fn work_sessions(blocks: &[ActivityBlock], meetings: &[Meeting]) -> Vec<WorkSession> {
    let now = Utc::now();
    let mut sessions = activity_sessions(blocks);
    sessions.extend(meetings.iter().map(|m| meeting_session(m, now)));
    sessions.sort_by_key(|s| s.start);
    sessions
}

/// Blocks clipped to `[start, end)`, system apps removed.
pub fn clip_blocks(
    blocks: &[ActivityBlock],
    start: DateTime<Utc>,
    end: DateTime<Utc>,
) -> Vec<ActivityBlock> {
    blocks
        .iter()
        .filter(|b| !is_system_app(&b.app))
        .filter_map(|b| {
            let clipped_start = b.start.max(start);
            let clipped_end = b.end.min(end);
            (clipped_end > clipped_start).then(|| ActivityBlock {
                id: b.id,
                app: b.app.clone(),
                title: b.title.clone(),
                start: clipped_start,
                end: clipped_end,
            })
        })
        .collect()
}

/// Per-app union time, longest first.
pub fn app_usage(blocks: &[ActivityBlock]) -> Vec<AppUsage> {
    let mut by_app: HashMap<&str, Vec<&ActivityBlock>> = HashMap::new();
    for block in blocks {
        by_app.entry(block.app.as_str()).or_default().push(block);
    }
    let mut usage: Vec<AppUsage> = by_app
        .into_iter()
        .map(|(app, blocks)| AppUsage {
            app: app.to_string(),
            seconds: merged_duration(&blocks),
        })
        .collect();
    usage.sort_by(|a, b| {
        b.seconds
            .partial_cmp(&a.seconds)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.app.cmp(&b.app))
    });
    usage
}

/// Columns for `screen_moment_from_row`. The text comes through the
/// `ocr_metadata` index when present, else by scanning `ocr_fts` (libraries
/// opened read-only before the app ever migrated them).
pub(crate) fn screen_columns(db: &rusqlite::Connection) -> Result<String> {
    let text = if table_exists(db, "ocr_metadata")? {
        "(SELECT ocr.text FROM ocr_metadata AS meta JOIN ocr_fts AS ocr ON ocr.rowid = meta.rowid \
         WHERE meta.snapshot_id = shot.id ORDER BY meta.rowid LIMIT 1)"
    } else if table_exists(db, "ocr_fts")? {
        "(SELECT ocr.text FROM ocr_fts AS ocr WHERE CAST(ocr.snapshot_id AS INTEGER) = shot.id \
         ORDER BY ocr.rowid LIMIT 1)"
    } else {
        "NULL"
    };
    Ok(format!(
        "shot.id, shot.ts, shot.app, shot.window_title, shot.capture_trigger, shot.path, \
         shot.source_url, shot.document_name, shot.meeting_id, shot.privacy_redactions, {text}, \
         bookmark.note, bookmark.snapshot_id IS NOT NULL"
    ))
}

pub(crate) fn screen_moment_from_row(row: &rusqlite::Row) -> rusqlite::Result<ScreenMoment> {
    let meeting: String = row.get(8)?;
    Ok(ScreenMoment {
        id: row.get(0)?,
        ts: from_epoch(row.get(1)?),
        app: row.get(2)?,
        window_title: row.get(3)?,
        capture_trigger: row.get(4)?,
        path: row.get(5)?,
        source_url: row.get(6)?,
        document_name: row.get(7)?,
        meeting_id: Uuid::parse_str(&meeting).ok(),
        privacy_redactions: row.get(9)?,
        text: row.get(10)?,
        saved_note: row.get(11)?,
        is_saved: row.get(12)?,
    })
}

/// A screen moment to store (`ActivityStore.insertScreenshot`). `path` is
/// empty for text-only captures; `text` empty when none was kept.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct NewScreenMoment {
    pub ts: DateTime<Utc>,
    pub app: String,
    pub window_title: String,
    /// `app_switch`, `window_change`, `click`, `typing_pause`, `scroll_settled`,
    /// `clipboard_change`, `interval` or `manual`.
    pub trigger: String,
    pub path: String,
    pub text: String,
    /// `accessibility`, `ocr` or `hybrid`, with `_redacted` when redacted.
    pub text_source: String,
    pub source_url: String,
    pub document_name: String,
    pub meeting_id: Option<Uuid>,
    pub privacy_redactions: i64,
}

impl Library {
    /// Inserts a finished (or growing) activity block and returns its id.
    pub fn append_activity(
        &self,
        app: &str,
        title: &str,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Result<i64> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        self.with_db(|db| {
            db.execute(
                "INSERT INTO activity_blocks (app, title, start, end) VALUES (?1, ?2, ?3, ?4)",
                params![app, title, to_epoch(start), to_epoch(end.max(start))],
            )?;
            Ok(db.last_insert_rowid())
        })
    }

    /// Stores a screen moment and its searchable text; returns its id.
    pub fn record_screen_moment(&self, moment: &NewScreenMoment) -> Result<i64> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        self.with_db(|db| {
            let tx = db.unchecked_transaction()?;
            tx.execute(
                "INSERT INTO screenshots (ts, path, app, window_title, capture_trigger, perceptual_hash, \
                 source_url, document_name, meeting_id, privacy_redactions) \
                 VALUES (?1, ?2, ?3, ?4, ?5, '', ?6, ?7, ?8, ?9)",
                params![
                    to_epoch(moment.ts),
                    moment.path,
                    moment.app,
                    moment.window_title,
                    if moment.trigger.is_empty() { "interval" } else { moment.trigger.as_str() },
                    moment.source_url,
                    moment.document_name,
                    moment.meeting_id.map(|id| crate::ids::uuid_upper(&id)).unwrap_or_default(),
                    moment.privacy_redactions.max(0),
                ],
            )?;
            let id = tx.last_insert_rowid();
            if !moment.text.is_empty() {
                tx.execute(
                    "INSERT INTO ocr_fts (text, window_title, ts, app, text_source, snapshot_id) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![
                        moment.text,
                        moment.window_title,
                        to_epoch(moment.ts),
                        moment.app,
                        if moment.text_source.is_empty() { "ocr" } else { moment.text_source.as_str() },
                        id,
                    ],
                )?;
                tx.execute(
                    "INSERT OR REPLACE INTO ocr_metadata (rowid, snapshot_id, ts) VALUES (?1, ?2, ?3)",
                    params![tx.last_insert_rowid(), id, to_epoch(moment.ts)],
                )?;
            }
            tx.commit()?;
            Ok(id)
        })
    }

    /// Saves (or re-notes) a moment; saving again keeps its creation time.
    /// Saved moments are exempt from retention.
    pub fn save_moment(&self, id: i64, note: &str) -> Result<()> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        self.with_db(|db| {
            db.execute(
                "INSERT INTO screen_bookmarks (snapshot_id, note, created_at) VALUES (?1, ?2, ?3) \
                 ON CONFLICT(snapshot_id) DO UPDATE SET note = excluded.note",
                params![id, note.trim(), to_epoch(Utc::now())],
            )?;
            Ok(())
        })
    }

    /// Removes a saved moment's bookmark (the capture itself stays).
    pub fn unsave_moment(&self, id: i64) -> Result<()> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        self.with_db(|db| {
            db.execute("DELETE FROM screen_bookmarks WHERE snapshot_id = ?1", [id])?;
            Ok(())
        })
    }

    /// Moves the end of a growing block forward.
    pub fn extend_activity(&self, id: i64, end: DateTime<Utc>) -> Result<()> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        self.with_db(|db| {
            db.execute(
                "UPDATE activity_blocks SET end = MAX(start, ?2) WHERE id = ?1",
                params![id, to_epoch(end)],
            )?;
            Ok(())
        })
    }

    /// Blocks overlapping `[start, end)`, oldest first, unclipped.
    pub fn activity_blocks(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Result<Vec<ActivityBlock>> {
        self.with_db(|db| {
            if !table_exists(db, "activity_blocks")? {
                return Ok(Vec::new());
            }
            let mut statement = db.prepare(
                "SELECT id, app, title, start, end FROM activity_blocks \
                 WHERE end > ?1 AND start < ?2 ORDER BY start, id",
            )?;
            let rows = statement.query_map(params![to_epoch(start), to_epoch(end)], |row| {
                Ok(ActivityBlock {
                    id: row.get(0)?,
                    app: row.get(1)?,
                    title: row.get(2)?,
                    start: from_epoch(row.get(3)?),
                    end: from_epoch(row.get(4)?),
                })
            })?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    /// Captured screen moments in `[start, end)`, oldest first, with their
    /// text (when kept) and saved note.
    pub fn screen_moments(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Result<Vec<ScreenMoment>> {
        self.with_db(|db| {
            if !table_exists(db, "screenshots")? {
                return Ok(Vec::new());
            }
            let columns = screen_columns(db)?;
            let mut statement = db.prepare(&format!(
                "SELECT {columns} FROM screenshots AS shot \
                 LEFT JOIN screen_bookmarks AS bookmark ON bookmark.snapshot_id = shot.id \
                 WHERE shot.ts >= ?1 AND shot.ts < ?2 ORDER BY shot.ts, shot.id"
            ))?;
            let rows = statement.query_map(
                params![to_epoch(start), to_epoch(end)],
                screen_moment_from_row,
            )?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    /// One screen moment by id.
    pub fn screen_moment(&self, id: i64) -> Result<Option<ScreenMoment>> {
        self.with_db(|db| {
            if !table_exists(db, "screenshots")? {
                return Ok(None);
            }
            let columns = screen_columns(db)?;
            let mut statement = db.prepare(&format!(
                "SELECT {columns} FROM screenshots AS shot \
                 LEFT JOIN screen_bookmarks AS bookmark ON bookmark.snapshot_id = shot.id WHERE shot.id = ?1"
            ))?;
            Ok(statement.query_row([id], screen_moment_from_row).optional()?)
        })
    }

    /// Everything Today and Timeline show for one local day.
    pub fn day_activity(&self, day: NaiveDate) -> Result<DayActivity> {
        let (start, end) = crate::time::local_day_bounds(day);
        let blocks = clip_blocks(&self.activity_blocks(start, end)?, start, end);
        let meetings: Vec<Meeting> = self
            .list_own_meetings()?
            .into_iter()
            .filter(|m| crate::time::local_day(m.started_at) == day)
            .collect();
        let sessions = work_sessions(&blocks, &meetings);
        let tracked_seconds = sessions
            .iter()
            .filter(|s| s.meeting_id.is_none())
            .map(|s| s.active_seconds)
            .sum();
        let moment_count = self.with_db(|db| {
            if !table_exists(db, "screenshots")? {
                return Ok(0);
            }
            let count: i64 = db.query_row(
                "SELECT COUNT(*) FROM screenshots WHERE ts >= ?1 AND ts < ?2",
                params![to_epoch(start), to_epoch(end)],
                |row| row.get(0),
            )?;
            Ok(count.max(0) as usize)
        })?;
        Ok(DayActivity {
            day: Some(day),
            app_usage: app_usage(&blocks),
            blocks,
            sessions,
            tracked_seconds,
            moment_count,
            meeting_count: meetings.len(),
        })
    }

    /// The newest activity end, if any (`ActivityStore.latestActivityEnd`).
    pub fn latest_activity_end(&self) -> Result<Option<DateTime<Utc>>> {
        self.with_db(|db| {
            if !table_exists(db, "activity_blocks")? {
                return Ok(None);
            }
            let latest: Option<f64> =
                db.query_row("SELECT MAX(end) FROM activity_blocks", [], |row| row.get(0))?;
            Ok(latest.map(from_epoch))
        })
    }
}

pub(crate) fn table_exists(db: &rusqlite::Connection, name: &str) -> Result<bool> {
    Ok(db
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE name = ?1",
            [name],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    fn at(minute: i64) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 15, 9, 0, 0).unwrap() + chrono::Duration::minutes(minute)
    }

    fn block(id: i64, app: &str, title: &str, start: i64, end: i64) -> ActivityBlock {
        ActivityBlock {
            id,
            app: app.into(),
            title: title.into(),
            start: at(start),
            end: at(end),
        }
    }

    #[test]
    fn short_gaps_merge_and_long_gaps_split() {
        let sessions = activity_sessions(&[
            block(
                1,
                "Visual Studio Code",
                "main.rs - lokalbot - Visual Studio Code",
                0,
                6,
            ),
            block(2, "Firefox", "Docs — Mozilla Firefox", 8, 12),
            block(3, "Slack", "#studio", 50, 55),
        ]);
        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].block_ids, [1, 2]);
        assert_eq!(sessions[0].context_switch_count, 1);
        assert_eq!(sessions[0].active_seconds, 10.0 * 60.0);
        assert_eq!(sessions[0].title, "main.rs - lokalbot · Docs");
        assert_eq!(sessions[1].block_ids, [3]);
        assert_eq!(sessions[1].title, "#studio");
    }

    #[test]
    fn long_sessions_split_at_forty_five_minutes() {
        let sessions = activity_sessions(&[
            block(1, "LibreOffice Writer", "Brief.odt", 0, 30),
            block(2, "LibreOffice Writer", "Brief.odt", 30, 46),
            block(3, "LibreOffice Writer", "Brief.odt", 46, 60),
        ]);
        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[1].block_ids, [3]);
    }

    #[test]
    fn a_sustained_new_title_after_ten_minutes_splits() {
        let sessions = activity_sessions(&[
            block(1, "Figma", "Logo lockups", 0, 12),
            block(2, "Figma", "Storyboard", 12, 20),
        ]);
        assert_eq!(sessions.len(), 2);
        let together = activity_sessions(&[
            block(1, "Figma", "Logo lockups", 0, 12),
            block(2, "Figma", "Storyboard", 12, 14),
        ]);
        assert_eq!(together.len(), 1);
    }

    #[test]
    fn titles_rank_by_time_and_fall_back_to_apps() {
        let sessions = activity_sessions(&[
            block(
                1,
                "Visual Studio Code",
                "timeline.rs - core - Visual Studio Code",
                0,
                30,
            ),
            block(2, "Terminal", "cargo test", 30, 32),
            block(
                3,
                "Microsoft Edge",
                "Release notes - Personal - Microsoft\u{200b} Edge",
                32,
                34,
            ),
        ]);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].title, "timeline.rs - core");
        assert_eq!(sessions[0].apps[0], "Visual Studio Code");
        let untitled = activity_sessions(&[
            block(1, "Files", "Files", 0, 5),
            block(2, "Terminal", "", 5, 8),
            block(3, "Slack", "Home", 8, 9),
        ]);
        assert_eq!(untitled[0].title, "Files, Terminal +1");
        assert!(untitled[0].title_names_apps);
        assert!(!sessions[0].title_names_apps);
    }

    fn at_second(second: i64) -> DateTime<Utc> {
        at(0) + chrono::Duration::seconds(second)
    }

    fn untitled_block(id: i64, app: &str, start: i64, end: i64) -> ActivityBlock {
        ActivityBlock {
            id,
            app: app.into(),
            title: String::new(),
            start: at_second(start),
            end: at_second(end),
        }
    }

    #[test]
    fn untitled_session_names_its_two_busiest_apps_and_counts_the_rest() {
        let sessions = activity_sessions(&[
            untitled_block(1, "Claude", 0, 600),
            untitled_block(2, "Google Chrome", 600, 1_000),
            untitled_block(3, "Discord", 1_000, 1_100),
            untitled_block(4, "Spotify", 1_100, 1_150),
        ]);
        assert_eq!(sessions.len(), 1);
        // Spotify's 50 seconds don't count toward "+1".
        assert_eq!(sessions[0].title, "Claude, Google Chrome +1");
        assert_eq!(sessions[0].apps.len(), 4);
        assert!(sessions[0].title_names_apps);
        assert_eq!(app_summary(&["Claude"]), "Claude");

        // Only seconds of a second app: it stays evidence, not part of the title.
        let brief = activity_sessions(&[
            untitled_block(1, "Terminal", 0, 2_400),
            untitled_block(2, "Firefox", 2_400, 2_408),
        ]);
        assert_eq!(brief[0].title, "Terminal");
        assert_eq!(brief[0].apps, ["Terminal", "Firefox"]);
    }

    /// The rail marks a long stretch with nothing recorded. A meeting that
    /// runs past the next session must not open a gap that never happened.
    #[test]
    fn rail_marks_long_gaps_from_the_latest_end_so_far() {
        let titled = |id: i64, title: &str, start: i64, end: i64| ActivityBlock {
            title: title.into(),
            ..untitled_block(id, "Visual Studio Code", start, end)
        };
        let meeting: Meeting = serde_json::from_value(serde_json::json!({
            "id": "66666666-6666-4666-8666-666666666666",
            "title": "Planning",
            "appName": "Zoom",
            "startedAt": at_second(4_000),
            "endedAt": at_second(8_000),
            "relativePath": "meetings/planning",
        }))
        .unwrap();
        let sessions = work_sessions(
            &[
                titled(1, "a.rs", 0, 600),
                titled(2, "b.rs", 3_000, 3_300),
                titled(3, "c.rs", 6_000, 6_300),
                titled(4, "d.rs", 9_000, 9_600),
            ],
            &[meeting],
        );
        assert_eq!(sessions.len(), 5);

        let rows = rail_rows(&sessions, AWAY_MINIMUM_GAP_SECONDS);

        let gaps: Vec<(DateTime<Utc>, DateTime<Utc>)> = rows
            .iter()
            .filter_map(|row| match row {
                RailRow::Away { start, end } => Some((*start, *end)),
                RailRow::Session(_) => None,
            })
            .collect();
        // 600 → 3,000 is 40 minutes away. 3,300 → 4,000 is under 30 minutes,
        // and the meeting covers c.rs and ends 1,000 s before d.rs.
        assert_eq!(gaps, [(at_second(600), at_second(3_000))]);
        assert_eq!(rows.len(), sessions.len() + 1);
        assert_eq!(rows[0], RailRow::Session(0));
        assert!(matches!(rows[1], RailRow::Away { .. }));
    }

    #[test]
    fn system_apps_and_browser_chrome_are_dropped() {
        assert!(is_system_app(" LockApp "));
        assert!(is_system_app("gnome-shell"));
        assert_eq!(
            strip_browser_chrome("Pull request #42 - Audio playing - Google Chrome - Ana"),
            "Pull request #42"
        );
        assert_eq!(strip_browser_chrome("Review — Mozilla Firefox"), "Review");
        assert_eq!(
            strip_browser_chrome("Chrome - the browser"),
            "Chrome - the browser"
        );
        assert_eq!(cleaned_title("New Tab", "Firefox"), None);
        assert_eq!(cleaned_title("Slack", "Slack"), None);
        assert_eq!(
            cleaned_title(
                "Holiday shoot planning | Microsoft Teams",
                "Microsoft Teams"
            )
            .as_deref(),
            Some("Holiday shoot planning")
        );
        assert_eq!(
            cleaned_title("Brief.odt - LibreOffice Writer", "LibreOffice Writer").as_deref(),
            Some("Brief.odt")
        );
        let sessions = activity_sessions(&[block(1, "LockApp", "", 0, 30)]);
        assert!(sessions.is_empty());
    }

    #[test]
    fn meetings_interleave_with_work() {
        let meeting: Meeting = serde_json::from_value(serde_json::json!({
            "id": "55555555-5555-4555-8555-555555555555",
            "title": "Holiday shoot planning",
            "appName": "Microsoft Teams",
            "startedAt": "2026-10-15T09:10:00Z",
            "endedAt": "2026-10-15T09:35:00Z",
            "relativePath": "meetings/2026/10/15-holiday-shoot-planning",
        }))
        .unwrap();
        let sessions = work_sessions(
            &[
                block(1, "Figma", "Shot list", 0, 5),
                block(2, "Figma", "Shot list", 40, 50),
            ],
            &[meeting],
        );
        assert_eq!(sessions.len(), 3);
        assert!(sessions[1].meeting_id.is_some());
        assert_eq!(sessions[1].active_seconds, 25.0 * 60.0);
    }

    #[test]
    fn day_projection_clips_to_the_day() {
        let start = at(0);
        let end = at(60);
        let clipped = clip_blocks(
            &[
                block(1, "Slack", "", -30, 30),
                block(2, "LockApp", "", 0, 60),
            ],
            start,
            end,
        );
        assert_eq!(clipped.len(), 1);
        assert_eq!(clipped[0].start, start);
        let usage = app_usage(&[
            block(1, "Slack", "", 0, 30),
            block(2, "Slack", "", 10, 40),
            block(3, "Files", "", 50, 55),
        ]);
        assert_eq!(usage[0].app, "Slack");
        assert_eq!(usage[0].seconds, 40.0 * 60.0);
    }
}
