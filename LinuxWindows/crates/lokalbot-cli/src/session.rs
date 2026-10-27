//! Meeting lookups and output shapes (`SessionLookup.swift`,
//! `SessionFormatter.swift`). Read-only: nothing here writes to the library.

use chrono::{DateTime, Local, NaiveDate, SecondsFormat, TimeZone as _, Utc};
use lokalbot_core::{Library, LibraryPaths, Meeting, Transcript};
use serde::Serialize;
use uuid::Uuid;

use crate::json;

/// The library the CLI reads, opened read-only.
pub struct Session {
    pub paths: LibraryPaths,
    pub library: Library,
}

impl Session {
    pub fn open(paths: LibraryPaths) -> anyhow::Result<Self> {
        let library = Library::open_read_only(paths.clone())?;
        Ok(Self { paths, library })
    }

    /// Every visible meeting, newest first.
    pub fn meetings(&self) -> anyhow::Result<Vec<Meeting>> {
        self.library.list_meetings()
    }

    /// `latest`, a full UUID, or a unique prefix of an 8-character short ID.
    pub fn find(&self, id: &str, meetings: &[Meeting]) -> Option<Meeting> {
        let needle = id.to_lowercase();
        if needle == "latest" {
            return meetings.first().cloned();
        }
        if let Ok(uuid) = Uuid::parse_str(&needle)
            && needle.len() == 36
        {
            return meetings.iter().find(|m| m.id == uuid).cloned();
        }
        let matches: Vec<&Meeting> = meetings
            .iter()
            .filter(|m| short_id(m).starts_with(&needle))
            .collect();
        (matches.len() == 1).then(|| matches[0].clone())
    }

    /// Short IDs of every meeting a prefix matches.
    pub fn prefix_matches(&self, id: &str, meetings: &[Meeting]) -> Vec<String> {
        let needle = id.to_lowercase();
        meetings
            .iter()
            .filter(|m| short_id(m).starts_with(&needle))
            .map(short_id)
            .collect()
    }

    pub fn folder(&self, meeting: &Meeting) -> std::path::PathBuf {
        self.library.meeting_dir(meeting)
    }

    pub fn summary(&self, meeting: &Meeting) -> Option<String> {
        self.library.summary(meeting).ok().flatten()
    }

    pub fn transcript_markdown(&self, meeting: &Meeting) -> Option<String> {
        lokalbot_core::library::read_text(&self.folder(meeting).join("transcript.md"))
            .ok()
            .flatten()
    }

    pub fn transcript(&self, meeting: &Meeting) -> Option<Transcript> {
        self.library.transcript(meeting).ok().flatten()
    }
}

pub fn short_id(meeting: &Meeting) -> String {
    meeting.id.simple().to_string()[..8].to_string()
}

pub fn short_uuid(id: &Uuid) -> String {
    id.simple().to_string()[..8].to_string()
}

/// ISO 8601 in UTC without fractions ("2026-10-18T09:57:00Z").
pub fn iso8601(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(SecondsFormat::Secs, true)
}

/// Wall-clock length, or `None` while recording.
pub fn duration(meeting: &Meeting) -> Option<f64> {
    meeting
        .ended_at
        .map(|end| (end - meeting.started_at).num_milliseconds() as f64 / 1000.0)
}

/// "25 min", "1h 5m" or "in progress" (`Meeting.durationLabel`).
pub fn duration_label(meeting: &Meeting) -> String {
    let Some(seconds) = meeting.recorded_duration.or_else(|| duration(meeting)) else {
        return "in progress".into();
    };
    let minutes = (seconds.max(0.0) as i64) / 60;
    if minutes >= 60 {
        format!("{}h {}m", minutes / 60, minutes % 60)
    } else {
        format!("{minutes} min")
    }
}

/// "October 18, 2026 at 9:57 AM".
pub fn long_date(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local)
        .format("%B %-d, %Y at %-I:%M %p")
        .to_string()
}

fn short_date(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local)
        .format("%Y-%m-%d %H:%M")
        .to_string()
}

/// Start of a real local day written `YYYY-MM-DD` (`LibraryInputPolicy.localDay`).
pub fn local_day(value: &str) -> Option<NaiveDate> {
    let parts: Vec<&str> = value.split('-').collect();
    if parts.len() != 3 || parts[0].len() != 4 || parts[1].len() != 2 || parts[2].len() != 2 {
        return None;
    }
    NaiveDate::parse_from_str(value, "%Y-%m-%d").ok()
}

