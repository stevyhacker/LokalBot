//! The Day Digest (`DayDigestEvidence.swift`, `DailyDigestEvidence.swift`).
//!
//! Evidence for one local day (activity blocks, screen text, finished
//! meetings) is cut into gap-aware segments. A first model pass per segment
//! extracts work candidates; a second pass groups them into tasks. The
//! journal's meetings, time allocation and full activity log are rendered
//! from the evidence itself, so a weak or failed model never loses activity.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::LazyLock;

use anyhow::Result;
use chrono::{DateTime, Local, NaiveDate, Utc};
use parking_lot::Mutex;
use regex::Regex;
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use lokalbot_core::model::{ActionStatus, DigestCoverage, DigestMeta, DigestQuality, Meeting};
use lokalbot_core::{Library, Settings};

use crate::error::AiError;
use crate::think::{ChatRequest, ThinkClient};
use crate::{json as model_json, prompts, sanitize};

#[derive(Clone, Debug, PartialEq)]
pub struct ScreenContext {
    pub snapshot_id: i64,
    pub captured_at: DateTime<Utc>,
    pub app: String,
    pub window_title: String,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MeetingEvidence {
    pub id: Uuid,
    pub title: String,
    pub app: String,
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
    pub source_summary: String,
    pub outcomes: String,
    pub artifact_modified_at: Option<DateTime<Utc>>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Activity {
    pub id: i64,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub app: String,
    pub title: String,
    pub contexts: Vec<ScreenContext>,
}

/// Everything the digest reads for one local day.
#[derive(Clone, Debug, PartialEq)]
pub struct DayEvidence {
    pub day: NaiveDate,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub activities: Vec<Activity>,
    pub standalone_contexts: Vec<ScreenContext>,
    pub meetings: Vec<MeetingEvidence>,
}

/// One slice of the day that gets its own extraction pass.
#[derive(Clone, Debug, PartialEq)]
pub struct Segment {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub active_seconds: f64,
    pub evidence: String,
    pub event_count: usize,
    pub source_ids: Vec<i64>,
}

fn seconds(a: DateTime<Utc>, b: DateTime<Utc>) -> f64 {
    (b - a).num_milliseconds() as f64 / 1000.0
}

fn time(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local).format("%H:%M").to_string()
}

/// `<1m`, `25m`, `2h 5m`.
fn duration(value: f64) -> String {
    let minutes = (value.round().max(0.0) as i64) / 60;
    if minutes == 0 {
        "<1m".into()
    } else if minutes >= 60 {
        format!("{}h {}m", minutes / 60, minutes % 60)
    } else {
        format!("{minutes}m")
    }
}

fn markdown_inline(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('`', "\\`")
        .replace('*', "\\*")
        .replace('_', "\\_")
        .replace('[', "\\[")
        .replace(']', "\\]")
}

fn markdown_table(value: &str) -> String {
    markdown_inline(value).replace('|', "\\|")
}

const RECURRING_CHROME: [&str; 5] = [
    "this button also has an action to zoom the window",
    "Bookmarks New Tab Back Forward Reload",
    "Chrome Apps Saved Tab Groups Separator",
    "Hide sidebar Back Forward Chat actions",
    "Toggle pinned summary Toggle bottom panel Toggle side panel",
];

/// Model-facing excerpt without recurring accessibility chrome.
fn summary_excerpt(value: &str, max_characters: usize) -> String {
    let mut result = sanitize::sanitize(value, None);
    for phrase in RECURRING_CHROME {
        if let Ok(pattern) = Regex::new(&format!("(?i){}", regex::escape(phrase))) {
            result = pattern.replace_all(&result, "").into_owned();
        }
    }
    sanitize::sanitize(&result, Some(max_characters))
}

fn evenly_spaced(count: usize, limit: usize) -> Vec<usize> {
    if count == 0 || limit == 0 {
        return Vec::new();
    }
    if limit == 1 {
        return vec![0];
    }
    if count <= limit {
        return (0..count).collect();
    }
    let mut result = Vec::new();
    for index in 0..limit {
        let position = (index as f64 * (count - 1) as f64 / (limit - 1) as f64).round() as usize;
        if !result.contains(&position) {
            result.push(position);
        }
    }
    result
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Source {
    Meeting,
    Activity,
    ScreenContext,
}

impl Source {
    fn order(self) -> u8 {
        match self {
            Source::Meeting => 0,
            Source::Activity => 2,
            Source::ScreenContext => 3,
        }
    }
}

#[derive(Clone, Debug)]
struct Event {
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    source: Source,
    text: String,
    source_ids: Vec<i64>,
    app: String,
    title: String,
}

fn covered_duration(events: &[&Event]) -> f64 {
    let mut intervals: Vec<(DateTime<Utc>, DateTime<Utc>)> = events
        .iter()
        .filter(|e| e.end > e.start)
        .map(|e| (e.start, e.end))
        .collect();
    intervals.sort_by_key(|i| i.0);
    let Some(mut current) = intervals.first().copied() else {
        return 0.0;
    };
    let mut total = 0.0;
    for interval in intervals.into_iter().skip(1) {
        if interval.0 <= current.1 {
            current.1 = current.1.max(interval.1);
        } else {
            total += seconds(current.0, current.1);
            current = interval;
        }
    }
    total + seconds(current.0, current.1)
}

/// The summary without its title and provenance lines.
fn summary_body(summary: &str) -> String {
    summary
        .lines()
        .filter(|l| !l.starts_with("# ") && !l.starts_with("**Duration:**"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn is_system_only(app: &str) -> bool {
    app.trim().eq_ignore_ascii_case("loginwindow")
}

impl DayEvidence {
    /// Gathers the day from the library: activity, retained screen text and
    /// finished meetings with their corrected outcomes.
    pub fn load(library: &Library, day: NaiveDate) -> Result<Self> {
        let (start, end) = lokalbot_core::time::local_day_bounds(day);
        let blocks = library.activity_blocks(start, end)?;
        let contexts: Vec<ScreenContext> = library
            .screen_moments(start, end)?
            .into_iter()
            .filter_map(|m| {
                let text = m.text.filter(|t| !t.trim().is_empty())?;
                Some(ScreenContext {
                    snapshot_id: m.id,
                    captured_at: m.ts,
                    app: m.app,
                    window_title: m.window_title,
                    text,
                })
            })
            .collect();
        let mut meetings = Vec::new();
        for meeting in library.list_own_meetings()? {
            if lokalbot_core::time::local_day(meeting.started_at) != day {
                continue;
            }
            let Some(ended_at) = meeting.ended_at else {
                continue;
            };
            meetings.push(MeetingEvidence {
                id: meeting.id,
                title: meeting.title.clone(),
                app: meeting.app_name.clone(),
                started_at: meeting.started_at,
                ended_at,
                source_summary: library.summary(&meeting)?.unwrap_or_default(),
                outcomes: render_meeting_outcomes(library, &meeting),
                artifact_modified_at: artifact_modified_at(library, &meeting),
            });
        }
        Ok(Self::build(day, start, end, blocks, contexts, meetings))
    }

    pub fn build(
        day: NaiveDate,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        blocks: Vec<lokalbot_core::model::ActivityBlock>,
        contexts: Vec<ScreenContext>,
        mut meetings: Vec<MeetingEvidence>,
    ) -> Self {
        let mut activities: Vec<Activity> = blocks
            .into_iter()
            .filter_map(|b| {
                let s = b.start.max(start);
                let e = b.end.min(end);
                (e > s).then(|| Activity {
                    id: b.id,
                    start: s,
                    end: e,
                    app: b.app,
                    title: b.title,
                    contexts: Vec::new(),
                })
            })
            .collect();
        activities.sort_by(|a, b| a.start.cmp(&b.start).then(a.id.cmp(&b.id)));
        let mut sorted = contexts;
        sorted.sort_by(|a, b| {
            a.captured_at
                .cmp(&b.captured_at)
                .then(a.snapshot_id.cmp(&b.snapshot_id))
        });
        // Repeated captures of the same window and text count once.
        let mut previous: Option<String> = None;
        let mut standalone = Vec::new();
        for mut context in sorted {
            if context.captured_at < start || context.captured_at >= end {
                continue;
            }
            context.text = sanitize::sanitize(&context.text, None);
            let fingerprint = format!(
                "{}\u{1f}{}\u{1f}{}",
                context.app.to_lowercase(),
                context.window_title.to_lowercase(),
                context.text
            );
            if previous.as_ref() == Some(&fingerprint) {
                continue;
            }
            previous = Some(fingerprint);
            match activities
                .iter_mut()
                .find(|a| context.captured_at >= a.start && context.captured_at < a.end)
            {
                Some(activity) => activity.contexts.push(context),
                None => standalone.push(context),
            }
        }
        meetings.sort_by(|a, b| {
            a.started_at
                .cmp(&b.started_at)
                .then(a.id.to_string().cmp(&b.id.to_string()))
        });
        Self {
            day,
            start,
            end,
            activities,
            standalone_contexts: standalone,
            meetings,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.activities.is_empty()
            && self.standalone_contexts.is_empty()
            && self.meetings.is_empty()
    }

    pub fn latest_evidence_at(&self) -> Option<DateTime<Utc>> {
        [
            self.activities.iter().map(|a| a.end).max(),
            self.standalone_contexts.iter().map(|c| c.captured_at).max(),
            self.meetings.iter().map(|m| m.ended_at).max(),
            self.meetings
                .iter()
                .filter_map(|m| m.artifact_modified_at)
                .max(),
        ]
        .into_iter()
        .flatten()
        .max()
    }

    fn representative(contexts: &[ScreenContext], limit: usize) -> Vec<&ScreenContext> {
        if limit == 0 {
            return Vec::new();
        }
        if contexts.len() <= limit {
            return contexts.iter().collect();
        }
        evenly_spaced(contexts.len(), limit)
            .into_iter()
            .map(|i| &contexts[i])
            .collect()
    }

    /// Long blocks get evidence in proportion to their duration.
    fn summary_contexts(activity: &Activity) -> Vec<&ScreenContext> {
        let duration = seconds(activity.start, activity.end).max(0.0);
        let proportional = (duration / (30.0 * 60.0)).ceil() as usize + 1;
        Self::representative(&activity.contexts, proportional.clamp(2, 12))
    }

    fn events(&self) -> Vec<Event> {
        let mut events = Vec::new();
        for activity in self.activities.iter().filter(|a| !is_system_only(&a.app)) {
            let contexts = Self::summary_contexts(activity);
            let budget = if contexts.is_empty() {
                0
            } else {
                (8_400 / contexts.len()).clamp(360, 1_200)
            };
            let mut lines = vec!["WORK SOURCE: ACTIVITY".to_string()];
            if !activity.title.is_empty() {
                lines.push(format!(
                    "Possible task context (weak; corroborate before summarizing): {}",
                    activity.title
                ));
            }
            for context in &contexts {
                let source = if context.snapshot_id > 0 {
                    format!("[screen:{}]", context.snapshot_id)
                } else {
                    "[screen]".into()
                };
                let text = summary_excerpt(&context.text, budget);
                if !text.is_empty() {
                    lines.push(format!("Screen context {source}:\n{text}"));
                }
            }
            lines.push(format!(
                "LOW-PRIORITY TRACE METADATA — do not summarize directly:\n{}–{}; app={}; window={}; duration={}",
                time(activity.start),
                time(activity.end),
                activity.app,
                if activity.title.is_empty() { "Unknown" } else { &activity.title },
                duration(seconds(activity.start, activity.end))
            ));
            events.push(Event {
                start: activity.start,
                end: activity.end,
                source: Source::Activity,
                text: lines.join("\n"),
                source_ids: contexts
                    .iter()
                    .map(|c| c.snapshot_id)
                    .filter(|id| *id > 0)
                    .collect(),
                app: activity.app.clone(),
                title: activity.title.clone(),
            });
        }
        for context in self
            .standalone_contexts
            .iter()
            .filter(|c| !is_system_only(&c.app))
        {
            let source = if context.snapshot_id > 0 {
                format!("[screen:{}]", context.snapshot_id)
            } else {
                "[screen]".into()
            };
            events.push(Event {
                start: context.captured_at,
                end: context.captured_at,
                source: Source::ScreenContext,
                text: format!(
                    "WORK SOURCE: SCREEN CONTEXT {source}\nCaptured work text: {}\nLOW-PRIORITY TRACE METADATA — do not summarize directly:\n{}; app={}; window={}",
                    summary_excerpt(&context.text, 1_200),
                    time(context.captured_at),
                    context.app,
                    if context.window_title.is_empty() { "Unknown" } else { &context.window_title }
                ),
                source_ids: if context.snapshot_id > 0 { vec![context.snapshot_id] } else { Vec::new() },
                app: context.app.clone(),
                title: context.window_title.clone(),
            });
        }
        for meeting in &self.meetings {
            let mut lines = vec![
                "WORK SOURCE: MEETING".to_string(),
                format!("Task context: {}", meeting.title),
            ];
            // Outcomes lead: a busy segment cuts each source from the front.
            let outcomes = sanitize::sanitize(&meeting.outcomes, Some(3_000));
            if !outcomes.is_empty() {
                lines.push(format!("Outcomes:\n{outcomes}"));
            }
            let summary = sanitize::sanitize(&summary_body(&meeting.source_summary), Some(6_000));
            if !summary.is_empty() {
                lines.push(format!("Source summary:\n{summary}"));
            }
            lines.push(format!(
                "LOW-PRIORITY TRACE METADATA — do not summarize directly:\n{}–{}; app={}",
                time(meeting.started_at),
                time(meeting.ended_at),
                meeting.app
            ));
            events.push(Event {
                start: meeting.started_at,
                end: meeting.ended_at,
                source: Source::Meeting,
                text: lines.join("\n"),
                source_ids: Vec::new(),
                app: meeting.app.clone(),
                title: meeting.title.clone(),
            });
        }
        events.sort_by(|a, b| {
            a.start
                .cmp(&b.start)
                .then(a.source.order().cmp(&b.source.order()))
        });
        events
    }

    /// Gap-aware segments: an idle gap over 10 minutes always starts a new
    /// one; a session gets one segment per hour of active time, at most 16.
    pub fn summary_segments(&self) -> Vec<Segment> {
        const MAX_CHARACTERS: usize = 12_000;
        const GAP_SECONDS: f64 = 600.0;
        const MAX_SEGMENTS: usize = 16;
        const TARGET_SECONDS: f64 = 3_600.0;
        let events = self.events();
        if events.is_empty() {
            return Vec::new();
        }
        let mut sessions: Vec<Vec<&Event>> = Vec::new();
        for event in &events {
            match sessions.last_mut() {
                Some(session)
                    if seconds(
                        session.iter().map(|e| e.end).max().unwrap_or(event.start),
                        event.start,
                    ) <= GAP_SECONDS =>
                {
                    session.push(event)
                }
                _ => sessions.push(vec![event]),
            }
        }
        while sessions.len() > MAX_SEGMENTS {
            let mut smallest = 0;
            let mut smallest_duration =
                covered_duration(&[sessions[0].clone(), sessions[1].clone()].concat());
            for index in 1..sessions.len() - 1 {
                let combined = covered_duration(
                    &[sessions[index].clone(), sessions[index + 1].clone()].concat(),
                );
                if combined < smallest_duration {
                    smallest = index;
                    smallest_duration = combined;
                }
            }
            let next = sessions.remove(smallest + 1);
            sessions[smallest].extend(next);
        }
        let weight = |session: &[&Event]| {
            let covered = covered_duration(session);
            if covered > 0.0 {
                covered
            } else {
                session.len() as f64
            }
        };
        let needs: Vec<usize> = sessions
            .iter()
            .map(|s| {
                s.len()
                    .min(((covered_duration(s) / TARGET_SECONDS.max(60.0)).ceil() as usize).max(1))
            })
            .collect();
        let budget = sessions.len().max(MAX_SEGMENTS.min(needs.iter().sum()));
        let mut allocations = vec![1usize; sessions.len()];
        while allocations.iter().sum::<usize>() < budget {
            let candidate = (0..sessions.len())
                .filter(|i| allocations[*i] < needs[*i])
                .max_by(|a, b| {
                    (weight(&sessions[*a]) / allocations[*a] as f64)
                        .partial_cmp(&(weight(&sessions[*b]) / allocations[*b] as f64))
                        .unwrap_or(std::cmp::Ordering::Equal)
                });
            let Some(index) = candidate else { break };
            allocations[index] += 1;
        }
        let mut groups: Vec<Vec<&Event>> = Vec::new();
        for (index, session) in sessions.iter().enumerate() {
            let count = allocations[index];
            for part in 0..count {
                let lower = part * session.len() / count;
                let upper = (part + 1) * session.len() / count;
                if lower < upper {
                    groups.push(session[lower..upper].to_vec());
                }
            }
        }
        groups
            .iter()
            .map(|group| self.make_segment(group, MAX_CHARACTERS))
            .collect()
    }

    fn make_segment(&self, events: &[&Event], max_characters: usize) -> Segment {
        let details = detail_indices(events, 12);
        let content_budget = ((max_characters as f64 * 0.82) as usize).max(120);
        let per_detail = (content_budget / details.len().max(1)).max(120);
        let texts: Vec<String> = details
            .iter()
            .map(|i| sanitize::sanitize(&events[*i].text, Some(per_detail)))
            .filter(|t| !t.is_empty())
            .collect();
        let mut evidence = format!(
            "WORK CONTENT — primary evidence:\n{}",
            texts.join("\n\n---\n\n")
        );
        let remaining = max_characters.saturating_sub(evidence.chars().count() + 72);
        if remaining > 80 {
            let per_line = (remaining / events.len().max(1)).clamp(48, 160);
            let inventory: Vec<String> = events
                .iter()
                .map(|e| {
                    let title = if e.title.is_empty() {
                        "Unknown"
                    } else {
                        &e.title
                    };
                    sanitize::single_line(
                        &format!("[{}–{}] {} — {title}", time(e.start), time(e.end), e.app),
                        per_line,
                    )
                })
                .collect();
            evidence.push_str(&format!(
                "\n\nLOW-PRIORITY TRACE METADATA — context only, never a work item:\n{}",
                inventory.join("\n")
            ));
        }
        let evidence = sanitize::sanitize(&evidence, Some(max_characters));
        let mut source_ids = Vec::new();
        for event in events {
            for id in &event.source_ids {
                if !source_ids.contains(id) {
                    source_ids.push(*id);
                }
            }
        }
        Segment {
            start: events.first().map(|e| e.start).unwrap_or(self.start),
            end: events.iter().map(|e| e.end).max().unwrap_or(self.start),
            active_seconds: covered_duration(events),
            evidence,
            event_count: events.len(),
            source_ids,
        }
    }

    /// The lossless journal around the model's summary.
    pub fn render_document(&self, summary: &str) -> String {
        let clean = summary.trim();
        let body = if clean.is_empty() {
            "_No grounded summary was generated. The chronological log below is complete._"
        } else {
            clean
        };
        [
            format!("## Day summary\n\n{body}"),
            format!("## Meetings\n\n{}", self.meetings_section()),
            format!("## Time allocation\n\n{}", self.time_allocation_section()),
            format!("## Full activity log\n\n{}", self.chronological_log()),
        ]
        .join("\n\n")
            + "\n"
    }

    fn chronological_log(&self) -> String {
        enum Entry<'a> {
            Activity(&'a Activity),
            Context(&'a ScreenContext),
            Meeting(&'a MeetingEvidence),
        }
        let mut entries: Vec<(DateTime<Utc>, u8, Entry)> = Vec::new();
        entries.extend(
            self.activities
                .iter()
                .map(|a| (a.start, 1, Entry::Activity(a))),
        );
        entries.extend(
            self.standalone_contexts
                .iter()
                .map(|c| (c.captured_at, 2, Entry::Context(c))),
        );
        entries.extend(
            self.meetings
                .iter()
                .map(|m| (m.started_at, 0, Entry::Meeting(m))),
        );
        entries.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
        if entries.is_empty() {
            return "_No activity was recorded._".into();
        }
        entries
            .iter()
            .map(|(_, _, entry)| match entry {
                Entry::Activity(activity) => {
                    let mut line = format!(
                        "- **{}–{}** — **{}**",
                        time(activity.start),
                        time(activity.end),
                        markdown_inline(&activity.app)
                    );
                    if !activity.title.is_empty() {
                        line.push_str(&format!(" — {}", markdown_inline(&activity.title)));
                    }
                    for context in Self::representative(&activity.contexts, 3) {
                        let excerpt = sanitize::single_line(&context.text, 360);
                        if excerpt.is_empty() {
                            continue;
                        }
                        let source = if context.snapshot_id > 0 {
                            format!("[screen:{}]", context.snapshot_id)
                        } else {
                            "screen context".into()
                        };
                        line.push_str(&format!(
                            "\n  - {source}, {}: {}",
                            time(context.captured_at),
                            markdown_inline(&excerpt)
                        ));
                    }
                    line
                }
                Entry::Context(context) => {
                    let title = if context.window_title.is_empty() {
                        markdown_inline(&context.app)
                    } else {
                        format!(
                            "{} — {}",
                            markdown_inline(&context.app),
                            markdown_inline(&context.window_title)
                        )
                    };
                    let source = if context.snapshot_id > 0 {
                        format!("[screen:{}]", context.snapshot_id)
                    } else {
                        "screen context".into()
                    };
                    format!(
                        "- **{}** — **Screen context** — {title}\n  - {source}: {}",
                        time(context.captured_at),
                        markdown_inline(&sanitize::single_line(&context.text, 360))
                    )
                }
                Entry::Meeting(meeting) => format!(
                    "- **{}–{}** — **Meeting** — {} ({})",
                    time(meeting.started_at),
                    time(meeting.ended_at),
                    markdown_inline(&meeting.title),
                    markdown_inline(&meeting.app)
                ),
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn meetings_section(&self) -> String {
        if self.meetings.is_empty() {
            return "_None._".into();
        }
        self.meetings
            .iter()
            .map(|meeting| {
                let mut lines = vec![
                    format!(
                        "### {} — {}",
                        time(meeting.started_at),
                        markdown_inline(&meeting.title)
                    ),
                    format!("- App: {}", markdown_inline(&meeting.app)),
                    format!(
                        "- Duration: {}",
                        duration(seconds(meeting.started_at, meeting.ended_at))
                    ),
                ];
                let summary = sanitize::single_line(&meeting.source_summary, 600);
                if !summary.is_empty() {
                    lines.push(format!("- Source summary: {}", markdown_inline(&summary)));
                }
                let outcomes = sanitize::single_line(&meeting.outcomes, 400);
                if !outcomes.is_empty() {
                    lines.push(format!("- Outcomes: {}", markdown_inline(&outcomes)));
                }
                lines.join("\n")
            })
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    fn time_allocation_section(&self) -> String {
        let mut totals: BTreeMap<&str, f64> = BTreeMap::new();
        for activity in &self.activities {
            *totals.entry(activity.app.as_str()).or_default() +=
                seconds(activity.start, activity.end);
        }
        if totals.is_empty() {
            return "_No tracked app time._".into();
        }
        let mut rows: Vec<(&str, f64)> = totals.into_iter().collect();
        rows.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(a.0.cmp(b.0))
        });
        let mut lines = vec![
            "| App | Tracked time |".to_string(),
            "| --- | ---: |".to_string(),
        ];
        lines.extend(
            rows.iter()
                .map(|(app, s)| format!("| {} | {} |", markdown_table(app), duration(*s))),
        );
        lines.join("\n")
    }

    fn meeting_fields(&self) -> Vec<String> {
        self.meetings
            .iter()
            .flat_map(|m| {
                [
                    "meeting".to_string(),
                    m.id.hyphenated().to_string().to_uppercase(),
                    m.title.clone(),
                    m.app.clone(),
                    epoch(m.started_at),
                    epoch(m.ended_at),
                    m.source_summary.clone(),
                    m.outcomes.clone(),
                ]
            })
            .collect()
    }

    /// `contentSignature`: changes whenever anything the digest reads changes.
    pub fn content_signature(&self) -> String {
        let mut fields = vec![
            "digest-evidence-v1".to_string(),
            epoch(self.start),
            epoch(self.start),
            epoch(self.end),
        ];
        let push_context = |fields: &mut Vec<String>, c: &ScreenContext| {
            fields.extend([
                "context".into(),
                c.snapshot_id.to_string(),
                epoch(c.captured_at),
                c.app.clone(),
                c.window_title.clone(),
                c.text.clone(),
            ]);
        };
        for activity in &self.activities {
            fields.extend([
                "activity".into(),
                activity.id.to_string(),
                epoch(activity.start),
                epoch(activity.end),
                activity.app.clone(),
                activity.title.clone(),
            ]);
            for context in &activity.contexts {
                push_context(&mut fields, context);
            }
        }
        for context in &self.standalone_contexts {
            push_context(&mut fields, context);
        }
        fields.extend(self.meeting_fields());
        fingerprint(&fields)
    }

    pub fn meeting_signature(&self) -> String {
        fingerprint(&self.meeting_fields())
    }
}

/// `String(Double)` of epoch seconds ("1760781234.0").
fn epoch(at: DateTime<Utc>) -> String {
    format!("{:?}", lokalbot_core::time::to_epoch(at))
}

/// `ContentFingerprint.fields`: SHA-256 over `<byte length>:<bytes>` per field.
fn fingerprint(fields: &[String]) -> String {
    let mut material = Vec::new();
    for field in fields {
        material.extend(format!("{}:", field.len()).as_bytes());
        material.extend(field.as_bytes());
    }
    lokalbot_core::library::sha256_hex(&material)
}

/// Meetings and agent sessions never get sampled away from a busy segment.
fn detail_indices(events: &[&Event], limit: usize) -> Vec<usize> {
    if events.is_empty() || limit == 0 {
        return Vec::new();
    }
    let sample = |indices: &[usize], count: usize| -> Vec<usize> {
        evenly_spaced(indices.len(), count.min(indices.len()))
            .into_iter()
            .map(|i| indices[i])
            .collect()
    };
    let meetings: Vec<usize> = (0..events.len())
        .filter(|i| events[*i].source == Source::Meeting)
        .collect();
    if meetings.len() >= limit {
        return sample(&meetings, limit);
    }
    let taken: HashSet<usize> = meetings.iter().copied().collect();
    let remaining: Vec<usize> = (0..events.len()).filter(|i| !taken.contains(i)).collect();
    let mut indices = meetings.clone();
    indices.extend(sample(&remaining, limit - meetings.len()));
    indices.sort_unstable();
    indices
}

/// "Action items:" with corrections, "Decisions:", "Open questions:".
fn render_meeting_outcomes(library: &Library, meeting: &Meeting) -> String {
    let mut lines = Vec::new();
    let actions = library.meeting_actions(meeting).unwrap_or_default();
    if !actions.is_empty() {
        lines.push("Action items:".to_string());
        for action in &actions {
            let mut details = Vec::new();
            if let Some(owner) = action.owner.as_deref().filter(|o| !o.is_empty()) {
                details.push(format!("owner: {owner}"));
            }
            if let Some(due) = action.due.as_deref().filter(|d| !d.is_empty()) {
                details.push(format!("due: {due}"));
            }
            if action.status == ActionStatus::Deferred {
                details.push("status: deferred".into());
            }
            let marker = if action.status == ActionStatus::Done {
                "x"
            } else {
                " "
            };
            let suffix = if details.is_empty() {
                String::new()
            } else {
                format!(" ({})", details.join(", "))
            };
            lines.push(format!("- [{marker}] {}{suffix}", action.text));
        }
    }
    if let Ok(Some(outcomes)) = library.outcomes(meeting) {
        if !outcomes.decision_records.is_empty() {
            lines.push("Decisions:".into());
            lines.extend(
                outcomes
                    .decision_records
                    .iter()
                    .map(|d| format!("- {}", d.text)),
            );
        }
        if !outcomes.open_questions.is_empty() {
            lines.push("Open questions:".into());
            lines.extend(outcomes.open_questions.iter().map(|q| format!("- {q}")));
        }
    }
    lines.join("\n")
}

fn artifact_modified_at(library: &Library, meeting: &Meeting) -> Option<DateTime<Utc>> {
    let dir = library.meeting_dir(meeting);
    let has_outcomes = dir.join("outcomes.json").is_file();
    ["summary.md", "outcomes.json", "outcome-state.json"]
        .iter()
        .filter(|name| **name != "outcome-state.json" || has_outcomes)
        .filter_map(|name| std::fs::metadata(dir.join(name)).ok()?.modified().ok())
        .map(DateTime::<Utc>::from)
        .max()
}

// ================================================================ generator

const TITLE_CHARACTERS: usize = 160;
const SUMMARY_WORDS: usize = 120;
const WORK_DONE_WORDS: usize = 80;
const BULLET_CHARACTERS: usize = 1_200;
const FOCUS_TOKENS: u32 = 2_048;
const FOCUS_RETRY_TOKENS: u32 = 4_096;
const AGGREGATION_TOKENS: u32 = 1_600;
const AGGREGATION_RETRY_TOKENS: u32 = 3_200;

fn aggregation_tokens(candidates: usize) -> u32 {
    AGGREGATION_RETRY_TOKENS.min(AGGREGATION_TOKENS + (candidates.saturating_sub(8) as u32) * 150)
}

#[derive(Clone, Debug, PartialEq)]
pub struct FocusBlock {
    pub task: String,
    pub work_done: String,
    pub status: String,
    pub outcome: String,
    pub next_step: String,
    pub source_ids: Vec<i64>,
}

#[derive(Deserialize)]
struct FocusDraft {
    substantive: bool,
    task: String,
    work_done: String,
    status: String,
    outcome: String,
    next_step: String,
    source_ids: Vec<i64>,
    #[serde(default)]
    other_tasks: Option<Vec<FocusDraft>>,
}

#[derive(Deserialize)]
struct DraftTask {
    title: String,
    status: String,
    summary: String,
    next_step: String,
    block_indices: Vec<i64>,
}

#[derive(Deserialize)]
struct DigestDraft {
    tasks: Vec<DraftTask>,
    decisions: Vec<String>,
    blockers: Vec<String>,
}

struct ParsedFocus {
    block: Option<FocusBlock>,
    substantive: bool,
    others: Vec<(FocusBlock, bool)>,
}

#[derive(Clone, Debug)]
struct NormalizedTask {
    title: String,
    status: String,
    summary: String,
    next_step: String,
}

fn clean_inline(value: &str, max: usize) -> String {
    sanitize::sanitize(value, Some(max))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches(|c| "#*` ".contains(c))
        .to_string()
}

static SCREEN_CITATION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[screen:\d+\]").expect("valid regex"));

fn clean_bullet(value: &str, max_words: usize) -> String {
    let mut clean = clean_inline(value, BULLET_CHARACTERS);
    while clean.starts_with('-') || clean.starts_with('•') {
        clean = clean.chars().skip(1).collect::<String>().trim().to_string();
    }
    for prefix in ["The user ", "the user ", "User ", "user "] {
        if let Some(rest) = clean.strip_prefix(prefix) {
            let mut chars = rest.chars();
            clean = match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            };
            break;
        }
    }
    let words: Vec<&str> = clean.split_whitespace().collect();
    if words.len() <= max_words {
        return clean;
    }
    format!("{}…", words[..max_words].join(" "))
}

fn clean_summary(value: &str, max_words: usize) -> String {
    clean_bullet(&SCREEN_CITATION.replace_all(value, ""), max_words)
}

fn normalized_status(value: &str) -> String {
    let normalized = value.trim().to_lowercase();
    if ["completed", "in_progress", "blocked", "unknown"].contains(&normalized.as_str()) {
        normalized
    } else {
        "unknown".into()
    }
}

fn task_key(value: &str) -> String {
    clean_inline(value, TITLE_CHARACTERS).to_lowercase()
}

fn status_lead(status: &str) -> &'static str {
    match status {
        "completed" => "Completed. ",
        "in_progress" => "In progress. ",
        "blocked" => "Blocked. ",
        _ => "",
    }
}

fn focus_block(draft: &FocusDraft, segment: &Segment) -> Option<FocusBlock> {
    let task = clean_inline(&draft.task, TITLE_CHARACTERS);
    let work_done = clean_summary(&draft.work_done, WORK_DONE_WORDS);
    if task.is_empty() || work_done.is_empty() {
        return None;
    }
    let mut source_ids = Vec::new();
    for id in &draft.source_ids {
        if segment.source_ids.contains(id) && !source_ids.contains(id) {
            source_ids.push(*id);
            if source_ids.len() == 2 {
                break;
            }
        }
    }
    Some(FocusBlock {
        task,
        work_done,
        status: normalized_status(&draft.status),
        outcome: clean_summary(&draft.outcome, 32),
        next_step: clean_summary(&draft.next_step, 28),
        source_ids,
    })
}

fn parse_focus(output: &str, segment: &Segment) -> Option<ParsedFocus> {
    let object = model_json::parse_object(output)?;
    let draft: FocusDraft = serde_json::from_value(Value::Object(object)).ok()?;
    let Some(main) = focus_block(&draft, segment) else {
        return (!draft.substantive).then_some(ParsedFocus {
            block: None,
            substantive: false,
            others: Vec::new(),
        });
    };
    let mut seen = vec![task_key(&main.task)];
    let mut others = Vec::new();
    for other in draft.other_tasks.iter().flatten() {
        if others.len() == 2 {
            break;
        }
        let Some(block) = focus_block(other, segment) else {
            continue;
        };
        if seen.contains(&task_key(&block.task)) {
            continue;
        }
        seen.push(task_key(&block.task));
        others.push((block, other.substantive));
    }
    Some(ParsedFocus {
        block: Some(main),
        substantive: draft.substantive,
        others,
    })
}

fn parse_digest(output: &str) -> Option<DigestDraft> {
    serde_json::from_value(Value::Object(model_json::parse_object(output)?)).ok()
}

fn focus_task_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "substantive": {"type": "boolean"},
            "task": {"type": "string"},
            "work_done": {"type": "string"},
            "status": {"type": "string", "enum": ["completed", "in_progress", "blocked", "unknown"]},
            "outcome": {"type": "string"},
            "next_step": {"type": "string"},
            "source_ids": {"type": "array", "items": {"type": "integer"}, "maxItems": 2},
        },
        "required": ["substantive", "task", "work_done", "status", "outcome", "next_step", "source_ids"],
        "additionalProperties": false,
    })
}

fn focus_schema() -> Value {
    let mut schema = focus_task_schema();
    schema["properties"]["other_tasks"] =
        json!({"type": "array", "items": focus_task_schema(), "maxItems": 2});
    if let Some(required) = schema["required"].as_array_mut() {
        required.push(json!("other_tasks"));
    }
    schema
}

fn digest_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "tasks": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "title": {"type": "string"},
                        "status": {"type": "string", "enum": ["completed", "in_progress", "blocked", "unknown"]},
                        "summary": {"type": "string"},
                        "next_step": {"type": "string"},
                        "block_indices": {"type": "array", "items": {"type": "integer"}, "minItems": 1},
                    },
                    "required": ["title", "status", "summary", "next_step", "block_indices"],
                    "additionalProperties": false,
                },
                "maxItems": 8,
            },
            "decisions": {"type": "array", "items": {"type": "string"}, "maxItems": 4},
            "blockers": {"type": "array", "items": {"type": "string"}, "maxItems": 4},
        },
        "required": ["tasks", "decisions", "blockers"],
        "additionalProperties": false,
    })
}

