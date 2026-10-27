//! What the meeting workspace shows, loaded off the main thread: the meeting
//! files plus everything derived from them for display (speaker names and
//! colors, the recap, actions with the user's corrections, transcript rows).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{DateTime, Local, Utc};
use gpui_kit::SharedString;
use lokalbot_core::{
    ActionReference, ActionStatus, Decision, Library, Meeting, MeetingOutcomes,
    OutcomeSourceCitation, Transcript,
};

/// A meeting's files and their display projection.
pub struct MeetingDoc {
    pub meeting: Meeting,
    pub folder: PathBuf,
    pub transcript: Option<Transcript>,
    pub summary: Option<String>,
    pub notes: String,
    pub outcomes: Option<MeetingOutcomes>,
    pub has_audio: bool,
    pub mic: Option<PathBuf>,
    pub system: Option<PathBuf>,
    /// Waveform overview, when the audio could be read.
    pub peaks: Option<Arc<[f32]>>,
    pub actions: Vec<MeetingAction>,
    pub decisions: Vec<Decision>,
    pub questions: Vec<String>,
    pub recap: Vec<String>,
    /// The summary's provenance line ("Duration 32m  ·  App Zoom").
    pub summary_meta: Option<String>,
    pub summary_body: String,
    pub rows: Vec<TranscriptRow>,
    pub review: Vec<ReviewSpeaker>,
    /// Remote speakers without a name (`unnamedRemoteSpeakers`).
    pub unnamed_remote: usize,
}

impl MeetingDoc {
    pub fn has_summary(&self) -> bool {
        self.summary
            .as_deref()
            .is_some_and(|s| !s.trim().is_empty())
    }

    pub fn has_transcript(&self) -> bool {
        self.transcript
            .as_ref()
            .is_some_and(|t| !t.segments.is_empty())
    }

    /// Row index whose segment contains `seconds` (or the nearest before it).
    pub fn row_at(&self, seconds: f64) -> Option<usize> {
        self.rows
            .iter()
            .position(|row| seconds >= row.start && seconds < row.end.max(row.start + 0.5))
            .or_else(|| self.rows.iter().rposition(|row| row.start <= seconds))
    }
}

/// An extracted action with the user's saved corrections applied.
#[derive(Clone, Debug)]
pub struct MeetingAction {
    pub id: String,
    pub text: String,
    pub original_text: String,
    pub owner: Option<String>,
    pub owner_label: Option<String>,
    pub due: Option<String>,
    /// "Due Fri, Oct 2 · said “Friday”".
    pub due_label: Option<String>,
    pub status: ActionStatus,
    pub citation: Option<OutcomeSourceCitation>,
}

#[derive(Clone, Debug)]
pub struct TranscriptRow {
    pub start: f64,
    pub end: f64,
    pub speaker: String,
    pub name: SharedString,
    pub color: usize,
    pub text: SharedString,
    pub begins_turn: bool,
}

#[derive(Clone, Debug)]
pub struct ReviewSpeaker {
    pub key: String,
    pub name: String,
    pub color: usize,
    pub is_user: bool,
    pub is_named: bool,
    pub can_confirm: bool,
    pub sample: Option<(f64, String)>,
    pub action_count: usize,
}

impl ReviewSpeaker {
    /// `MeetingSpeakerReviewItem.status`.
    pub fn status(&self) -> &'static str {
        if self.is_user {
            lokalbot_i18n::tr("Attributed to you")
        } else if !self.can_confirm {
            lokalbot_i18n::tr("Mixed or unresolved audio")
        } else if self.is_named {
            lokalbot_i18n::tr("Named in this meeting")
        } else {
            lokalbot_i18n::tr("Name not confirmed")
        }
    }
}

/// Display names and colors for a transcript's speakers
/// (`MeetingSpeakerPresentation.swift`).
#[derive(Default, Clone, Debug)]
pub struct Speakers {
    order: Vec<String>,
    colors: HashMap<String, usize>,
    names: HashMap<String, String>,
    users: HashSet<String>,
    owner_users: HashSet<String>,
}