/// `[start, end)` of a local day in UTC.
pub fn day_bounds(day: NaiveDate) -> (DateTime<Utc>, DateTime<Utc>) {
    lokalbot_core::time::local_day_bounds(day)
}

pub fn start_of_local_day(day: NaiveDate) -> DateTime<Utc> {
    day_bounds(day).0
}

pub fn local_now_day() -> NaiveDate {
    Local::now().date_naive()
}

/// `YYYY-MM-DD` of an instant in the local zone.
pub fn day_key(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local).format("%Y-%m-%d").to_string()
}

#[derive(Serialize)]
struct ListEntry {
    id: String,
    uuid: String,
    title: String,
    date: String,
    duration_seconds: f64,
    app_source: String,
    has_system_track: bool,
    has_summary: bool,
    has_transcript: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    summary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    summary_truncated: Option<bool>,
    /// Only on LokalBot's sample meeting: made up, with synthetic voices.
    #[serde(skip_serializing_if = "Option::is_none")]
    sample: Option<bool>,
}

/// `list --include summary` (MCP: `list_meetings` with `include`): the listed
/// summaries share one character budget, so ten hour-long meetings fit a
/// small model's context. A short summary comes whole and leaves the rest of
/// its share to longer ones; a cut one ends in "…" with `summary_truncated`,
/// and `get` reads it whole.
pub const LIST_SUMMARY_BUDGET: usize = 20_000;
pub const LIST_SUMMARY_CAP: usize = 5_000;
pub const DEFAULT_SUMMARY_LIST_COUNT: usize = 10;
pub const MAXIMUM_SUMMARY_LIST_COUNT: usize = 50;

#[derive(Debug, PartialEq, Eq)]
pub enum ListIncludeError {
    Transcript,
    Unknown(Vec<String>),
}

/// Whether `list --include` (MCP `include`) asks for summaries. Entries
/// always carry metadata, so `metadata` changes nothing; transcripts are read
/// one meeting at a time with `get`.
pub fn list_includes_summary(include: &str) -> Result<bool, ListIncludeError> {
    let parts: std::collections::BTreeSet<String> = include
        .split(',')
        .map(|p| p.trim().to_lowercase())
        .filter(|p| !p.is_empty())
        .collect();
    if parts.contains("transcript") {
        return Err(ListIncludeError::Transcript);
    }
    let unknown: Vec<String> = parts
        .iter()
        .filter(|p| !["metadata", "summary"].contains(&p.as_str()))
        .cloned()
        .collect();
    if !unknown.is_empty() {
        return Err(ListIncludeError::Unknown(unknown));
    }
    Ok(parts.contains("summary"))
}

/// Each summary cut to its share of `LIST_SUMMARY_BUDGET`; `None` where a
/// meeting has none.
pub fn list_summaries(summaries: &[Option<String>]) -> Vec<Option<(String, bool)>> {
    let texts: Vec<Option<&str>> = summaries
        .iter()
        .map(|s| s.as_deref().map(str::trim).filter(|t| !t.is_empty()))
        .collect();
    let present: Vec<usize> = (0..texts.len()).filter(|&i| texts[i].is_some()).collect();
    let lengths: Vec<usize> = present
        .iter()
        .map(|&i| texts[i].map_or(0, |t| t.chars().count()))
        .collect();
    let shares = summary_shares(&lengths, LIST_SUMMARY_BUDGET, LIST_SUMMARY_CAP);
    let mut result = vec![None; texts.len()];
    for (&index, share) in present.iter().zip(shares) {
        if let Some(text) = texts[index] {
            result[index] = Some(shortened(text, share));
        }
    }
    result
}

/// Shortest first, each takes what it needs up to an equal split of what is
/// left (and at most `cap`), so short summaries leave room for long ones.
pub fn summary_shares(lengths: &[usize], budget: usize, cap: usize) -> Vec<usize> {
    let mut shares = vec![0; lengths.len()];
    let mut remaining = budget;
    let mut order: Vec<usize> = (0..lengths.len()).collect();
    order.sort_by_key(|&i| (lengths[i], i));
    for (position, &index) in order.iter().enumerate() {
        shares[index] = lengths[index]
            .min(cap)
            .min(remaining / (order.len() - position));
        remaining -= shares[index];
    }
    shares
}