fn candidate_material(block: &FocusBlock, index: usize, priority: Option<&str>) -> String {
    let priority = priority
        .map(|p| format!("\n  Priority: {p}"))
        .unwrap_or_default();
    format!(
        "- [candidate_index {index}]{priority}\n  Task: {}\n  Work done: {}\n  Status: {}\n  Outcome: {}\n  Next step: {}",
        block.task,
        block.work_done,
        block.status,
        if block.outcome.is_empty() {
            "None supported"
        } else {
            &block.outcome
        },
        if block.next_step.is_empty() {
            "None supported"
        } else {
            &block.next_step
        },
    )
}

fn candidate_summary(block: &FocusBlock) -> String {
    let mut summary = block.work_done.clone();
    if !block.outcome.is_empty()
        && !summary
            .to_lowercase()
            .contains(&block.outcome.to_lowercase())
    {
        summary.push_str(&format!(" Outcome: {}", block.outcome));
    }
    clean_summary(&summary, SUMMARY_WORDS)
}

fn merge_fallback_candidate(block: &FocusBlock, tasks: &mut Vec<NormalizedTask>) {
    let key = task_key(&block.task);
    if let Some(task) = tasks.iter_mut().find(|t| task_key(&t.title) == key) {
        if !task
            .summary
            .to_lowercase()
            .contains(&block.work_done.to_lowercase())
        {
            task.summary = clean_summary(
                &format!("{} {}", task.summary, candidate_summary(block)),
                SUMMARY_WORDS,
            );
        }
        if block.status != "unknown" {
            task.status = block.status.clone();
        }
        if !block.next_step.is_empty() {
            task.next_step = block.next_step.clone();
        }
        return;
    }
    tasks.push(NormalizedTask {
        title: block.task.clone(),
        status: block.status.clone(),
        summary: candidate_summary(block),
        next_step: block.next_step.clone(),
    });
}