impl Speakers {
    pub fn new(transcript: Option<&Transcript>) -> Self {
        let mut this = Self::default();
        let Some(transcript) = transcript else {
            return this;
        };
        for segment in &transcript.segments {
            let key = Transcript::canonical_speaker_key(&segment.speaker);
            if !this.order.contains(&key) {
                this.order.push(key);
            }
        }
        let mut next = 1;
        for key in &this.order {
            let is_user = transcript.speaker_identity(key) == lokalbot_core::SpeakerIdentity::User;
            let color = if is_user {
                this.users.insert(key.clone());
                0
            } else {
                next += 1;
                next - 1
            };
            this.colors.insert(key.clone(), color);
            let name = transcript.speaker_name(key);
            if is_user {
                this.owner_users.insert(name.to_lowercase());
            }
            this.names
                .insert(key.clone(), display_label(&name, is_user));
        }
        this
    }

    pub fn name(&self, speaker: &str) -> String {
        let key = Transcript::canonical_speaker_key(speaker);
        self.names
            .get(&key)
            .cloned()
            .unwrap_or_else(|| display_label(&Transcript::default_speaker_name(&key), false))
    }

    pub fn color_index(&self, speaker: &str) -> usize {
        self.colors
            .get(&Transcript::canonical_speaker_key(speaker))
            .copied()
            .unwrap_or(1)
    }

    /// An action owner as people should read it ("You", "Other speaker").
    pub fn owner(&self, value: &str, is_for_user: bool) -> String {
        display_label(
            value,
            is_for_user || self.owner_users.contains(&value.trim().to_lowercase()),
        )
    }
}

/// `SpeakerDisplayName.label`: "Me" (as the user) reads "You", "Them" reads
/// "Other speaker" and "Them 2" reads "Speaker 2".
pub fn display_label(name: &str, is_user: bool) -> String {
    let trimmed = name.trim();
    let lower = trimmed.to_lowercase();
    if lower == "me" {
        return if is_user {
            lokalbot_i18n::tr("You").into()
        } else {
            trimmed.to_string()
        };
    }
    if lower == "them" {
        return lokalbot_i18n::tr("Other speaker").into();
    }
    if let Some(n) = lower
        .strip_prefix("them ")
        .filter(|n| n.chars().all(|c| c.is_ascii_digit()) && !n.is_empty())
    {
        return lokalbot_i18n::format("Speaker {n}", &[("n", n.to_string())]);
    }
    trimmed.to_string()
}

fn is_placeholder_name(name: &str) -> bool {
    let lower = name.trim().to_lowercase();
    lower.is_empty()
        || [
            "me",
            "them",
            "you",
            "other speaker",
            "local speaker",
            "speaker unclear",
            "remote speaker",
        ]
        .contains(&lower.as_str())
        || lower
            .strip_prefix("speaker ")
            .is_some_and(|n| n.chars().all(|c| c.is_ascii_digit()))
        || lower
            .strip_prefix("them ")
            .is_some_and(|n| n.chars().all(|c| c.is_ascii_digit()))
}

/// An action with corrections applied (`Library::meeting_actions`), labelled
/// for display.
pub fn meeting_action(reference: ActionReference, speakers: &Speakers) -> MeetingAction {
    let owner_label = reference
        .owner
        .as_deref()
        .filter(|o| !o.trim().is_empty())
        .map(|o| speakers.owner(o, reference.is_for_user));
    let due_label = reference
        .due
        .as_deref()
        .map(|due| lokalbot_core::due::label(due, reference.due_reference_date()));
    MeetingAction {
        citation: reference.citations.first().cloned(),
        id: reference.action_id,
        text: reference.text,
        original_text: reference.original_text,
        owner: reference.owner,
        owner_label,
        due: reference.due,
        due_label,
        status: reference.status,
    }
}