/// The text when it has at most `limit` characters; otherwise its start, cut
/// at the last line break when that keeps at least half, and "…".
pub fn shortened(text: &str, limit: usize) -> (String, bool) {
    if text.chars().count() <= limit {
        return (text.to_string(), false);
    }
    let mut kept: String = text.chars().take(limit.saturating_sub(2)).collect();
    if let Some(newline) = kept.rfind('\n')
        && kept[..newline].chars().count() >= kept.chars().count() / 2
    {
        kept.truncate(newline);
    }
    (format!("{}\n…", kept.trim_end()), true)
}

pub fn list_json(session: &Session, meetings: &[Meeting], include_summary: bool) -> String {
    let markdown: Vec<Option<String>> = meetings.iter().map(|m| session.summary(m)).collect();
    let summaries = if include_summary {
        list_summaries(&markdown)
    } else {
        vec![None; meetings.len()]
    };
    let entries: Vec<ListEntry> = meetings
        .iter()
        .zip(markdown.iter().zip(summaries))
        .map(|(m, (markdown, summary))| ListEntry {
            id: short_id(m),
            uuid: m.id.hyphenated().to_string(),
            title: m.title.clone(),
            date: iso8601(m.started_at),
            duration_seconds: duration(m).unwrap_or(0.0),
            app_source: m.app_name.clone(),
            has_system_track: m.has_system_track,
            has_summary: markdown.is_some(),
            has_transcript: session.transcript_markdown(m).is_some(),
            summary_truncated: summary.as_ref().and_then(|(_, cut)| cut.then_some(true)),
            summary: summary.map(|(text, _)| text),
            sample: m.is_sample().then_some(true),
        })
        .collect();
    json::pretty(&entries, true)
}

pub fn list_table(session: &Session, meetings: &[Meeting], include_summary: bool) -> String {
    if meetings.is_empty() {
        return "(no meetings)".into();
    }
    let rows: Vec<Vec<String>> = meetings
        .iter()
        .map(|m| {
            vec![
                short_id(m),
                short_date(m.started_at),
                duration_label(m),
                m.app_name.clone(),
                m.title.clone(),
            ]
        })
        .collect();
    let table = render_table(&["ID", "Date", "Duration", "App", "Title"], &rows);
    if !include_summary {
        return table;
    }
    let markdown: Vec<Option<String>> = meetings.iter().map(|m| session.summary(m)).collect();
    let mut sections = vec![table];
    for (m, summary) in meetings.iter().zip(list_summaries(&markdown)) {
        if let Some((text, _)) = summary {
            sections.push(format!("── {} · {}\n{text}", short_id(m), m.title));
        }
    }
    sections.join("\n\n")
}

/// Which parts `get` prints, and an optional transcript window (MCP).
#[derive(Clone, Debug, PartialEq)]
pub struct GetOptions {
    pub include_summary: bool,
    pub include_transcript: bool,
    pub include_metadata: bool,
    pub transcript_characters: Option<usize>,
    pub transcript_from: Option<f64>,
}

impl GetOptions {
    pub fn all() -> Self {
        Self {
            include_summary: true,
            include_transcript: true,
            include_metadata: true,
            transcript_characters: None,
            transcript_from: None,
        }
    }
}

#[derive(Serialize)]
struct GetEntry {
    id: String,
    uuid: String,
    title: String,
    date: String,
    duration_seconds: f64,
    app_source: String,
    has_system_track: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    summary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    transcript: Option<String>,
    folder: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    sample: Option<bool>,
}

pub fn get_json(session: &Session, meeting: &Meeting, options: &GetOptions) -> String {
    let entry = GetEntry {
        id: short_id(meeting),
        uuid: meeting.id.hyphenated().to_string(),
        title: meeting.title.clone(),
        date: iso8601(meeting.started_at),
        duration_seconds: duration(meeting).unwrap_or(0.0),
        app_source: meeting.app_name.clone(),
        has_system_track: meeting.has_system_track,
        summary: options
            .include_summary
            .then(|| session.summary(meeting))
            .flatten(),
        transcript: options
            .include_transcript
            .then(|| session.transcript_markdown(meeting))
            .flatten(),
        folder: session.folder(meeting).to_string_lossy().into_owned(),
        sample: meeting.is_sample().then_some(true),
    };
    json::pretty(&entry, true)
}