fn normalized_list(values: &[String], max_words: usize) -> Vec<String> {
    let mut result = Vec::new();
    for raw in values {
        let clean = clean_bullet(raw, max_words);
        if !clean.is_empty() && !result.contains(&clean) {
            result.push(clean);
        }
        if result.len() == 4 {
            break;
        }
    }
    result
}

fn normalized_digest(
    draft: Option<&DigestDraft>,
    blocks: &[FocusBlock],
) -> (Vec<NormalizedTask>, Vec<String>, Vec<String>) {
    let mut tasks: Vec<NormalizedTask> = Vec::new();
    let mut covered: HashSet<usize> = HashSet::new();
    for raw in draft.map(|d| d.tasks.as_slice()).unwrap_or_default() {
        let mut indices: Vec<usize> = Vec::new();
        for index in &raw.block_indices {
            if let Ok(i) = usize::try_from(*index)
                && i < blocks.len()
                && !indices.contains(&i)
            {
                indices.push(i);
            }
        }
        let title = clean_inline(&raw.title, TITLE_CHARACTERS);
        let summary = clean_summary(&raw.summary, SUMMARY_WORDS);
        if indices.is_empty() || title.is_empty() || summary.is_empty() {
            continue;
        }
        if tasks.iter().any(|t| task_key(&t.title) == task_key(&title)) {
            continue;
        }
        tasks.push(NormalizedTask {
            title,
            status: normalized_status(&raw.status),
            summary,
            next_step: clean_summary(&raw.next_step, 32),
        });
        covered.extend(indices);
    }
    // Candidates the model left out are still kept.
    for (index, block) in blocks.iter().enumerate() {
        if !covered.contains(&index) {
            merge_fallback_candidate(block, &mut tasks);
        }
    }
    let decisions = normalized_list(
        draft.map(|d| d.decisions.as_slice()).unwrap_or_default(),
        32,
    );
    let blockers = normalized_list(draft.map(|d| d.blockers.as_slice()).unwrap_or_default(), 32);
    (tasks, decisions, blockers)
}

