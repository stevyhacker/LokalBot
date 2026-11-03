//! Library health (`LibraryHealth.swift`, `LibraryHealthLoader.swift`,
//! `LibraryHealthReportStore.swift`): judges one day of a library the way a
//! person would notice a problem. Reads counts and timestamps only, never window
//! text or meeting content. Reports stay in `diagnostics/health`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use anyhow::Result;
use chrono::{DateTime, Duration, Local, NaiveDate, Timelike as _, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::library::{Library, write_atomic};
use crate::model::{ActivityBlock, DigestCoverage, DigestQuality, Meeting};
use crate::settings::Settings;
use crate::time::{iso_seconds, local_day, local_day_bounds};

pub const PRIVATE_APP: &str = "Private";
/// Capture skips LokalBot's own windows and the lock screen by design.
const UNCAPTURED_APPS: &[&str] = &[
    "LokalBot",
    "LokalBot Dev",
    "LokalBot UI Test Host",
    "loginwindow",
];
const MINIMUM_TRACKED_SECONDS_FOR_CAPTURE: f64 = 30.0 * 60.0;
const PRIVATE_SHARE_WARNING: f64 = 0.15;
const PRIVATE_SHARE_BASELINE_FLOOR: f64 = 0.10;
const DIGEST_COVERAGE_WARNING: f64 = 0.60;
const SCHEDULER_GRACE_SECONDS: i64 = 2 * 60 * 60;
const CLOCK_TOLERANCE_SECONDS: f64 = 60.0;
/// Reads transcripts for finished recordings of the last week.
const RECORDINGS_WINDOW_DAYS: i64 = 7;
use crate::dream::CATCH_UP_DAYS as DREAM_CATCH_UP_DAYS;
/// `DayDigestGenerationMetadataStore.maximumDegradedAttempts`.
const MAXIMUM_DEGRADED_ATTEMPTS: u32 = 3;
/// Shorter recordings hold no speech worth a model run.
const MINIMUM_RECORDING_SECONDS: f64 = 5.0;
/// A merged source shorter than this may legitimately have no segments.
const MINIMUM_GAP_SECONDS: f64 = 30.0;
const GAP_REPAIR_MARKER: &str = "transcript-gap-repair.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HealthStatus {
    Pass,
    Warn,
    Fail,
}

impl HealthStatus {
    fn label(self) -> &'static str {
        match self {
            Self::Pass => "PASS",
            Self::Warn => "WARN",
            Self::Fail => "FAIL",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HealthCheck {
    CaptureRate,
    PrivateShare,
    ActivityClock,
    FinishedRecordings,
    Schedulers,
    DigestCoverage,
}

impl HealthCheck {
    pub fn title(self) -> &'static str {
        match self {
            Self::CaptureRate => "Screen captures per app",
            Self::PrivateShare => "Time recorded as Private",
            Self::ActivityClock => "Tracked time versus the clock",
            Self::FinishedRecordings => "Finished recordings",
            Self::Schedulers => "Scheduled digests and dreams",
            Self::DigestCoverage => "Digest coverage",
        }
    }
}

/// Fields are in sorted-key order, so the JSON reads as the Mac's
/// `.sortedKeys` encoder writes it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HealthFinding {
    pub check: HealthCheck,
    #[serde(default)]
    pub measurements: BTreeMap<String, f64>,
    pub status: HealthStatus,
    pub summary: String,
}

impl HealthFinding {
    fn new(check: HealthCheck, status: HealthStatus, summary: impl Into<String>) -> Self {
        Self {
            check,
            measurements: BTreeMap::new(),
            status,
            summary: summary.into(),
        }
    }