pub fn get_markdown(session: &Session, meeting: &Meeting, options: &GetOptions) -> String {
    let mut lines: Vec<String> = Vec::new();
    if options.include_metadata {
        lines.push(format!("# {}", meeting.title));
        lines.push(format!("**Date:** {}  ", long_date(meeting.started_at)));
        lines.push(format!("**Duration:** {}  ", duration_label(meeting)));
        lines.push(format!("**App:** {}", meeting.app_name));
        if meeting.is_sample() {
            lines.push(String::new());
            lines.push("**Sample:** LokalBot's sample meeting. The people and the company are made up, and the voices are synthetic.".into());
        }
        lines.push(String::new());
    }
    if options.include_summary
        && let Some(summary) = session.summary(meeting)
    {
        lines.push("## Summary".into());
        lines.push(summary.trim().to_string());
        lines.push(String::new());
    }
    if options.include_transcript {
        if let (Some(limit), Some(transcript)) =
            (options.transcript_characters, session.transcript(meeting))
        {
            let (text, next) =
                transcript_window(&transcript, options.transcript_from.unwrap_or(0.0), limit);
            lines.push("## Transcript".into());
            lines.push(text);
            if let Some(next) = next {
                lines.push(String::new());
                lines.push(format!(
                    "[Transcript continues. Call get_meeting with transcript_from \"{next}\" to read on.]"
                ));
            }
            lines.push(String::new());
        } else if let Some(markdown) = session.transcript_markdown(meeting) {
            lines.push("## Transcript".into());
            lines.push(markdown.trim().to_string());
            lines.push(String::new());
        }
    }
    lines.join("\n")
}

/// Whole entries from `start` on, up to `max_characters`; the first entry is
/// always kept so paging makes progress.
pub fn transcript_window(
    transcript: &Transcript,
    start: f64,
    max_characters: usize,
) -> (String, Option<String>) {
    let roster = transcript.speaker_roster();
    let mut kept: Vec<String> = Vec::new();
    let mut used = 0;
    for segment in transcript.segments.iter().filter(|s| s.start >= start) {
        let Some(line) = Transcript::markdown_line(segment, &roster) else {
            continue;
        };
        let length = line.chars().count();
        if !kept.is_empty() && used + length + 2 > max_characters {
            return (
                kept.join("\n\n"),
                Some(lokalbot_core::time::stamp(segment.start)),
            );
        }
        kept.push(line);
        used += length + 2;
    }
    (kept.join("\n\n"), None)
}

/// Seconds for "HH:MM:SS", "MM:SS" or a plain number.
pub fn seconds_from_stamp(stamp: &str) -> Option<f64> {
    let parts: Vec<&str> = stamp.trim().split(':').collect();
    if !(1..=3).contains(&parts.len()) {
        return None;
    }
    let mut total = 0.0;
    for part in parts {
        let value: f64 = part.parse().ok()?;
        if value < 0.0 || !value.is_finite() {
            return None;
        }
        total = total * 60.0 + value;
    }
    Some(total)
}

/// One `search` hit (`SessionFormatter.SearchHit`).
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SearchHit {
    pub meeting_id: String,
    pub meeting_title: String,
    pub match_kind: String,
    pub snippet: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sample: Option<bool>,
}

pub fn search_json(hits: &[SearchHit]) -> String {
    json::pretty(&hits, true)
}

pub fn search_table(hits: &[SearchHit]) -> String {
    if hits.is_empty() {
        return "(no matches)".into();
    }
    let rows: Vec<Vec<String>> = hits
        .iter()
        .map(|hit| {
            let snippet: String = hit.snippet.replace('\n', " ").chars().take(80).collect();
            vec![
                hit.meeting_id.clone(),
                hit.match_kind.clone(),
                hit.timestamp.clone().unwrap_or_else(|| "—".into()),
                format!("{} — {snippet}", hit.meeting_title),
            ]
        })
        .collect();
    render_table(&["ID", "Kind", "Stamp", "Title — snippet"], &rows)
}

/// Columns padded to width and joined by two spaces; a `─` rule under the header.
pub fn render_table(header: &[&str], rows: &[Vec<String>]) -> String {
    let widths: Vec<usize> = (0..header.len())
        .map(|col| {
            std::iter::once(header[col].chars().count())
                .chain(
                    rows.iter()
                        .map(|r| r.get(col).map_or(0, |v| v.chars().count())),
                )
                .max()
                .unwrap_or(0)
        })
        .collect();
    let pad = |row: Vec<String>| -> String {
        row.iter()
            .zip(&widths)
            .map(|(value, width)| {
                format!(
                    "{value}{}",
                    " ".repeat(width.saturating_sub(value.chars().count()))
                )
            })
            .collect::<Vec<_>>()
            .join("  ")
    };
    let mut lines = vec![
        pad(header.iter().map(|h| h.to_string()).collect()),
        pad(widths.iter().map(|w| "─".repeat(*w)).collect()),
    ];
    lines.extend(rows.iter().cloned().map(pad));
    lines.join("\n")
}