fn unique_follow_ups(
    tasks: &[NormalizedTask],
    decisions: &[String],
    blockers: &[String],
) -> Vec<String> {
    let task_content: Vec<String> = tasks
        .iter()
        .map(|t| format!("{} {}", t.title, t.summary))
        .collect();
    let mut accepted: Vec<(String, String)> = Vec::new();
    let mut append = |content: &str, rendered: String| {
        if task_content
            .iter()
            .any(|t| lokalbot_core::digest::is_similar(content, t))
            || accepted
                .iter()
                .any(|(c, _)| lokalbot_core::digest::is_similar(content, c))
        {
            return;
        }
        accepted.push((content.to_string(), rendered));
    };
    for decision in decisions {
        append(decision, format!("Decision: {decision}"));
    }
    for blocker in blockers {
        append(blocker, format!("Blocker: {blocker}"));
    }
    for task in tasks.iter().filter(|t| !t.next_step.is_empty()) {
        append(
            &task.next_step,
            format!("Next — {}: {}", task.title, task.next_step),
        );
    }
    accepted.into_iter().map(|(_, r)| r).collect()
}

const RECORDED_ACTIVITY: &str = "### Tasks\n- **Recorded activity** — Activity was captured, but the available context did not identify a more specific item.";

fn render(blocks: &[FocusBlock], draft: Option<&DigestDraft>) -> String {
    let (tasks, decisions, blockers) = normalized_digest(draft, blocks);
    if tasks.is_empty() {
        return RECORDED_ACTIVITY.into();
    }
    let mut sections = vec![format!(
        "### Tasks\n{}",
        tasks
            .iter()
            .map(|t| format!(
                "- **{}** — {}{}",
                t.title,
                status_lead(&t.status),
                t.summary
            ))
            .collect::<Vec<_>>()
            .join("\n")
    )];
    let follow_ups = unique_follow_ups(&tasks, &decisions, &blockers);
    if !follow_ups.is_empty() {
        sections.push(format!(
            "### Decisions and next steps\n{}",
            follow_ups
                .iter()
                .map(|f| format!("- {f}"))
                .collect::<Vec<_>>()
                .join("\n")
        ));
    }
    sections.join("\n\n")
}