/// Reads and projects one meeting. Runs on a background thread.
pub fn load(library: &Library, meeting: Meeting) -> MeetingDoc {
    let folder = library.meeting_dir(&meeting);
    let transcript = library.transcript(&meeting).unwrap_or_else(|err| {
        log::warn!("transcript for {}: {err:#}", meeting.id);
        None
    });
    let summary = library.summary(&meeting).ok().flatten();
    let notes = library.notes(&meeting).unwrap_or_default();
    let outcomes = library.outcomes(&meeting).ok().flatten();
    // The WAV tracks this app records, or the `.m4a` a macOS library keeps:
    // the player and the waveform read both.
    let audio = library.audio(&meeting);
    let mic = audio.mic.clone();
    let system = audio.system.clone();
    let has_audio = mic.is_some() || system.is_some();
    let tracks: Vec<&Path> = [mic.as_deref(), system.as_deref()]
        .into_iter()
        .flatten()
        .collect();
    let peaks = (!tracks.is_empty())
        .then(|| lokalbot_audio::waveform_peaks(&tracks, 720))
        .and_then(|result| {
            result
                .map_err(|err| log::warn!("waveform for {}: {err:#}", meeting.id))
                .ok()
        })
        .map(Arc::from);

    let speakers = Speakers::new(transcript.as_ref());
    let actions: Vec<MeetingAction> = library
        .meeting_actions(&meeting)
        .unwrap_or_else(|err| {
            log::warn!("actions for {}: {err:#}", meeting.id);
            Vec::new()
        })
        .into_iter()
        .map(|reference| meeting_action(reference, &speakers))
        .collect();
    let decisions = outcomes
        .as_ref()
        .map(|o| o.decision_records.clone())
        .unwrap_or_default();
    let questions = outcomes
        .as_ref()
        .map(|o| o.open_questions.clone())
        .unwrap_or_default();
    let (summary_meta, summary_body) = summary
        .as_deref()
        .map(split_summary)
        .unwrap_or((None, String::new()));
    let recap = summary
        .as_deref()
        .and_then(recap)
        .map(|text| recap_points(&text))
        .unwrap_or_default();
    let rows = transcript
        .as_ref()
        .map(|t| transcript_rows(t, &speakers))
        .unwrap_or_default();
    let review = transcript
        .as_ref()
        .map(|t| review_speakers(t, &speakers, &actions))
        .unwrap_or_default();

    let unnamed_remote = transcript
        .as_ref()
        .map(unnamed_remote_speakers)
        .unwrap_or(0);
    MeetingDoc {
        unnamed_remote,
        meeting,
        folder,
        transcript,
        summary,
        notes,
        outcomes,
        has_audio,
        mic,
        system,
        peaks,
        actions,
        decisions,
        questions,
        recap,
        summary_meta,
        summary_body,
        rows,
        review,
    }
}

/// Remote voices (system track or `them…`) the user has not named yet.
fn unnamed_remote_speakers(transcript: &Transcript) -> usize {
    let mut seen = Vec::<String>::new();
    for segment in &transcript.segments {
        let key = Transcript::canonical_speaker_key(&segment.speaker);
        let remote = key.starts_with("them")
            || Transcript::resolved_attribution(segment).source
                == lokalbot_core::AttributionSource::System;
        if remote && !transcript.speaker_aliases.contains_key(&key) && !seen.contains(&key) {
            seen.push(key);
        }
    }
    seen.len()
}

fn transcript_rows(transcript: &Transcript, speakers: &Speakers) -> Vec<TranscriptRow> {
    let mut rows: Vec<TranscriptRow> = Vec::with_capacity(transcript.segments.len());
    for segment in &transcript.segments {
        let text = Transcript::display_text(&segment.text);
        if text.is_empty() {
            continue;
        }
        let key = Transcript::canonical_speaker_key(&segment.speaker);
        let begins_turn = rows.last().is_none_or(|last| last.speaker != key);
        rows.push(TranscriptRow {
            start: segment.start,
            end: segment.end,
            name: speakers.name(&key).into(),
            color: speakers.color_index(&key),
            speaker: key,
            text: text.into(),
            begins_turn,
        });
    }
    rows
}