    fn measuring<const N: usize>(mut self, measurements: [(&str, f64); N]) -> Self {
        self.measurements = measurements
            .into_iter()
            .map(|(name, value)| (name.to_string(), value))
            .collect();
        self
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthReport {
    pub day_key: String,
    pub findings: Vec<HealthFinding>,
    #[serde(with = "iso_seconds")]
    pub generated_at: DateTime<Utc>,
}

impl HealthReport {
    pub fn status(&self) -> HealthStatus {
        self.findings
            .iter()
            .map(|finding| finding.status)
            .max()
            .unwrap_or(HealthStatus::Pass)
    }

    pub fn finding(&self, check: HealthCheck) -> Option<&HealthFinding> {
        self.findings.iter().find(|finding| finding.check == check)
    }

    pub fn markdown(&self) -> String {
        let mut lines = vec![
            format!("# LokalBot health — {}", self.day_key),
            String::new(),
            format!("Overall: **{}**", self.status().label()),
            String::new(),
        ];
        for finding in &self.findings {
            lines.push(format!(
                "- **{}** {}: {}",
                finding.status.label(),
                finding.check.title(),
                finding.summary
            ));
        }
        lines.join("\n") + "\n"
    }
}

/// Why a finished recording still needs transcribing (`MissingTranscription.Reason`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MissingTranscript {
    NeverTranscribed,
    MergedGap,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RecordingHealth {
    pub meeting_id: Uuid,
    pub title: String,
    pub missing_transcript: Option<MissingTranscript>,
    pub has_queued_job: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PastDay {
    pub day: NaiveDate,
    pub latest_evidence_at: Option<DateTime<Utc>>,
    pub digest_modified_at: Option<DateTime<Utc>>,
}

impl PastDay {
    /// A past day with evidence is final once its journal was written at or
    /// after the start of the following day (`DayDigestScheduler.needsFinalization`).
    pub fn needs_finalization(&self) -> bool {
        if self.latest_evidence_at.is_none() {
            return false;
        }
        let (_, next_day) = local_day_bounds(self.day);
        self.digest_modified_at.is_none_or(|at| at < next_day)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SchedulerHealth {
    pub automatic_inference_allowed: bool,
    pub digest_enabled: bool,
    /// Yesterday relative to `now`, as the digest scheduler sees it.
    pub previous_day: Option<PastDay>,
    pub dreaming_enabled: bool,
    pub dreaming_hour: u32,
    /// Undreamed eligible days in the catch-up window through yesterday.
    pub missing_dream_days: usize,
}

/// Everything the evaluator judges.
#[derive(Clone, Debug, PartialEq)]
pub struct HealthInput {
    pub day_start: DateTime<Utc>,
    pub day_end: DateTime<Utc>,
    pub now: DateTime<Utc>,
    pub blocks: Vec<ActivityBlock>,
    pub screen_capture_enabled: bool,
    pub capture_counts_by_app: HashMap<String, usize>,
    /// Private share of each earlier day in the last week that had activity.
    pub private_share_history: Vec<f64>,
    pub recordings: Vec<RecordingHealth>,
    /// Off means the app never repairs a missing transcript on its own.
    pub automatic_transcription: bool,
    pub schedulers: SchedulerHealth,
    pub digest_coverage: Option<DigestCoverage>,
}

/// Blocks overlapping the day, cut to it and sorted by start.
pub fn clamped_blocks(
    blocks: &[ActivityBlock],
    start: DateTime<Utc>,
    end: DateTime<Utc>,
) -> Vec<ActivityBlock> {
    let mut clamped: Vec<ActivityBlock> = blocks
        .iter()
        .filter_map(|block| {
            let (from, to) = (block.start.max(start), block.end.min(end));
            (to > from).then(|| ActivityBlock {
                start: from,
                end: to,
                ..block.clone()
            })
        })
        .collect();
    clamped.sort_by_key(|block| block.start);
    clamped
}

fn total(blocks: &[ActivityBlock]) -> f64 {
    // Not `sum`: an empty float sum is -0.0, which would read as "-0.0 h".
    blocks
        .iter()
        .fold(0.0, |total, block| total + block.duration_seconds())
}

fn median(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let middle = sorted.len() / 2;
    if sorted.len().is_multiple_of(2) {
        (sorted[middle - 1] + sorted[middle]) / 2.0
    } else {
        sorted[middle]
    }
}

fn percent(value: f64) -> i64 {
    (value * 100.0).round() as i64
}

pub fn evaluate(input: &HealthInput, day_key: &str) -> HealthReport {
    let blocks = clamped_blocks(&input.blocks, input.day_start, input.day_end);
    HealthReport {
        day_key: day_key.to_string(),
        findings: vec![
            capture_rate(input, &blocks),
            private_share(input, &blocks),
            activity_clock(input, &blocks),
            finished_recordings(input),
            schedulers(input),
            digest_coverage(input),
        ],
        generated_at: input.now,
    }
}

fn capture_rate(input: &HealthInput, blocks: &[ActivityBlock]) -> HealthFinding {
    use HealthCheck::CaptureRate as Check;
    if !input.screen_capture_enabled {
        return HealthFinding::new(Check, HealthStatus::Pass, "Screen capture is turned off.");
    }
    let mut seconds: HashMap<&str, f64> = HashMap::new();
    for block in blocks {
        *seconds.entry(block.app.as_str()).or_default() += block.duration_seconds();
    }
    let mut silent: Vec<&str> = seconds
        .into_iter()
        .filter(|(app, tracked)| {
            *app != PRIVATE_APP
                && !UNCAPTURED_APPS.contains(app)
                && !crate::timeline::is_system_app(app)
                && *tracked >= MINIMUM_TRACKED_SECONDS_FOR_CAPTURE
        })
        .filter(|(app, _)| input.capture_counts_by_app.get(*app).copied().unwrap_or(0) == 0)
        .map(|(app, _)| app)
        .collect();
    silent.sort_unstable();
    if silent.is_empty() {
        return HealthFinding::new(
            Check,
            HealthStatus::Pass,
            "Every app with 30 or more minutes tracked has screen captures.",
        );
    }
    HealthFinding::new(
        Check,
        HealthStatus::Fail,
        format!(
            "No screen captures for {} despite 30 or more minutes tracked.",
            silent.join(", ")
        ),
    )
    .measuring([("appsWithoutCaptures", silent.len() as f64)])
}

fn private_share(input: &HealthInput, blocks: &[ActivityBlock]) -> HealthFinding {
    use HealthCheck::PrivateShare as Check;
    let tracked = total(blocks);
    if tracked <= 0.0 {
        return HealthFinding::new(Check, HealthStatus::Pass, "No tracked activity.");
    }
    let hidden: f64 = blocks
        .iter()
        .filter(|block| block.app == PRIVATE_APP)
        .map(ActivityBlock::duration_seconds)
        .sum();
    let share = hidden / tracked;
    let baseline = median(&input.private_share_history);
    let doubled = baseline > 0.0 && share >= 2.0 * baseline && share > PRIVATE_SHARE_BASELINE_FLOOR;
    let status = if share > PRIVATE_SHARE_WARNING || doubled {
        HealthStatus::Warn
    } else {
        HealthStatus::Pass
    };
    let mut summary = format!(
        "{}% of tracked time was recorded as Private",
        percent(share)
    );
    if doubled {
        summary.push_str(&format!(" (7-day median {}%)", percent(baseline)));
    }
    summary.push('.');
    HealthFinding::new(Check, status, summary)
        .measuring([("privateShare", share), ("baseline", baseline)])
}

fn activity_clock(input: &HealthInput, blocks: &[ActivityBlock]) -> HealthFinding {
    use HealthCheck::ActivityClock as Check;
    let mut overlaps = 0;
    let mut latest_end: Option<DateTime<Utc>> = None;
    for block in blocks {
        if latest_end.is_some_and(|end| block.start < end - Duration::seconds(1)) {
            overlaps += 1;
        }
        latest_end = Some(latest_end.map_or(block.end, |end| end.max(block.end)));
    }
    let tracked = total(blocks);
    let elapsed = ((input.now.min(input.day_end) - input.day_start).num_milliseconds() as f64
        / 1000.0)
        .max(0.0);
    let measurements = [
        ("trackedHours", tracked / 3_600.0),
        ("elapsedHours", elapsed / 3_600.0),
        ("overlaps", f64::from(overlaps)),
    ];
    if overlaps > 0 {
        return HealthFinding::new(
            Check,
            HealthStatus::Fail,
            format!("{overlaps} activity blocks overlap another block."),
        )
        .measuring(measurements);
    }
    if tracked > elapsed + CLOCK_TOLERANCE_SECONDS {
        return HealthFinding::new(
            Check,
            HealthStatus::Fail,
            format!(
                "Tracked {:.1} h exceeds the {:.1} h that elapsed.",
                tracked / 3_600.0,
                elapsed / 3_600.0
            ),
        )
        .measuring(measurements);
    }
    HealthFinding::new(
        Check,
        HealthStatus::Pass,
        format!("{:.1} h tracked, no overlaps.", tracked / 3_600.0),
    )
    .measuring(measurements)
}

fn finished_recordings(input: &HealthInput) -> HealthFinding {
    use HealthCheck::FinishedRecordings as Check;
    if !input.automatic_transcription {
        return HealthFinding::new(
            Check,
            HealthStatus::Pass,
            "Automatic transcription is off; recordings are transcribed when you ask.",
        );
    }
    let stuck: Vec<&RecordingHealth> = input
        .recordings
        .iter()
        .filter(|recording| recording.missing_transcript.is_some() && !recording.has_queued_job)
        .collect();
    if stuck.is_empty() {
        return HealthFinding::new(
            Check,
            HealthStatus::Pass,
            "Every finished recording has a transcript or a queued job.",
        );
    }
    let titles: Vec<&str> = stuck.iter().map(|r| r.title.as_str()).collect();
    HealthFinding::new(
        Check,
        HealthStatus::Fail,
        format!(
            "{} finished recordings have no transcript and no queued job: {}.",
            stuck.len(),
            titles.join(", ")
        ),
    )
    .measuring([("stuckRecordings", stuck.len() as f64)])
}

fn schedulers(input: &HealthInput) -> HealthFinding {
    let schedulers = &input.schedulers;
    let local_now = input.now.with_timezone(&Local);
    let start_of_today = local_day_bounds(local_day(input.now)).0;
    let mut status = HealthStatus::Pass;
    let mut problems: Vec<String> = Vec::new();
    if schedulers.digest_enabled
        && schedulers.automatic_inference_allowed
        && schedulers
            .previous_day
            .is_some_and(|past| past.needs_finalization())
        && (input.now - start_of_today).num_seconds() >= SCHEDULER_GRACE_SECONDS
    {
        status = HealthStatus::Fail;
        problems.push("yesterday's digest was not finished after midnight".into());
    }
    if schedulers.dreaming_enabled
        && schedulers.automatic_inference_allowed
        && schedulers.missing_dream_days > 0
        && local_now
            .with_hour(schedulers.dreaming_hour.min(23))
            .and_then(|at| at.with_minute(0))
            .and_then(|at| at.with_second(0))
            .is_some_and(|due| (local_now - due).num_seconds() >= SCHEDULER_GRACE_SECONDS)
    {
        status = status.max(if schedulers.missing_dream_days >= 2 {
            HealthStatus::Fail
        } else {
            HealthStatus::Warn
        });
        problems.push(format!(
            "{} eligible days were not dreamed",
            schedulers.missing_dream_days
        ));
    }
    let summary = if problems.is_empty() {
        "Scheduled digests and dreams ran when due.".to_string()
    } else {
        format!("Scheduler problem: {}.", problems.join("; "))
    };
    HealthFinding::new(HealthCheck::Schedulers, status, summary)
        .measuring([("missingDreamDays", schedulers.missing_dream_days as f64)])
}

fn digest_coverage(input: &HealthInput) -> HealthFinding {
    use HealthCheck::DigestCoverage as Check;
    let ratio = input
        .digest_coverage
        .filter(|coverage| coverage.tracked_seconds > 0.0)
        .map(|coverage| {
            (
                coverage,
                coverage.covered_seconds / coverage.tracked_seconds,
            )
        });
    let Some((coverage, ratio)) = ratio else {
        return HealthFinding::new(
            Check,
            HealthStatus::Pass,
            "No digest coverage recorded for this day.",
        );
    };
    let status = if ratio < DIGEST_COVERAGE_WARNING {
        HealthStatus::Warn
    } else {
        HealthStatus::Pass
    };
    HealthFinding::new(
        Check,
        status,
        format!("The digest covers {}% of tracked activity.", percent(ratio)),
    )
    .measuring([
        ("coverage", ratio),
        ("trackedHours", coverage.tracked_seconds / 3_600.0),
    ])
}

/// Finds a finished recording whose transcript is missing or incomplete
/// (`MissingTranscription.reason`).
pub fn missing_transcript(library: &Library, meeting: &Meeting) -> Option<MissingTranscript> {
    if meeting.merged_into_meeting_id.is_some() || meeting.ended_at.is_none() {
        return None;
    }
    let audio = library.audio(meeting);
    if meeting.duration_seconds() < MINIMUM_RECORDING_SECONDS
        || (audio.mic.is_none() && audio.system.is_none())
    {
        return None;
    }
    let folder = library.meeting_dir(meeting);
    if !folder.join("transcript.json").exists() {
        return Some(MissingTranscript::NeverTranscribed);
    }
    has_merged_source_gap(library, meeting, &folder).then_some(MissingTranscript::MergedGap)
}

/// Written before a merged-gap repair is queued, so a span that stays empty
/// (silence, for example) isn't transcribed again on every launch.
pub fn mark_gap_repair_requested(folder: &Path, at: DateTime<Utc>) -> anyhow::Result<()> {
    let marker = serde_json::json!({
        "requestedAt": at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    });
    write_atomic(
        &folder.join(GAP_REPAIR_MARKER),
        &serde_json::to_vec(&marker)?,
    )?;
    Ok(())
}

/// A merged meeting's transcript has no segment at all within the span of one of
/// its sources.
fn has_merged_source_gap(library: &Library, meeting: &Meeting, folder: &Path) -> bool {
    if folder.join(GAP_REPAIR_MARKER).exists() {
        return false;
    }
    let Some(manifest) = std::fs::read(folder.join("merge-manifest.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
    else {
        return false;
    };
    let Some(sources) = manifest["sources"].as_array() else {
        return false;
    };
    let Ok(Some(transcript)) = library.transcript(meeting) else {
        return false;
    };
    let mut offset = 0.0;
    for source in sources {
        let duration = source["duration"].as_f64().unwrap_or(0.0);
        let span_start = offset;
        offset += duration.max(0.0);
        if duration < MINIMUM_GAP_SECONDS {
            continue;
        }
        let covered = transcript
            .segments
            .iter()
            .any(|segment| segment.end > span_start && segment.start < span_start + duration);
        if !covered {
            return true;
        }
    }
    false
}

/// `DayDigestGenerationMetadataStore.completedAt`: when the day's journal was
/// finished, or `None` while it still needs a repair.
fn digest_completed_at(library: &Library, day: NaiveDate) -> Option<DateTime<Utc>> {
    let modified: DateTime<Utc> = std::fs::metadata(library.journal_path(day))
        .ok()?
        .modified()
        .ok()?
        .into();
    let Some(meta) = library.digest_meta(day).ok().flatten() else {
        return Some(modified);
    };
    let matches_journal = meta
        .journal_modified_at
        .is_some_and(|at| (at - modified).num_milliseconds().abs() < 500);
    if matches_journal
        && meta.quality != DigestQuality::Complete
        && meta.degraded_attempt_count < MAXIMUM_DEGRADED_ATTEMPTS
    {
        return None;
    }
    Some(modified)
}

pub fn reports_dir(root: &Path) -> PathBuf {
    root.join("diagnostics").join("health")
}

pub fn capture_traces_dir(root: &Path) -> PathBuf {
    root.join("diagnostics").join("capture-traces")
}

impl Library {
    fn private_share_history(&self, day: NaiveDate) -> Result<Vec<f64>> {
        let mut history = Vec::new();
        for offset in 1..=7 {
            let earlier = day - Duration::days(offset);
            let (start, end) = local_day_bounds(earlier);
            let blocks = clamped_blocks(&self.activity_blocks(start, end)?, start, end);
            let tracked = total(&blocks);
            if tracked <= 0.0 {
                continue;
            }
            let hidden: f64 = blocks
                .iter()
                .filter(|block| block.app == PRIVATE_APP)
                .map(ActivityBlock::duration_seconds)
                .sum();
            history.push(hidden / tracked);
        }
        Ok(history)
    }

    fn missing_dream_days(&self, settings: &Settings, yesterday: NaiveDate) -> usize {
        if !settings.dreaming_enabled {
            return 0;
        }
        let window_start = yesterday - Duration::days(DREAM_CATCH_UP_DAYS - 1);
        let first_eligible = settings
            .dreaming_first_eligible_day_key()
            .and_then(crate::dream::day_from_key)
            .unwrap_or(yesterday);
        let store = crate::dream::DreamStore::new(self.paths().root());
        let mut day = window_start.max(first_eligible);
        let mut missing = 0;
        while day <= yesterday {
            if !store.has_report(&crate::dream::day_key(day)) {
                missing += 1;
            }
            let Some(next) = day.succ_opt() else {
                break;
            };
            day = next;
        }
        missing
    }

    /// Gathers what `evaluate` judges for one day (`LibraryHealthLoader.input`).
    pub fn health_input(
        &self,
        day: NaiveDate,
        now: DateTime<Utc>,
        settings: &Settings,
        automatic_inference_allowed: bool,
    ) -> Result<HealthInput> {
        let (day_start, day_end) = local_day_bounds(day);
        let mut capture_counts_by_app: HashMap<String, usize> = HashMap::new();
        for moment in self.screen_moments(day_start, day_end)? {
            *capture_counts_by_app.entry(moment.app).or_default() += 1;
        }
        let queued: HashSet<Uuid> = self
            .pending_jobs()?
            .into_iter()
            .map(|job| job.meeting_id)
            .collect();
        let cutoff = now - Duration::days(RECORDINGS_WINDOW_DAYS);
        let recordings = self
            .list_meetings()?
            .iter()
            .filter(|meeting| meeting.ended_at.is_some_and(|ended| ended >= cutoff))
            .map(|meeting| RecordingHealth {
                meeting_id: meeting.id,
                title: meeting.title.clone(),
                missing_transcript: missing_transcript(self, meeting),
                has_queued_job: queued.contains(&meeting.id),
            })
            .collect();
        let yesterday = local_day(now) - Duration::days(1);
        Ok(HealthInput {
            day_start,
            day_end,
            now,
            blocks: self.activity_blocks(day_start, day_end)?,
            screen_capture_enabled: settings.tracking_enabled
                && settings.screen_context_capture_mode != crate::ScreenContextMode::ActivityOnly,
            capture_counts_by_app,
            private_share_history: self.private_share_history(day)?,
            recordings,
            automatic_transcription: settings.auto_transcribe,
            schedulers: SchedulerHealth {
                automatic_inference_allowed,
                digest_enabled: settings.day_digest_auto_enabled,
                previous_day: Some(PastDay {
                    day: yesterday,
                    latest_evidence_at: self.latest_evidence_at(yesterday)?,
                    digest_modified_at: digest_completed_at(self, yesterday),
                }),
                dreaming_enabled: settings.dreaming_enabled,
                dreaming_hour: settings.dreaming_hour,
                missing_dream_days: self.missing_dream_days(settings, yesterday),
            },
            digest_coverage: self
                .digest_meta(day)
                .ok()
                .flatten()
                .and_then(|m| m.coverage),
        })
    }

    /// Writes `<dayKey>.json` and `<dayKey>.md`; returns the Markdown path.
    pub fn write_health_report(&self, report: &HealthReport) -> Result<PathBuf> {
        let directory = reports_dir(self.paths().root());
        std::fs::create_dir_all(&directory)?;
        write_atomic(
            &directory.join(format!("{}.json", report.day_key)),
            &serde_json::to_vec_pretty(report)?,
        )?;
        let markdown = directory.join(format!("{}.md", report.day_key));
        write_atomic(&markdown, report.markdown().as_bytes())?;
        Ok(markdown)
    }

    /// When a health check last ran, from its reports.
    pub fn latest_health_run(&self) -> Option<DateTime<Utc>> {
        std::fs::read_dir(reports_dir(self.paths().root()))
            .ok()?
            .flatten()
            .filter(|entry| entry.path().extension().is_some_and(|e| e == "json"))
            .filter_map(|entry| std::fs::read(entry.path()).ok())
            .filter_map(|bytes| serde_json::from_slice::<HealthReport>(&bytes).ok())
            .map(|report| report.generated_at)
            .max()
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone as _;

    use super::*;

    /// Noon local time on `day`, for tests of "now".
    fn local_noon(day: NaiveDate) -> DateTime<Utc> {
        Local
            .from_local_datetime(&day.and_hms_opt(12, 0, 0).unwrap())
            .single()
            .unwrap()
            .with_timezone(&Utc)
    }

    fn block(app: &str, start: DateTime<Utc>, minutes: i64) -> ActivityBlock {
        ActivityBlock {
            id: 1,
            app: app.into(),
            title: String::new(),
            start,
            end: start + Duration::minutes(minutes),
        }
    }

    fn input(day: NaiveDate) -> HealthInput {
        let (day_start, day_end) = local_day_bounds(day);
        HealthInput {
            day_start,
            day_end,
            now: local_noon(day + Duration::days(1)),
            blocks: Vec::new(),
            screen_capture_enabled: true,
            capture_counts_by_app: HashMap::new(),
            private_share_history: Vec::new(),
            recordings: Vec::new(),
            automatic_transcription: true,
            schedulers: SchedulerHealth {
                automatic_inference_allowed: true,
                digest_enabled: false,
                previous_day: None,
                dreaming_enabled: false,
                dreaming_hour: 3,
                missing_dream_days: 0,
            },
            digest_coverage: None,
        }
    }

    fn day() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 10, 15).unwrap()
    }

    #[test]
    fn a_quiet_day_passes_every_check() {
        let report = evaluate(&input(day()), "2026-10-15");
        assert_eq!(report.status(), HealthStatus::Pass);
        assert_eq!(report.findings.len(), 6);
        assert_eq!(
            report.finding(HealthCheck::ActivityClock).unwrap().summary,
            "0.0 h tracked, no overlaps."
        );
    }

    #[test]
    fn an_app_with_long_activity_and_no_captures_fails_unless_exempt() {
        let start = local_noon(day());
        let mut seen = input(day());
        seen.blocks = vec![
            block("Editor", start, 45),
            block("Private", start + Duration::hours(1), 45),
            block("LokalBot", start + Duration::hours(2), 45),
            block("gnome-shell", start + Duration::hours(3), 45),
            block("Browser", start + Duration::hours(4), 10),
        ];
        let report = evaluate(&seen, "k");
        let finding = report.finding(HealthCheck::CaptureRate).unwrap();
        assert_eq!(finding.status, HealthStatus::Fail);
        assert_eq!(
            finding.summary,
            "No screen captures for Editor despite 30 or more minutes tracked."
        );
        seen.capture_counts_by_app.insert("Editor".into(), 2);
        assert_eq!(
            evaluate(&seen, "k")
                .finding(HealthCheck::CaptureRate)
                .unwrap()
                .status,
            HealthStatus::Pass
        );
        seen.capture_counts_by_app.clear();
        seen.screen_capture_enabled = false;
        assert_eq!(
            evaluate(&seen, "k")
                .finding(HealthCheck::CaptureRate)
                .unwrap()
                .summary,
            "Screen capture is turned off."
        );
    }

    #[test]
    fn private_share_warns_above_the_threshold_or_at_double_the_median() {
        let start = local_noon(day());
        let mut seen = input(day());
        seen.screen_capture_enabled = false;
        seen.blocks = vec![
            block("Private", start, 20),
            block("Editor", start + Duration::hours(1), 80),
        ];
        let high = evaluate(&seen, "k");
        let finding = high.finding(HealthCheck::PrivateShare).unwrap();
        assert_eq!(finding.status, HealthStatus::Warn);
        assert_eq!(
            finding.summary,
            "20% of tracked time was recorded as Private."
        );

        seen.blocks = vec![
            block("Private", start, 12),
            block("Editor", start + Duration::hours(1), 88),
        ];
        assert_eq!(
            evaluate(&seen, "k")
                .finding(HealthCheck::PrivateShare)
                .unwrap()
                .status,
            HealthStatus::Pass
        );
        seen.private_share_history = vec![0.05, 0.05, 0.06];
        let doubled = evaluate(&seen, "k");
        let finding = doubled.finding(HealthCheck::PrivateShare).unwrap();
        assert_eq!(finding.status, HealthStatus::Warn);
        assert_eq!(
            finding.summary,
            "12% of tracked time was recorded as Private (7-day median 5%)."
        );
    }

    #[test]
    fn overlaps_and_impossible_totals_fail_the_clock() {
        let start = local_noon(day());
        let mut seen = input(day());
        seen.screen_capture_enabled = false;
        seen.blocks = vec![
            block("A", start, 30),
            block("B", start + Duration::minutes(10), 5),
        ];
        let report = evaluate(&seen, "k");
        let finding = report.finding(HealthCheck::ActivityClock).unwrap();
        assert_eq!(finding.status, HealthStatus::Fail);
        assert_eq!(finding.summary, "1 activity blocks overlap another block.");
        assert_eq!(finding.measurements["overlaps"], 1.0);

        let (day_start, _) = local_day_bounds(day());
        seen.blocks = vec![block("A", day_start, 30)];
        seen.now = day_start + Duration::minutes(5);
        let report = evaluate(&seen, "k");
        assert!(
            report
                .finding(HealthCheck::ActivityClock)
                .unwrap()
                .summary
                .starts_with("Tracked 0.5 h exceeds")
        );

        // A block is cut to the day it's judged for.
        seen.blocks = vec![block("A", day_start - Duration::hours(2), 180)];
        seen.now = local_noon(day() + Duration::days(1));
        let report = evaluate(&seen, "k");
        assert_eq!(
            report.finding(HealthCheck::ActivityClock).unwrap().summary,
            "1.0 h tracked, no overlaps."
        );
    }

    #[test]
    fn recordings_stuck_without_a_job_fail_unless_transcription_is_manual() {
        let mut seen = input(day());
        seen.recordings = vec![
            RecordingHealth {
                meeting_id: Uuid::new_v4(),
                title: "Stuck".into(),
                missing_transcript: Some(MissingTranscript::NeverTranscribed),
                has_queued_job: false,
            },
            RecordingHealth {
                meeting_id: Uuid::new_v4(),
                title: "Queued".into(),
                missing_transcript: Some(MissingTranscript::MergedGap),
                has_queued_job: true,
            },
        ];
        let report = evaluate(&seen, "k");
        let finding = report.finding(HealthCheck::FinishedRecordings).unwrap();
        assert_eq!(finding.status, HealthStatus::Fail);
        assert_eq!(
            finding.summary,
            "1 finished recordings have no transcript and no queued job: Stuck."
        );
        seen.automatic_transcription = false;
        assert_eq!(
            evaluate(&seen, "k")
                .finding(HealthCheck::FinishedRecordings)
                .unwrap()
                .status,
            HealthStatus::Pass
        );
    }

    #[test]
    fn schedulers_are_judged_after_their_grace_period() {
        let mut seen = input(day());
        let (_, next) = local_day_bounds(day());
        seen.schedulers.digest_enabled = true;
        seen.schedulers.previous_day = Some(PastDay {
            day: day(),
            latest_evidence_at: Some(next - Duration::hours(1)),
            digest_modified_at: Some(next - Duration::minutes(30)),
        });
        let report = evaluate(&seen, "k");
        assert_eq!(
            report.finding(HealthCheck::Schedulers).unwrap().status,
            HealthStatus::Fail
        );
        // Still inside the grace period after midnight.
        seen.now = next + Duration::minutes(30);
        assert_eq!(
            evaluate(&seen, "k")
                .finding(HealthCheck::Schedulers)
                .unwrap()
                .status,
            HealthStatus::Pass
        );
        seen.now = local_noon(day() + Duration::days(1));
        // Finished after midnight: final.
        seen.schedulers.previous_day = Some(PastDay {
            day: day(),
            latest_evidence_at: Some(next - Duration::hours(1)),
            digest_modified_at: Some(next + Duration::minutes(5)),
        });
        assert_eq!(
            evaluate(&seen, "k")
                .finding(HealthCheck::Schedulers)
                .unwrap()
                .status,
            HealthStatus::Pass
        );
        // A remote model nobody approved isn't a scheduler problem.
        seen.schedulers.previous_day = Some(PastDay {
            day: day(),
            latest_evidence_at: Some(next - Duration::hours(1)),
            digest_modified_at: None,
        });
        seen.schedulers.automatic_inference_allowed = false;
        assert_eq!(
            evaluate(&seen, "k")
                .finding(HealthCheck::Schedulers)
                .unwrap()
                .status,
            HealthStatus::Pass
        );

        let mut dreams = input(day());
        dreams.schedulers.dreaming_enabled = true;
        dreams.schedulers.missing_dream_days = 1;
        assert_eq!(
            evaluate(&dreams, "k")
                .finding(HealthCheck::Schedulers)
                .unwrap()
                .status,
            HealthStatus::Warn
        );
        dreams.schedulers.missing_dream_days = 2;
        let report = evaluate(&dreams, "k");
        let finding = report.finding(HealthCheck::Schedulers).unwrap();
        assert_eq!(finding.status, HealthStatus::Fail);
        assert_eq!(
            finding.summary,
            "Scheduler problem: 2 eligible days were not dreamed."
        );
    }

    #[test]
    fn digest_coverage_warns_below_sixty_percent() {
        let mut seen = input(day());
        seen.digest_coverage = Some(DigestCoverage {
            covered_seconds: 50.0,
            tracked_seconds: 100.0,
        });
        let report = evaluate(&seen, "k");
        let finding = report.finding(HealthCheck::DigestCoverage).unwrap();
        assert_eq!(finding.status, HealthStatus::Warn);
        assert_eq!(
            finding.summary,
            "The digest covers 50% of tracked activity."
        );
        seen.digest_coverage = Some(DigestCoverage {
            covered_seconds: 60.0,
            tracked_seconds: 100.0,
        });
        assert_eq!(
            evaluate(&seen, "k")
                .finding(HealthCheck::DigestCoverage)
                .unwrap()
                .status,
            HealthStatus::Pass
        );
        seen.digest_coverage = Some(DigestCoverage {
            covered_seconds: 0.0,
            tracked_seconds: 0.0,
        });
        assert_eq!(
            evaluate(&seen, "k")
                .finding(HealthCheck::DigestCoverage)
                .unwrap()
                .summary,
            "No digest coverage recorded for this day."
        );
    }

    #[test]
    fn reports_read_and_write_the_macs_files() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let report = evaluate(&input(day()), "2026-10-15");
        let markdown = library.write_health_report(&report).unwrap();
        assert_eq!(
            markdown,
            dir.path().join("diagnostics/health/2026-10-15.md")
        );
        let text = std::fs::read_to_string(&markdown).unwrap();
        assert!(text.starts_with("# LokalBot health — 2026-10-15\n\nOverall: **PASS**\n\n"));
        assert!(text.contains("- **PASS** Finished recordings: Every finished recording"));
        let written =
            std::fs::read_to_string(dir.path().join("diagnostics/health/2026-10-15.json")).unwrap();
        let value: serde_json::Value = serde_json::from_str(&written).unwrap();
        assert_eq!(value["dayKey"], "2026-10-15");
        assert!(value["generatedAt"].as_str().unwrap().ends_with('Z'));
        assert_eq!(value["findings"][0]["check"], "captureRate");
        assert_eq!(value["findings"][0]["status"], "pass");
        assert!(written.find("\"dayKey\"") < written.find("\"findings\""));
        assert!(written.find("\"findings\"") < written.find("\"generatedAt\""));
        assert!(library.latest_health_run().is_some());

        // What the Mac writes decodes, with an absent measurements map.
        let mac: HealthReport = serde_json::from_value(serde_json::json!({
            "dayKey": "2026-10-14",
            "findings": [{"check": "schedulers", "status": "warn", "summary": "s"}],
            "generatedAt": "2026-10-15T09:00:00Z",
        }))
        .unwrap();
        assert_eq!(mac.status(), HealthStatus::Warn);
    }

    #[test]
    fn a_library_reports_missing_transcripts_and_queued_jobs() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let now = Utc::now();
        let mut meeting = library
            .create_meeting("Standup", "Zoom", now - Duration::hours(1))
            .unwrap();
        meeting.ended_at = Some(now - Duration::minutes(30));
        library.save_meeting(&meeting).unwrap();
        // No audio yet: nothing to transcribe.
        assert_eq!(missing_transcript(&library, &meeting), None);
        std::fs::write(library.meeting_dir(&meeting).join("mic.wav"), b"audio").unwrap();
        assert_eq!(
            missing_transcript(&library, &meeting),
            Some(MissingTranscript::NeverTranscribed)
        );
        let settings = Settings::default();
        let day = local_day(now);
        let seen = library.health_input(day, now, &settings, true).unwrap();
        assert_eq!(seen.recordings.len(), 1);
        assert!(!seen.recordings[0].has_queued_job);
        library.enqueue_job(meeting.id, true, true, true).unwrap();
        let seen = library.health_input(day, now, &settings, true).unwrap();
        assert!(seen.recordings[0].has_queued_job);
    }
}