fn fallback_activity_title(raw: &str, app: &str) -> Option<String> {
    let mut title = clean_inline(raw, 120);
    let clean_app = clean_inline(app, 72);
    if !clean_app.is_empty() {
        let suffix = format!(" - {}", clean_app.to_lowercase());
        if let Some(at) = title.to_lowercase().rfind(&suffix) {
            title = title[..at].trim().to_string();
        }
    }
    let normalized = title.to_lowercase();
    let generic = [
        "",
        "home",
        "login",
        "login window",
        "loginwindow",
        "new tab",
        "timeline",
        "today",
        "unknown",
    ];
    if generic.contains(&normalized.as_str())
        || clean_app.to_lowercase() == "loginwindow"
        || normalized == clean_app.to_lowercase()
    {
        return None;
    }
    Some(clean_inline(&title, TITLE_CHARACTERS))
}

fn markdown_section<'a>(name: &str, markdown: &'a str) -> Option<&'a str> {
    let lower = markdown.to_lowercase();
    let heading = format!("## {}", name.to_lowercase());
    let at = lower.find(&heading)? + heading.len();
    let rest = &markdown[at..];
    Some(match rest.find("\n## ") {
        Some(end) => &rest[..end],
        None => rest,
    })
}

/// Conservative output when the model fails or rejects everything.
fn best_available_blocks(evidence: &DayEvidence, limit: usize) -> Vec<FocusBlock> {
    let mut blocks = Vec::new();
    for meeting in &evidence.meetings {
        let title = clean_inline(&meeting.title, TITLE_CHARACTERS);
        let mut work = markdown_section("TL;DR", &meeting.source_summary)
            .map(|t| clean_summary(t, WORK_DONE_WORDS))
            .unwrap_or_default();
        if work.is_empty() {
            work = clean_summary(&meeting.outcomes, WORK_DONE_WORDS);
        }
        blocks.push(FocusBlock {
            task: if title.is_empty() {
                "Recorded meeting".into()
            } else {
                title
            },
            work_done: if work.is_empty() {
                "Participated in the recorded meeting.".into()
            } else {
                work
            },
            status: "unknown".into(),
            outcome: clean_summary(&meeting.outcomes, 32),
            next_step: String::new(),
            source_ids: Vec::new(),
        });
        if blocks.len() == limit {
            return blocks;
        }
    }
    let mut grouped: HashMap<String, (String, f64, DateTime<Utc>)> = HashMap::new();
    for activity in &evidence.activities {
        let Some(title) = fallback_activity_title(&activity.title, &activity.app) else {
            continue;
        };
        let entry = grouped
            .entry(task_key(&title))
            .or_insert((title, 0.0, activity.start));
        entry.1 += seconds(activity.start, activity.end).max(0.0);
        entry.2 = entry.2.min(activity.start);
    }
    for context in &evidence.standalone_contexts {
        let Some(title) = fallback_activity_title(&context.window_title, &context.app) else {
            continue;
        };
        grouped
            .entry(task_key(&title))
            .or_insert((title, 0.0, context.captured_at));
    }
    let mut activities: Vec<(String, f64, DateTime<Utc>)> = grouped.into_values().collect();
    activities.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.2.cmp(&b.2))
    });
    let mut keys: HashSet<String> = blocks.iter().map(|b| task_key(&b.task)).collect();
    for (title, _, _) in activities {
        if !keys.insert(task_key(&title)) {
            continue;
        }
        blocks.push(FocusBlock {
            task: title,
            work_done:
                "Activity related to this item was recorded; no more specific outcome was visible."
                    .into(),
            status: "unknown".into(),
            outcome: String::new(),
            next_step: String::new(),
            source_ids: Vec::new(),
        });
        if blocks.len() == limit {
            break;
        }
    }
    blocks
}