fn review_speakers(
    transcript: &Transcript,
    speakers: &Speakers,
    actions: &[MeetingAction],
) -> Vec<ReviewSpeaker> {
    let mut seen = Vec::<String>::new();
    for segment in &transcript.segments {
        let key = Transcript::canonical_speaker_key(&segment.speaker);
        if !seen.contains(&key) {
            seen.push(key);
        }
    }
    let mut items: Vec<ReviewSpeaker> = seen
        .iter()
        .map(|key| {
            let segments: Vec<_> = transcript
                .segments
                .iter()
                .filter(|s| Transcript::canonical_speaker_key(&s.speaker) == *key)
                .collect();
            let sample = segments
                .iter()
                .filter(|s| {
                    s.start.is_finite()
                        && s.end > s.start
                        && Transcript::display_text(&s.text).split_whitespace().count() >= 3
                })
                .max_by(|a, b| {
                    let score = |s: &&&lokalbot_core::Segment| {
                        (Transcript::display_text(&s.text)
                            .split_whitespace()
                            .count()
                            .min(25) as f64)
                            + (s.end - s.start).min(12.)
                    };
                    score(a)
                        .partial_cmp(&score(b))
                        .unwrap_or(std::cmp::Ordering::Equal)
                        .then(b.start.total_cmp(&a.start))
                })
                .map(|s| (s.start, Transcript::display_text(&s.text)));
            let name = speakers.name(key);
            let alias = transcript
                .speaker_aliases
                .get(key)
                .filter(|a| !a.trim().is_empty());
            let action_count = actions
                .iter()
                .filter(|a| {
                    a.owner
                        .as_deref()
                        .is_some_and(|o| Transcript::canonical_speaker_key(o) == *key || o == name)
                        || a.citation
                            .as_ref()
                            .is_some_and(|c| Transcript::canonical_speaker_key(&c.speaker) == *key)
                })
                .count();
            ReviewSpeaker {
                key: key.clone(),
                color: speakers.color_index(key),
                is_user: speakers.users.contains(key),
                is_named: alias.is_some() && !is_placeholder_name(&name),
                can_confirm: !key.contains("unclear"),
                sample,
                action_count,
                name,
            }
        })
        .collect();
    let order: HashMap<String, usize> = seen
        .iter()
        .enumerate()
        .map(|(ix, key)| (key.clone(), ix))
        .collect();
    items.sort_by(|a, b| {
        (b.action_count > 0)
            .cmp(&(a.action_count > 0))
            .then(b.action_count.cmp(&a.action_count))
            .then(order[&a.key].cmp(&order[&b.key]))
    });
    items
}

/// Lifts the "**Duration:** 32m · **App:** Zoom" provenance line out of the
/// summary body (`SummaryPresentation.split`).
pub fn split_summary(markdown: &str) -> (Option<String>, String) {
    let lines: Vec<&str> = markdown.lines().collect();
    for (index, line) in lines.iter().enumerate().take(4) {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let Some(items) = metadata_items(trimmed).filter(|items| items.len() >= 2) else {
            break;
        };
        let shown: Vec<String> = items
            .into_iter()
            .filter(|(label, value)| {
                label != "Sources" && !(label == "App" && value == "Merged meetings")
            })
            .map(|(label, value)| format!("{label} {value}"))
            .collect();
        let body = lines
            .iter()
            .enumerate()
            .filter(|(ix, _)| *ix != index)
            .map(|(_, l)| *l)
            .collect::<Vec<_>>()
            .join("\n")
            .trim()
            .to_string();
        return ((!shown.is_empty()).then(|| shown.join("  ·  ")), body);
    }
    (None, markdown.trim().to_string())
}

