//! Merging finished meetings into one (`MeetingMergeService.swift`).
//!
//! The merged meeting is the selected part of each source laid end to end.
//! Source folders are never changed beyond a marker that folds them into the
//! merged meeting, so Undo can bring them back. Speaker keys are prefixed with
//! their source, so "Me" in one recording can't claim a voice in another.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context as _;
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::library::{Library, TRANSCRIPT_FILE, read_json, write_json};
use crate::model::{Meeting, Transcript};

pub const MANIFEST_FILE: &str = "merge-manifest.json";
/// Shown where a recorded meeting shows its meeting app.
pub const MERGED_APP_NAME: &str = "Merged meetings";

#[derive(Debug, thiserror::Error)]
pub enum MergeError {
    #[error("Select at least two completed meetings to merge.")]
    NeedsAtLeastTwo,
    #[error("{0} is still recording. Stop it before merging.")]
    RecordingStillActive(String),
    #[error("{0} is still being processed. Wait for it to finish before merging.")]
    ProcessingInProgress(String),
    #[error("{0} is already folded into another merged meeting.")]
    AlreadyMerged(String),
    #[error("{0} has no readable audio or transcript to merge.")]
    NoUsableEvidence(String),
    #[error("{0} has no usable recorded duration.")]
    InvalidDuration(String),
    #[error("The merged meeting could not be created: {0}")]
    CannotCreateMeeting(String),
    #[error("No readable audio tracks were found in the selected meetings.")]
    NoAudioTracks,
    #[error("The merged audio could not be written: {0}")]
    ExportFailed(String),
}

impl MergeError {
    /// The message in the interface language.
    pub fn localized(&self) -> String {
        let title = |title: &String| [("title", title.clone())];
        match self {
            Self::NeedsAtLeastTwo => {
                lokalbot_i18n::tr("Select at least two completed meetings to merge.").into()
            }
            Self::RecordingStillActive(t) => lokalbot_i18n::format(
                "{title} is still recording. Stop it before merging.",
                &title(t),
            ),
            Self::ProcessingInProgress(t) => lokalbot_i18n::format(
                "{title} is still being processed. Wait for it to finish before merging.",
                &title(t),
            ),
            Self::AlreadyMerged(t) => lokalbot_i18n::format(
                "{title} is already folded into another merged meeting.",
                &title(t),
            ),
            Self::NoUsableEvidence(t) => lokalbot_i18n::format(
                "{title} has no readable audio or transcript to merge.",
                &title(t),
            ),
            Self::InvalidDuration(t) => {
                lokalbot_i18n::format("{title} has no usable recorded duration.", &title(t))
            }
            Self::CannotCreateMeeting(reason) => lokalbot_i18n::format(
                "The merged meeting could not be created: {reason}",
                &[("reason", reason.clone())],
            ),
            Self::NoAudioTracks => {
                lokalbot_i18n::tr("No readable audio tracks were found in the selected meetings.")
                    .into()
            }
            Self::ExportFailed(reason) => lokalbot_i18n::format(
                "The merged audio could not be written: {reason}",
                &[("reason", reason.clone())],
            ),
        }
    }
}

/// One source track's part of the merged timeline: `source` (when it has
/// that track) from `start` to `end` seconds, padded with silence to
/// `end - start` when the track is shorter.
#[derive(Clone, Debug, PartialEq)]
pub struct Slice {
    pub source: Option<PathBuf>,
    pub start: f64,
    pub end: f64,
}

/// Writes one merged track from `slices`, in order, and returns which slices
/// contributed audio. Nothing is written when none did.
pub type Splice<'a> = dyn Fn(&[Slice], &Path) -> std::io::Result<Vec<bool>> + 'a;

#[derive(Clone, Debug)]
pub struct MergeResult {
    pub meeting: Meeting,
    pub sources: Vec<Meeting>,
    pub transcript_segments: usize,
    /// False when a source part contributed no transcript; a requested
    /// summary must then transcribe the merged audio first.
    pub transcript_coverage_complete: bool,
}