/// The summary without the model.
pub fn fallback_summary(evidence: &DayEvidence) -> String {
    if evidence.is_empty() {
        return "### At a glance\n_No activity was recorded._".into();
    }
    let blocks = best_available_blocks(evidence, 6);
    if blocks.is_empty() {
        RECORDED_ACTIVITY.into()
    } else {
        render(&blocks, None)
    }
}

/// Answers already given today, keyed by the exact prompt; in memory only.
/// Days in use order, then each day's prompt key → answer.
type SegmentCache = (Vec<String>, HashMap<String, HashMap<String, String>>);

static SEGMENT_CACHE: LazyLock<Mutex<SegmentCache>> =
    LazyLock::new(|| Mutex::new((Vec::new(), HashMap::new())));

fn cache_key(think: &ThinkClient, system: &str, prompt: &str) -> String {
    lokalbot_core::library::sha256_hex(
        format!(
            "{}\u{1f}{system}\u{1f}{prompt}",
            think.checkpoint_identity()
        )
        .as_bytes(),
    )
}

fn cached(day: &str, key: &str) -> Option<String> {
    SEGMENT_CACHE.lock().1.get(day)?.get(key).cloned()
}

fn store(day: &str, key: &str, output: &str) {
    let mut guard = SEGMENT_CACHE.lock();
    let (order, entries) = &mut *guard;
    let day_entries = entries.entry(day.to_string()).or_default();
    if !day_entries.contains_key(key) && day_entries.len() >= 64 {
        day_entries.clear();
    }
    day_entries.insert(key.to_string(), output.to_string());
    order.retain(|d| d != day);
    order.push(day.to_string());
    while order.len() > 8 {
        let oldest = order.remove(0);
        entries.remove(&oldest);
    }
}