fn metadata_items(line: &str) -> Option<Vec<(String, String)>> {
    let mut items = Vec::new();
    for piece in line.split(" · ") {
        let piece = piece.trim();
        let rest = piece.strip_prefix("**")?;
        let (label, value) = rest.split_once(":**")?;
        let (label, value) = (label.trim(), value.trim());
        if label.is_empty() || value.is_empty() {
            return None;
        }
        items.push((label.to_string(), value.to_string()));
    }
    (!items.is_empty()).then_some(items)
}

/// The recap preview (`SummaryPresentation.recap`): the TL;DR section, or the
/// first prose paragraph.
pub fn recap(markdown: &str) -> Option<String> {
    let (_, body) = split_summary(markdown);
    let lines: Vec<&str> = body.lines().collect();
    if let Some(heading) = lines
        .iter()
        .position(|l| l.trim().eq_ignore_ascii_case("## tl;dr"))
    {
        let section = lines[heading + 1..]
            .iter()
            .take_while(|l| !l.trim_start().starts_with('#'))
            .copied()
            .collect::<Vec<_>>()
            .join("\n");
        let section = section.trim();
        if !section.is_empty() && !section.eq_ignore_ascii_case("none") {
            return recap_text(section);
        }
    }
    body.split("\n\n").find_map(|paragraph| {
        let content = paragraph
            .lines()
            .filter(|l| !l.trim_start().starts_with('#'))
            .collect::<Vec<_>>()
            .join("\n");
        let content = content.trim();
        if content.is_empty()
            || content.eq_ignore_ascii_case("none")
            || content.starts_with("- ")
            || content.starts_with("* ")
            || content.starts_with('|')
        {
            return None;
        }
        recap_text(content)
    })
}

fn recap_text(section: &str) -> Option<String> {
    let text = section
        .lines()
        .map(|line| {
            let trimmed = line.trim_start();
            let mut out = line.to_string();
            for bullet in ["- ", "* ", "• "] {
                if let Some(rest) = trimmed.strip_prefix(bullet) {
                    let rest = rest.trim_start();
                    // Drop a leading "**Label:**" from bullets.
                    let rest = rest
                        .strip_prefix("**")
                        .and_then(|r| r.split_once(":**").map(|(_, after)| after.trim_start()))
                        .unwrap_or(rest);
                    out = format!("• {rest}");
                    break;
                }
            }
            strip_trailing_stamp(&out)
        })
        .collect::<Vec<_>>()
        .join("\n");
    let text = text.trim().to_string();
    (!text.is_empty()).then_some(text)
}

/// Removes a trailing " — [00:12]" citation.
fn strip_trailing_stamp(line: &str) -> String {
    let trimmed = line.trim_end();
    if let Some(open) = trimmed.rfind('[')
        && trimmed.ends_with(']')
    {
        let inner = &trimmed[open + 1..trimmed.len() - 1];
        if lokalbot_core::time::parse_stamp(inner).is_some() {
            let before = trimmed[..open].trim_end();
            let before = before.trim_end_matches(['—', '–', '-']).trim_end();
            return before.to_string();
        }
    }
    trimmed.to_string()
}

/// One recap point per non-empty line.
pub fn recap_points(text: &str) -> Vec<String> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect()
}

// ------------------------------------------------------------------ labels

/// "Oct 8, 2026 at 11:57 AM".
pub fn date_label(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local)
        .format_localized(
            lokalbot_i18n::date_pattern("%b %-d, %Y at %-I:%M %p"),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}

/// Duration chip text: "2 min", "1 hr 5 min" (minutes floored, as on macOS).
pub fn duration_label(meeting: &Meeting) -> String {
    let minutes = (meeting.duration_seconds() / 60.).floor() as u64;
    if minutes >= 60 {
        lokalbot_i18n::format(
            "{0} hr {1} min",
            &[
                ("0", format!("{}", minutes / 60)),
                ("1", format!("{}", minutes % 60)),
            ],
        )
    } else {
        lokalbot_i18n::format("{minutes} min", &[("minutes", format!("{}", minutes))])
    }
}