/// A UTC instant from epoch seconds, for SQLite rows.
pub fn epoch(seconds: f64) -> DateTime<Utc> {
    lokalbot_core::time::from_epoch(seconds)
}

/// Local midnight of today as UTC.
pub fn today_start() -> DateTime<Utc> {
    let today = Local::now().date_naive();
    Local
        .from_local_datetime(&today.and_hms_opt(0, 0, 0).unwrap_or_default())
        .earliest()
        .map(|d| d.with_timezone(&Utc))
        .unwrap_or_else(Utc::now)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tables_pad_columns() {
        let table = render_table(
            &["ID", "Title"],
            &[vec!["a1b2c3d4".into(), "Design review".into()]],
        );
        assert_eq!(
            table,
            "ID        Title        \n────────  ─────────────\na1b2c3d4  Design review"
        );
    }

    #[test]
    fn list_summaries_share_one_budget() {
        // Short summaries take what they need and leave the rest to longer ones.
        assert_eq!(
            summary_shares(&[100, 9_000, 30_000], 10_000, 5_000),
            vec![100, 4_950, 4_950]
        );
        assert_eq!(summary_shares(&[300, 200], 20_000, 5_000), vec![300, 200]);
        assert_eq!(summary_shares(&[8_000; 4], 20_000, 5_000), vec![5_000; 4]);
        assert_eq!(summary_shares(&[], 20_000, 5_000), Vec::<usize>::new());
        let fifty = summary_shares(&[18_000; 50], LIST_SUMMARY_BUDGET, LIST_SUMMARY_CAP);
        assert!(fifty.iter().sum::<usize>() <= LIST_SUMMARY_BUDGET);
        assert!(fifty.iter().all(|&s| s == 400));

        assert_eq!(shortened("short", 10), ("short".to_string(), false));
        let text = "## TL;DR\nWe chose Redis.\n\n## Key points\n- one\n- two";
        let (cut, truncated) = shortened(text, 30);
        assert!(truncated);
        assert_eq!(cut, "## TL;DR\nWe chose Redis.\n…");
        // One long line is cut mid-line rather than to almost nothing.
        let (cut, _) = shortened(&format!("a\n{}", "b".repeat(100)), 20);
        assert_eq!(cut, format!("a\n{}\n…", "b".repeat(16)));
        assert!(cut.chars().count() <= 20);

        let listed = list_summaries(&[
            Some("  ## TL;DR\nShort.\n".into()),
            None,
            Some("   ".into()),
            Some("x".repeat(LIST_SUMMARY_CAP + 1)),
        ]);
        assert_eq!(listed[0], Some(("## TL;DR\nShort.".to_string(), false)));
        assert_eq!(listed[1], None);
        assert_eq!(listed[2], None);
        let (long, truncated) = listed[3].clone().unwrap();
        assert!(truncated && long.ends_with("\n…") && long.chars().count() <= LIST_SUMMARY_CAP);
    }

    #[test]
    fn list_include_takes_only_summary() {
        assert_eq!(list_includes_summary("metadata"), Ok(false));
        assert_eq!(list_includes_summary(""), Ok(false));
        assert_eq!(list_includes_summary(" Summary "), Ok(true));
        assert_eq!(list_includes_summary("metadata,summary"), Ok(true));
        assert_eq!(
            list_includes_summary("summary,transcript"),
            Err(ListIncludeError::Transcript)
        );
        assert_eq!(
            list_includes_summary("summary,audio,notes"),
            Err(ListIncludeError::Unknown(vec![
                "audio".into(),
                "notes".into()
            ]))
        );
    }

    #[test]
    fn stamps_and_days_parse() {
        assert_eq!(seconds_from_stamp("00:42:10"), Some(2530.0));
        assert_eq!(seconds_from_stamp("90"), Some(90.0));
        assert_eq!(seconds_from_stamp("1:2:3:4"), None);
        assert!(local_day("2026-02-28").is_some());
        assert!(local_day("2026-02-30").is_none());
        assert!(local_day("2026-2-03").is_none());
    }
}