/// Forgets cached answers for days whose evidence was deleted or corrected.
pub fn purge_cache(days: &[NaiveDate]) {
    let mut guard = SEGMENT_CACHE.lock();
    for day in days {
        let key = day.format("%Y-%m-%d").to_string();
        guard.1.remove(&key);
        guard.0.retain(|d| d != &key);
    }
}

/// The generated summary (the `## Day summary` body) with its quality.
pub struct Overview {
    pub summary: String,
    pub quality: DigestQuality,
    pub coverage: Option<DigestCoverage>,
}

#[allow(clippy::too_many_arguments)]
fn generate_json(
    think: &ThinkClient,
    system: &str,
    prompt: &str,
    context: &str,
    max_tokens: u32,
    reasoning: u32,
    temperature: f32,
    schema: &Value,
) -> Result<String> {
    let request = ChatRequest::new(system, format!("{context}\n\n{prompt}"))
        .max_tokens(max_tokens)
        .reasoning_budget(reasoning)
        .temperature(temperature)
        .json_schema(schema.clone());
    think.complete(&request)
}

fn is_truncation(err: &anyhow::Error) -> bool {
    matches!(
        err.downcast_ref::<AiError>(),
        Some(AiError::Truncated { .. })
    )
}

/// The two model passes over the day's segments
/// (`DayDigestOverviewGenerator.generateResult`).
pub fn generate_overview(
    think: &ThinkClient,
    evidence: &DayEvidence,
    custom_prompt: &str,
    progress: &mut dyn FnMut(&str),
) -> Result<Overview> {
    let date_context = format!("Date: {}", evidence.day.format("%A, %B %-d, %Y"));
    let day_key = evidence.day.format("%Y-%m-%d").to_string();
    let segments = evidence.summary_segments();
    let tracked: f64 = segments.iter().map(|s| s.active_seconds).sum();
    let mut covered = 0.0;
    if segments.is_empty() {
        return Ok(Overview {
            summary: fallback_summary(evidence),
            quality: DigestQuality::Complete,
            coverage: None,
        });
    }
    log::info!(
        "day digest plan segments={} events={}",
        segments.len(),
        segments.iter().map(|s| s.event_count).sum::<usize>()
    );
    let mut substantive: Vec<FocusBlock> = Vec::new();
    let mut secondary: Vec<FocusBlock> = Vec::new();
    let mut degraded = false;
    let focus_schema = focus_schema();
    for (index, segment) in segments.iter().enumerate() {
        progress(&format!(
            "Reading the day · part {} of {}",
            index + 1,
            segments.len()
        ));
        let ids = segment
            .source_ids
            .iter()
            .map(i64::to_string)
            .collect::<Vec<_>>()
            .join(", ");
        let focus_prompt = format!(
            "Extract the substantive-work candidates from this evidence segment.\nDecide eligibility from the work content, not from time spent or app usage.\nAllowed screen source IDs: [{ids}]\n\n{}",
            segment.evidence
        );
        let key = cache_key(think, prompts::DAY_DIGEST_FOCUS_SYSTEM, &focus_prompt);
        let mut accept = |parsed: ParsedFocus, covered: &mut f64| {
            let Some(block) = parsed.block else { return };
            *covered += segment.active_seconds;
            for (block, is_substantive) in
                std::iter::once((block, parsed.substantive)).chain(parsed.others)
            {
                if is_substantive {
                    substantive.push(block)
                } else {
                    secondary.push(block)
                }
            }
        };
        if let Some(parsed) =
            cached(&day_key, &key).and_then(|output| parse_focus(&output, segment))
        {
            accept(parsed, &mut covered);
            continue;
        }
        let retry_prompt = format!("{}\n\n{focus_prompt}", prompts::DIGEST_FOCUS_RETRY);
        let mut attempts = 1;
        let first = generate_json(
            think,
            prompts::DAY_DIGEST_FOCUS_SYSTEM,
            &focus_prompt,
            &date_context,
            FOCUS_TOKENS,
            256,
            0.2,
            &focus_schema,
        );
        let mut output = match first {
            Ok(output) => output,
            Err(err) if is_truncation(&err) => {
                attempts = 2;
                match generate_json(
                    think,
                    prompts::DAY_DIGEST_FOCUS_SYSTEM,
                    &retry_prompt,
                    &date_context,
                    FOCUS_RETRY_TOKENS,
                    0,
                    0.0,
                    &focus_schema,
                ) {
                    Ok(output) => output,
                    Err(err) if crate::error::is_cancelled(&err) => return Err(err),
                    Err(_) => {
                        degraded = true;
                        continue;
                    }
                }
            }
            Err(err) if crate::error::is_cancelled(&err) => return Err(err),
            Err(err) => {
                degraded = true;
                log::warn!("day digest segment {} stopped: {err:#}", index + 1);
                break;
            }
        };
        let mut parsed = parse_focus(&output, segment);
        if parsed.is_none() && attempts == 1 {
            match generate_json(
                think,
                prompts::DAY_DIGEST_FOCUS_SYSTEM,
                &retry_prompt,
                &date_context,
                FOCUS_RETRY_TOKENS,
                0,
                0.0,
                &focus_schema,
            ) {
                Ok(retry) => {
                    output = retry;
                    parsed = parse_focus(&output, segment);
                }
                Err(err) if crate::error::is_cancelled(&err) => return Err(err),
                Err(err) => {
                    degraded = true;
                    if matches!(
                        err.downcast_ref::<AiError>(),
                        Some(AiError::ServerUnreachable(_))
                    ) {
                        break;
                    }
                }
            }
        }
        match parsed {
            Some(parsed) => {
                store(&day_key, &key, &output);
                accept(parsed, &mut covered);
            }
            None => degraded = true,
        }
    }
    let coverage = Some(DigestCoverage {
        covered_seconds: covered,
        tracked_seconds: tracked,
    });
    let uses_best_available = substantive.is_empty();
    let marks_priority = !substantive.is_empty() && !secondary.is_empty();
    let primary_count = substantive.len();
    let selected: Vec<FocusBlock> = substantive.into_iter().chain(secondary).collect();
    if selected.is_empty() {
        return Ok(Overview {
            summary: fallback_summary(evidence),
            quality: if degraded {
                DigestQuality::Fallback
            } else {
                DigestQuality::Complete
            },
            coverage,
        });
    }
    progress("Writing the day summary…");
    let (instruction, heading) = if uses_best_available {
        (
            "Retain the best grounded activity even without a concrete outcome.",
            "BEST AVAILABLE WORK OR ACTIVITY CANDIDATES:",
        )
    } else if marks_priority {
        (
            "Rank primary candidates by concrete outcome, useful progress, decision, or blocker, then list secondary candidates after them. Merge a secondary candidate into a primary task when both concern the same work; otherwise keep it as its own lower-ranked task. Do not rank by duration or chronology.",
            "WORK CANDIDATES (primary first, then secondary):",
        )
    } else {
        (
            "Rank by concrete outcome, useful progress, decision, or blocker. Do not rank by duration or chronology.",
            "SUBSTANTIVE WORK CANDIDATES:",
        )
    };
    let material = selected
        .iter()
        .enumerate()
        .map(|(i, b)| {
            candidate_material(
                b,
                i,
                marks_priority.then_some(if i < primary_count {
                    "primary"
                } else {
                    "secondary"
                }),
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let system = prompts::with_digest_guidance(
        if uses_best_available {
            prompts::DAY_DIGEST_FALLBACK_SYSTEM
        } else {
            prompts::DAY_DIGEST_SYSTEM
        },
        custom_prompt,
    );
    let prompt = format!(
        "Build the daily recap from every accepted candidate below.\nMerge candidates for the same task and include every contributing\ncandidate index in block_indices. {instruction}\n\n{heading}\n{material}"
    );
    let key = cache_key(think, &system, &prompt);
    let schema = digest_schema();
    let output = match cached(&day_key, &key).filter(|o| parse_digest(o).is_some()) {
        Some(output) => Ok(output),
        None => match generate_json(
            think,
            &system,
            &prompt,
            &date_context,
            aggregation_tokens(selected.len()),
            512,
            0.2,
            &schema,
        ) {
            Err(err) if is_truncation(&err) => {
                let retry = format!("{}\n\n{prompt}", prompts::DIGEST_AGGREGATION_RETRY);
                generate_json(
                    think,
                    &system,
                    &retry,
                    &date_context,
                    AGGREGATION_RETRY_TOKENS,
                    0,
                    0.0,
                    &schema,
                )
            }
            other => other,
        },
    };
    let draft = match output {
        Ok(output) => {
            let draft = parse_digest(&output);
            if draft.is_some() {
                store(&day_key, &key, &output);
            }
            draft
        }
        Err(err) if crate::error::is_cancelled(&err) => return Err(err),
        Err(err) => {
            log::warn!("day digest aggregation fell back: {err:#}");
            None
        }
    };
    if draft.is_none() {
        degraded = true;
    }
    Ok(Overview {
        summary: render(&selected, draft.as_ref()),
        quality: if degraded {
            DigestQuality::Partial
        } else {
            DigestQuality::Complete
        },
        coverage,
    })
}

/// The journal Markdown for `day` and its sidecar. Never fails on a model
/// error: the evidence-only journal is written with `quality: fallback`.
pub fn generate_day_digest(
    think: &ThinkClient,
    library: &Library,
    day: NaiveDate,
    settings: &Settings,
    progress: &mut dyn FnMut(&str),
) -> Result<(String, DigestMeta)> {
    progress("Gathering the day…");
    let evidence = DayEvidence::load(library, day)?;
    let _hold = if evidence.is_empty() {
        None
    } else {
        think.hold()?
    };
    let overview = match generate_overview(
        think,
        &evidence,
        &settings.day_digest_custom_prompt,
        progress,
    ) {
        Ok(overview) => overview,
        Err(err) if crate::error::is_cancelled(&err) => return Err(err),
        Err(err) => {
            log::warn!("day digest model pass failed: {err:#}");
            Overview {
                summary: fallback_summary(&evidence),
                quality: DigestQuality::Fallback,
                coverage: None,
            }
        }
    };
    let markdown = evidence.render_document(&overview.summary);
    let meta = DigestMeta {
        quality: overview.quality,
        generated_at: lokalbot_core::time::now_seconds(),
        evidence_latest_at: evidence.latest_evidence_at(),
        evidence_signature: Some(evidence.content_signature()),
        meeting_evidence_signature: Some(evidence.meeting_signature()),
        coverage: overview.coverage,
        engine: Some(think.display_name()),
        ..DigestMeta::default()
    };
    progress("Digest ready");
    Ok((markdown, meta))
}

/// The current evidence signatures for `day`, to decide whether a stored
/// digest is still current without generating anything.
pub fn evidence_signatures(library: &Library, day: NaiveDate) -> Result<(String, String)> {
    let evidence = DayEvidence::load(library, day)?;
    Ok((evidence.content_signature(), evidence.meeting_signature()))
}

#[cfg(test)]
mod tests;