#[derive(Clone, Debug)]
struct Source {
    meeting: Meeting,
    folder: PathBuf,
    duration: f64,
    start: f64,
    end: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub version: u32,
    pub sources: Vec<ManifestSource>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestSource {
    #[serde(with = "crate::ids::uuid_upper_serde")]
    pub id: Uuid,
    pub title: String,
    #[serde(with = "crate::time::iso_seconds")]
    pub started_at: DateTime<Utc>,
    pub duration: f64,
    /// Version 2. Older manifests stay readable without claiming coverage.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_audio: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_transcript: Option<bool>,
}

/// Whether `meetings` can be merged as selected (the selection bar's check).
pub fn can_merge(meetings: &[Meeting], processing: impl Fn(Uuid) -> bool) -> bool {
    meetings.len() >= 2
        && meetings
            .iter()
            .all(|m| !m.is_live() && m.is_own_work() && !processing(m.id))
}

/// Builds the merged meeting. On any failure the sources are left unfolded
/// and the half-made meeting is removed.
pub fn merge_meetings(
    library: &Library,
    meetings: &[Meeting],
    title: &str,
    splice: &Splice<'_>,
) -> Result<MergeResult, MergeError> {
    let sources = prepare_sources(library, meetings)?;
    let title = normalized_title(title, &sources);
    let started_at = sources[0].meeting.started_at;
    let relative = library
        .reserve_meeting_folder(&title, started_at)
        .map_err(|e| MergeError::CannotCreateMeeting(format!("{e:#}")))?;
    let folder = library.paths().meeting_dir(&relative);
    let mut folded: Vec<Meeting> = Vec::new();
    let result = build(
        library,
        &sources,
        &title,
        &relative,
        &folder,
        &mut folded,
        splice,
    );
    if result.is_err() {
        for source in &folded {
            let mut restored = source.clone();
            restored.merged_into_meeting_id = None;
            let _ = library.save_meeting(&restored);
        }
        let _ = fs::remove_dir_all(&folder);
    }
    result
}

fn build(
    library: &Library,
    sources: &[Source],
    title: &str,
    relative: &str,
    folder: &Path,
    folded: &mut Vec<Meeting>,
    splice: &Splice<'_>,
) -> Result<MergeResult, MergeError> {
    let fail = |e: anyhow::Error| MergeError::CannotCreateMeeting(format!("{e:#}"));
    let total: f64 = sources.iter().map(|s| s.duration).sum();
    let started_at = sources[0].meeting.started_at;
    let imported: Vec<String> = sources
        .iter()
        .flat_map(|s| s.meeting.imported_file_names.iter().flatten().cloned())
        .collect();
    let mut merged = Meeting::new(title, MERGED_APP_NAME, started_at, relative);
    merged.ended_at = Some(started_at + Duration::milliseconds((total * 1000.0).round() as i64));
    merged.recorded_duration = Some(total);
    merged.merged_source_meeting_ids = Some(sources.iter().map(|s| s.meeting.id).collect());
    // Screen context reads this marker: an imported source's span shows
    // unrelated screen activity, so the merge stays imported.
    merged.imported_file_names = (!imported.is_empty()).then_some(imported);

    let (transcript, transcript_sources) = merged_transcript(sources)?;
    if let Some(transcript) = &transcript {
        write_json(&folder.join(TRANSCRIPT_FILE), transcript).map_err(fail)?;
        crate::library::write_atomic(
            &folder.join(crate::library::TRANSCRIPT_MD_FILE),
            transcript.markdown().as_bytes(),
        )
        .map_err(|e| fail(e.into()))?;
    }

    let mut audio_sources = BTreeSet::new();
    let mut tracks = [false, false];
    for (index, name) in [crate::library::MIC_TRACK, crate::library::SYSTEM_TRACK]
        .into_iter()
        .enumerate()
    {
        let slices: Vec<Slice> = sources
            .iter()
            .map(|s| {
                let audio = library.audio(&s.meeting);
                Slice {
                    source: if index == 0 { audio.mic } else { audio.system },
                    start: s.start,
                    end: s.end,
                }
            })
            .collect();
        let contributed = splice(&slices, &folder.join(name))
            .map_err(|e| MergeError::ExportFailed(e.to_string()))?;
        for (source, used) in contributed.iter().enumerate() {
            if *used {
                audio_sources.insert(source);
                tracks[index] = true;
            }
        }
    }
    if !tracks[0] && !tracks[1] && transcript.is_none() {
        return Err(MergeError::NoAudioTracks);
    }
    merged.has_system_track = tracks[1];

    write_summary(library, title, &merged, sources, folder);
    let notes: Vec<String> = sources
        .iter()
        .filter_map(|s| {
            let text = library.notes(&s.meeting).ok()?;
            (!text.trim().is_empty())
                .then(|| format!("## {}\n\n{}", s.meeting.display_title(), text))
        })
        .collect();
    library
        .save_notes(&merged, &notes.join("\n\n"))
        .map_err(fail)?;
    let manifest = Manifest {
        version: 2,
        sources: sources
            .iter()
            .enumerate()
            .map(|(index, s)| ManifestSource {
                id: s.meeting.id,
                title: s.meeting.display_title(),
                started_at: s.meeting.started_at,
                duration: s.duration,
                has_audio: Some(audio_sources.contains(&index)),
                has_transcript: Some(transcript_sources.contains(&index)),
            })
            .collect(),
    };
    write_json(&folder.join(MANIFEST_FILE), &manifest).map_err(fail)?;
    library.save_meeting(&merged).map_err(fail)?;

    let affected: Vec<&Meeting> = sources.iter().map(|s| &s.meeting).collect();
    crate::evidence::with_meeting_mutation(library.paths().root(), &affected, || {
        for source in sources {
            let mut source = source.meeting.clone();
            source.merged_into_meeting_id = Some(merged.id);
            library.save_meeting(&source)?;
            folded.push(source);
        }
        Ok(())
    })
    .map_err(fail)?;
    library.tombstone_meetings(folded).map_err(fail)?;

    Ok(MergeResult {
        transcript_segments: transcript.as_ref().map_or(0, |t| t.segments.len()),
        transcript_coverage_complete: transcript_sources.len() == sources.len(),
        meeting: merged,
        sources: folded.clone(),
    })
}

fn prepare_sources(library: &Library, meetings: &[Meeting]) -> Result<Vec<Source>, MergeError> {
    if meetings.len() < 2 {
        return Err(MergeError::NeedsAtLeastTwo);
    }
    let mut ordered: Vec<&Meeting> = meetings.iter().collect();
    ordered.sort_by_key(|m| m.started_at);
    let mut seen = BTreeSet::new();
    let mut sources = Vec::new();
    for meeting in ordered {
        if !seen.insert(meeting.id) {
            continue;
        }
        let title = meeting.display_title();
        if meeting.is_merged_source() {
            return Err(MergeError::AlreadyMerged(title));
        }
        if meeting.is_live() {
            return Err(MergeError::RecordingStillActive(title));
        }
        let folder = library.meeting_dir(meeting);
        let audio = library.audio(meeting);
        let has_audio = audio.mic.is_some() || audio.system.is_some();
        if !folder.join(TRANSCRIPT_FILE).is_file() && !has_audio {
            return Err(MergeError::NoUsableEvidence(title));
        }
        let raw = meeting.duration_seconds();
        if !(raw.is_finite() && raw > 0.0) {
            return Err(MergeError::InvalidDuration(title));
        }
        let range = meeting.content_range;
        let start = range.map_or(0.0, |r| r.start).clamp(0.0, raw);
        let end = range.map_or(raw, |r| r.end).min(raw).max(start);
        if end <= start {
            return Err(MergeError::InvalidDuration(title));
        }
        sources.push(Source {
            meeting: meeting.clone(),
            folder,
            duration: end - start,
            start,
            end,
        });
    }
    if sources.len() < 2 {
        return Err(MergeError::NeedsAtLeastTwo);
    }
    Ok(sources)
}

fn normalized_title(title: &str, sources: &[Source]) -> String {
    let cleaned = title.split_whitespace().collect::<Vec<_>>().join(" ");
    if cleaned.is_empty() {
        sources[0].meeting.display_title()
    } else {
        cleaned
    }
}

/// The sources' segments inside their ranges, shifted onto the merged
/// timeline, with source-scoped speakers. Also returns which sources had any.
fn merged_transcript(
    sources: &[Source],
) -> Result<(Option<Transcript>, BTreeSet<usize>), MergeError> {
    let mut merged = Transcript {
        engine: "merged".into(),
        ..Default::default()
    };
    let mut covered = BTreeSet::new();
    let mut offset = 0.0;
    for (index, source) in sources.iter().enumerate() {
        let transcript: Option<Transcript> = read_json(&source.folder.join(TRANSCRIPT_FILE))
            .map_err(|_| {
                MergeError::CannotCreateMeeting(format!(
                    "the transcript for {} could not be read",
                    source.meeting.display_title()
                ))
            })?;
        if let Some(transcript) = transcript {
            let before = merged.segments.len();
            for segment in &transcript.segments {
                if segment.start < source.start
                    || segment.end > source.end
                    || segment.end <= segment.start
                    || Transcript::display_text(&segment.text).is_empty()
                {
                    continue;
                }
                let original = Transcript::canonical_speaker_key(&segment.speaker);
                let key = format!(
                    "source{}:{}",
                    index + 1,
                    if original.is_empty() {
                        "speaker"
                    } else {
                        &original
                    }
                );
                let mut shifted = segment.clone();
                shifted.speaker = key.clone();
                shifted.start = offset + segment.start - source.start;
                shifted.end = offset + segment.end - source.start;
                merged.segments.push(shifted);
                merged.speaker_aliases.insert(
                    key.clone(),
                    format!(
                        "{} · source {}",
                        transcript.speaker_name(&original),
                        index + 1
                    ),
                );
                if let Some(id) = transcript.speaker_calendar_identity_ids.get(&original) {
                    merged.speaker_calendar_identity_ids.insert(key, id.clone());
                }
            }
            if merged.segments.len() > before {
                covered.insert(index);
            }
        }
        offset += source.duration;
    }
    if merged.segments.is_empty() {
        return Ok((None, covered));
    }
    merged
        .segments
        .sort_by(|a, b| a.start.total_cmp(&b.start).then(a.end.total_cmp(&b.end)));
    Ok((Some(merged), covered))
}

fn write_summary(
    library: &Library,
    title: &str,
    merged: &Meeting,
    sources: &[Source],
    folder: &Path,
) {
    let date = merged
        .started_at
        .with_timezone(&chrono::Local)
        .format("%B %-d, %Y at %-I:%M %p");
    let minutes = merged.duration_seconds() as u64 / 60;
    let duration = if minutes >= 60 {
        format!("{}h {}m", minutes / 60, minutes % 60)
    } else {
        format!("{minutes} min")
    };
    let mut body = format!(
        "# {title} — {date}\n**Duration:** {duration} · **Sources:** {}\n\n",
        sources.len()
    );
    body.push_str(
        "This is a non-destructive merge. Source evidence remains on disk for provenance, \
         while the source rows are folded into this merged meeting. Speaker names stay \
         scoped to their source meeting until you confirm a name.\n\n",
    );
    for source in sources {
        body.push_str(&format!("## {}\n\n", source.meeting.display_title()));
        match library.summary(&source.meeting).ok().flatten() {
            Some(summary) if !summary.trim().is_empty() => {
                body.push_str(summary.trim());
                body.push_str("\n\n");
            }
            _ => body.push_str("No saved summary was available for this source meeting.\n\n"),
        }
    }
    let _ =
        crate::library::write_atomic(&folder.join(crate::library::SUMMARY_FILE), body.as_bytes());
}

#[derive(Debug, thiserror::Error)]
pub enum UndoError {
    #[error("This meeting does not contain a reversible merge.")]
    NotAMerge,
    #[error("Some original meetings could not be found, so the merge was kept intact.")]
    SourcesMissing,
    #[error("Could not undo the merge: {0}")]
    Failed(String),
}

impl UndoError {
    pub fn localized(&self) -> String {
        match self {
            Self::NotAMerge => {
                lokalbot_i18n::tr("This meeting does not contain a reversible merge.").into()
            }
            Self::SourcesMissing => lokalbot_i18n::tr(
                "Some original meetings could not be found, so the merge was kept intact.",
            )
            .into(),
            Self::Failed(reason) => lokalbot_i18n::format(
                "Could not undo the merge: {reason}",
                &[("reason", reason.clone())],
            ),
        }
    }
}

/// Removes a merged meeting and restores its sources (`AppState.undoMerge`).
/// The merged meeting goes first; a source whose restore fails keeps its
/// marker, and the next library load restores it.
pub fn undo_merge(library: &Library, merged: &Meeting) -> Result<Vec<Meeting>, UndoError> {
    let ids: BTreeSet<Uuid> = merged
        .merged_source_meeting_ids
        .iter()
        .flatten()
        .copied()
        .collect();
    if ids.len() < 2 {
        return Err(UndoError::NotAMerge);
    }
    let sources: Vec<Meeting> = library
        .list_all_meetings()
        .map_err(|e| UndoError::Failed(format!("{e:#}")))?
        .into_iter()
        .filter(|m| ids.contains(&m.id))
        .collect();
    if sources.len() != ids.len()
        || sources
            .iter()
            .any(|s| s.merged_into_meeting_id != Some(merged.id))
    {
        return Err(UndoError::SourcesMissing);
    }
    // Deleting the merged meeting alone: its sources are about to come back.
    let mut detached = merged.clone();
    detached.merged_source_meeting_ids = None;
    crate::evidence::with_meeting_mutation(library.paths().root(), &[merged], || {
        library.remove_meeting(&detached)
    })
    .map_err(|e| UndoError::Failed(format!("{e:#}")))?;
    let mut restored = Vec::new();
    for source in &sources {
        match library.restore_merged_source(source) {
            Ok(meeting) => restored.push(meeting),
            Err(err) => {
                log::warn!("restoring a merge source failed; retried on next load: {err:#}")
            }
        }
    }
    restored.sort_by_key(|m| m.started_at);
    Ok(restored)
}

/// Re-transcribing a merged meeting covers only sources that had audio.
/// Keeps the earlier transcript in the parts of sources that had text but
/// no audio, which would otherwise come back silent
/// (`MeetingMergeService.preservingTranscriptOnlySources`).
pub fn preserve_transcript_only_sources(
    previous: Option<&Transcript>,
    folder: &Path,
    regenerated: Transcript,
) -> anyhow::Result<Transcript> {
    let Some(previous) = previous else {
        return Ok(regenerated);
    };
    let Some(manifest) =
        read_json::<Manifest>(&folder.join(MANIFEST_FILE)).context("reading the merge manifest")?
    else {
        return Ok(regenerated);
    };
    if manifest.version < 2 {
        return Ok(regenerated);
    }
    let mut cursor = 0.0;
    let mut protected = Vec::new();
    for source in &manifest.sources {
        let end = cursor + source.duration;
        if source.has_transcript == Some(true) && source.has_audio == Some(false) {
            protected.push((cursor, end));
        }
        cursor = end;
    }
    if protected.is_empty() {
        return Ok(regenerated);
    }
    let preserved: Vec<_> = previous
        .segments
        .iter()
        .filter(|s| protected.iter().any(|(a, b)| s.start >= *a && s.end <= *b))
        .cloned()
        .collect();
    if preserved.is_empty() {
        return Ok(regenerated);
    }
    let mut combined = regenerated;
    combined
        .segments
        .retain(|s| !protected.iter().any(|(a, b)| s.end > *a && s.start < *b));
    let speakers: BTreeMap<String, ()> = preserved
        .iter()
        .map(|s| (Transcript::canonical_speaker_key(&s.speaker), ()))
        .collect();
    combined.segments.extend(preserved);
    combined
        .segments
        .sort_by(|a, b| a.start.total_cmp(&b.start).then(a.end.total_cmp(&b.end)));
    for speaker in speakers.keys() {
        if let Some(alias) = previous.speaker_aliases.get(speaker) {
            combined
                .speaker_aliases
                .insert(speaker.clone(), alias.clone());
        }
        if let Some(id) = previous.speaker_calendar_identity_ids.get(speaker) {
            combined
                .speaker_calendar_identity_ids
                .insert(speaker.clone(), id.clone());
        }
    }
    Ok(combined)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Segment;
    use crate::paths::LibraryPaths;

    fn finished(library: &Library, title: &str, minutes_ago: i64, seconds: f64) -> Meeting {
        let started = crate::time::now_seconds() - Duration::minutes(minutes_ago);
        let mut meeting = library.create_meeting(title, "Zoom", started).unwrap();
        meeting.ended_at = Some(started + Duration::seconds(seconds as i64));
        meeting.recorded_duration = Some(seconds);
        library.save_meeting(&meeting).unwrap();
        meeting
    }

    fn segment(start: f64, end: f64, speaker: &str, text: &str) -> Segment {
        serde_json::from_value(serde_json::json!({
            "start": start, "end": end, "speaker": speaker, "text": text
        }))
        .unwrap()
    }

    fn with_transcript(library: &Library, meeting: &Meeting, segments: Vec<Segment>) {
        let mut transcript = Transcript {
            segments,
            ..Default::default()
        };
        transcript
            .speaker_aliases
            .insert("them".into(), "Ana".into());
        transcript
            .speaker_calendar_identity_ids
            .insert("them".into(), "ana-id".into());
        library.save_transcript(meeting, &transcript).unwrap();
    }

    fn no_audio(slices: &[Slice], _: &Path) -> std::io::Result<Vec<bool>> {
        Ok(vec![false; slices.len()])
    }

    #[test]
    fn merge_creates_a_source_scoped_transcript_and_keeps_the_sources() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path())).unwrap();
        let first = finished(&library, "Design review", 120, 1_800.0);
        let second = finished(&library, "Launch check", 60, 1_800.0);
        for meeting in [&first, &second] {
            with_transcript(
                &library,
                meeting,
                vec![
                    segment(10.0, 20.0, "me", "Hello"),
                    segment(30.0, 40.0, "them", "Hi"),
                ],
            );
            library
                .save_summary(meeting, &format!("## TL;DR\n{}", meeting.title))
                .unwrap();
        }
        library.save_notes(&first, "Bring the roadmap").unwrap();

        let result =
            merge_meetings(&library, &[second.clone(), first.clone()], "", &no_audio).unwrap();
        let merged = &result.meeting;
        assert!(merged.is_merged_meeting());
        assert_eq!(
            merged.merged_source_meeting_ids.as_deref(),
            Some(&[first.id, second.id][..])
        );
        assert_eq!(
            merged.title, "Design review",
            "the first meeting's title by default"
        );
        assert_eq!(result.transcript_segments, 4);
        assert!(result.transcript_coverage_complete);
        assert_eq!(merged.recorded_duration, Some(3_600.0));

        let transcript = library.transcript(merged).unwrap().unwrap();
        assert_eq!(transcript.engine, "merged");
        assert!(transcript.segments[2].start >= 1_800.0);
        assert_eq!(transcript.speaker_aliases["source1:me"], "Me · source 1");
        assert_eq!(transcript.speaker_aliases["source2:them"], "Ana · source 2");
        assert_eq!(
            transcript.speaker_calendar_identity_ids["source2:them"],
            "ana-id"
        );
        let summary = library.summary(merged).unwrap().unwrap();
        assert!(summary.contains("## Design review") && summary.contains("## Launch check"));
        assert!(summary.contains("non-destructive merge"));
        assert_eq!(
            library.notes(merged).unwrap(),
            "## Design review\n\nBring the roadmap"
        );
        assert!(library.meeting_dir(merged).join(MANIFEST_FILE).is_file());

        let visible: Vec<_> = library
            .list_meetings()
            .unwrap()
            .iter()
            .map(|m| m.id)
            .collect();
        assert_eq!(visible, [merged.id]);
        let all = library.list_all_meetings().unwrap();
        assert_eq!(all.len(), 3);
        for source in all.iter().filter(|m| m.id != merged.id) {
            assert_eq!(source.merged_into_meeting_id, Some(merged.id));
            assert!(source.merged_source_meeting_ids.is_none());
            assert!(library.meeting_dir(source).join(TRANSCRIPT_FILE).is_file());
        }
    }

    #[test]
    fn a_source_without_transcript_needs_transcribing_and_keeps_text_only_parts() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path())).unwrap();
        let first = finished(&library, "Typed up", 120, 600.0);
        let second = finished(&library, "Recorded", 60, 600.0);
        fs::write(library.meeting_dir(&second).join("system.wav"), b"audio").unwrap();
        with_transcript(
            &library,
            &first,
            vec![segment(5.0, 9.0, "them", "From the notes")],
        );
        let second_has_audio = |slices: &[Slice], dest: &Path| {
            fs::write(dest, b"audio")?;
            Ok((0..slices.len()).map(|i| i == 1).collect())
        };
        let result = merge_meetings(&library, &[first, second], "Both", &second_has_audio).unwrap();
        assert!(!result.transcript_coverage_complete);
        assert_eq!(result.transcript_segments, 1);
        assert!(result.meeting.has_system_track);

        let folder = library.meeting_dir(&result.meeting);
        let previous = library.transcript(&result.meeting).unwrap();
        let regenerated = Transcript {
            segments: vec![
                segment(3.0, 4.0, "them", "silence misheard"),
                segment(700.0, 710.0, "them", "Recorded speech"),
            ],
            ..Default::default()
        };
        let combined =
            preserve_transcript_only_sources(previous.as_ref(), &folder, regenerated).unwrap();
        let texts: Vec<_> = combined.segments.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(texts, ["From the notes", "Recorded speech"]);
        assert_eq!(combined.speaker_aliases["source1:them"], "Ana · source 1");
    }

    #[test]
    fn a_failed_merge_leaves_the_library_as_it_was() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path())).unwrap();
        let first = finished(&library, "One", 120, 60.0);
        let second = finished(&library, "Two", 60, 60.0);
        fs::write(library.meeting_dir(&second).join("mic.wav"), b"audio").unwrap();
        with_transcript(&library, &first, vec![segment(1.0, 2.0, "me", "Hi")]);
        let failing = |_: &[Slice], _: &Path| -> std::io::Result<Vec<bool>> {
            Err(std::io::Error::other("disk full"))
        };
        let error = merge_meetings(&library, &[first, second], "", &failing).unwrap_err();
        assert!(matches!(error, MergeError::ExportFailed(_)), "{error}");
        let all = library.list_all_meetings().unwrap();
        assert_eq!(all.len(), 2);
        assert!(all.iter().all(|m| !m.is_merged_source()));
        let folders = fs::read_dir(
            library.paths().meetings_dir().join(
                crate::time::local_day(crate::time::now_seconds())
                    .format("%Y/%m")
                    .to_string(),
            ),
        )
        .unwrap()
        .count();
        assert_eq!(folders, 2, "the half-made merged meeting is removed");
    }

    #[test]
    fn merging_refuses_live_folded_and_single_meetings() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path())).unwrap();
        let done = finished(&library, "Done", 120, 60.0);
        with_transcript(&library, &done, vec![segment(1.0, 2.0, "me", "Hi")]);
        let live = library
            .create_meeting("Live", "Zoom", crate::time::now_seconds())
            .unwrap();
        assert!(matches!(
            merge_meetings(&library, std::slice::from_ref(&done), "", &no_audio),
            Err(MergeError::NeedsAtLeastTwo)
        ));
        assert!(matches!(
            merge_meetings(&library, &[done.clone(), live], "", &no_audio),
            Err(MergeError::RecordingStillActive(title)) if title == "Live"
        ));
        let mut folded = finished(&library, "Folded", 30, 60.0);
        folded.merged_into_meeting_id = Some(Uuid::new_v4());
        assert!(matches!(
            merge_meetings(&library, &[done.clone(), folded], "", &no_audio),
            Err(MergeError::AlreadyMerged(_))
        ));
        let empty = finished(&library, "Empty", 20, 60.0);
        assert!(matches!(
            merge_meetings(&library, &[done, empty], "", &no_audio),
            Err(MergeError::NoUsableEvidence(title)) if title == "Empty"
        ));
    }

    #[test]
    fn deleting_a_nested_merge_removes_every_source_but_nothing_else() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path())).unwrap();
        let meetings: Vec<Meeting> = (0..3)
            .map(|i| {
                let m = finished(&library, &format!("Part {i}"), 100 - i * 10, 60.0);
                with_transcript(&library, &m, vec![segment(1.0, 2.0, "me", "Hi")]);
                m
            })
            .collect();
        let unrelated = finished(&library, "Unrelated", 5, 60.0);
        let first = merge_meetings(&library, &meetings[..2], "", &no_audio).unwrap();
        let nested = merge_meetings(
            &library,
            &[first.meeting.clone(), meetings[2].clone()],
            "",
            &no_audio,
        )
        .unwrap();
        library.delete_meeting(&nested.meeting).unwrap();
        let left: Vec<_> = library
            .list_all_meetings()
            .unwrap()
            .iter()
            .map(|m| m.id)
            .collect();
        assert_eq!(left, [unrelated.id]);
    }
}