/// List row metadata: "Zoom · 10:57 AM · 2 min"; merged meetings omit the app.
pub fn row_detail(meeting: &Meeting, live: bool) -> String {
    let time = if live {
        lokalbot_i18n::tr("in progress").to_string()
    } else {
        lokalbot_core::time::clock_time(meeting.started_at)
    };
    let duration = if live {
        lokalbot_i18n::format(
            "{0} min",
            &[(
                "0",
                format!(
                    "{}",
                    ((Utc::now() - meeting.started_at).num_seconds().max(60) / 60)
                ),
            )],
        )
    } else {
        duration_label(meeting)
    };
    if meeting.is_merged_meeting() {
        lokalbot_i18n::format(
            "{time} · {duration}",
            &[
                ("time", time.to_string()),
                ("duration", duration.to_string()),
            ],
        )
    } else {
        // The sample says what it is where a meeting names its app.
        let source = if meeting.is_sample() {
            lokalbot_i18n::tr("Sample").to_string()
        } else {
            meeting.app_name.to_string()
        };
        lokalbot_i18n::format(
            "{0} · {time} · {duration}",
            &[
                ("0", source),
                ("time", time.to_string()),
                ("duration", duration.to_string()),
            ],
        )
    }
}

// ------------------------------------------------------------------ export

/// The meeting as Markdown: title, metadata, notes, summary and transcript.
pub fn meeting_markdown(doc: &MeetingDoc) -> String {
    let meeting = &doc.meeting;
    let mut out = format!("# {}\n\n", meeting.display_title());
    let mut meta = vec![
        format!("**Date:** {}", date_label(meeting.started_at)),
        format!("**Duration:** {}", duration_label(meeting)),
    ];
    if !meeting.is_merged_meeting() {
        meta.push(format!("**App:** {}", meeting.app_name));
    }
    out.push_str(&meta.join(" · "));
    out.push_str("\n\n");
    if !doc.notes.trim().is_empty() {
        out.push_str("## Your notes\n\n");
        out.push_str(doc.notes.trim());
        out.push_str("\n\n");
    }
    if let Some(summary) = doc.summary.as_deref().filter(|s| !s.trim().is_empty()) {
        out.push_str(summary.trim());
        out.push_str("\n\n");
    }
    if let Some(transcript) = doc.transcript.as_ref().filter(|t| !t.segments.is_empty()) {
        out.push_str("## Transcript\n\n");
        out.push_str(&transcript.markdown());
        out.push('\n');
    }
    out
}

pub fn transcript_text(doc: &MeetingDoc) -> String {
    doc.rows
        .iter()
        .map(|row| {
            format!(
                "[{}] {}: {}",
                lokalbot_core::time::stamp(row.start),
                row.name,
                row.text
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recap_prefers_the_tldr_section() {
        let summary = "## TL;DR\nThe team chose Redis.\n\n## Decisions\n- Adopt Redis";
        assert_eq!(recap(summary).as_deref(), Some("The team chose Redis."));
    }

    #[test]
    fn recap_bullets_drop_labels_and_stamps() {
        let summary = "## TL;DR\n- **Caching:** Redis wins — [00:12]\n- Ship Friday";
        assert_eq!(
            recap_points(&recap(summary).unwrap()),
            vec!["• Redis wins", "• Ship Friday"]
        );
    }

    #[test]
    fn provenance_line_is_split_out() {
        let (meta, body) = split_summary("# Sync\n**Duration:** 32m · **App:** Zoom\n\nBody");
        assert_eq!(meta.as_deref(), Some("Duration 32m  ·  App Zoom"));
        assert_eq!(body, "# Sync\n\nBody");
    }

    #[test]
    fn speaker_labels_match_the_mac() {
        assert_eq!(display_label("Me", true), "You");
        assert_eq!(display_label("Them", false), "Other speaker");
        assert_eq!(display_label("Them 2", false), "Speaker 2");
        assert_eq!(display_label("Maya", false), "Maya");
    }
}
