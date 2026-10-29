//! `transcript.json` (`LokalBot/Models/Transcript.swift`, `SpeakerAttribution.swift`).

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Transcript {
    pub segments: Vec<Segment>,
    #[serde(default)]
    pub engine: String,
    /// Canonical speaker key (trimmed, lowercase) to the name the user gave it.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub speaker_aliases: BTreeMap<String, String>,
    /// Canonical speaker key to an opaque calendar participant ID.
    #[serde(
        default,
        skip_serializing_if = "BTreeMap::is_empty",
        rename = "speakerCalendarIdentityIDs"
    )]
    pub speaker_calendar_identity_ids: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub echo_report: Option<EchoReport>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Segment {
    /// Seconds from the start of the recording.
    pub start: f64,
    pub end: f64,
    /// `me`/`them` (legacy), `local`/`them`, or diarized `local N`/`them N`.
    pub speaker: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timing_precision: Option<TimingPrecision>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attribution: Option<SpeakerAttribution>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TimingPrecision {
    Coarse,
    Span,
    Token,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpeakerAttribution {
    pub source: AttributionSource,
    pub identity: SpeakerIdentity,
    pub method: AttributionMethod,
}

/// Settings → "My microphone is me" (`SpeakerAttribution.microphoneIsUser`).
/// One value for the whole process, as on macOS, so the meeting view,
/// `transcript.md`, search and Ask all label microphone speech the same way.
static MICROPHONE_IS_USER: AtomicBool = AtomicBool::new(true);

impl SpeakerAttribution {
    /// On by default: the personal microphone belongs to this computer's user.
    pub fn microphone_is_user() -> bool {
        MICROPHONE_IS_USER.load(Ordering::Relaxed)
    }

    /// Shared-room recordings turn it off, so unconfirmed microphone voices
    /// stay unidentified instead of being labelled as the user.
    pub fn set_microphone_is_user(value: bool) {
        MICROPHONE_IS_USER.store(value, Ordering::Relaxed);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AttributionSource {
    Microphone,
    System,
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SpeakerIdentity {
    User,
    Other,
    Unresolved,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AttributionMethod {
    Track,
    Diarization,
    OverlappingSpeech,
    SuspectedEcho,
    Confirmation,
    Profile,
    Legacy,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EchoReport {
    pub status: EchoStatus,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "reductionDB"
    )]
    pub reduction_db: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delay_seconds: Option<f64>,
    #[serde(default)]
    pub alignment_verified: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EchoStatus {
    Disabled,
    NoReference,
    Applied,
    Uncertain,
    Failed,
}

impl Transcript {
    /// Trimmed, lowercased key used for aliases and colors.
    pub fn canonical_speaker_key(speaker: &str) -> String {
        speaker.trim().to_lowercase()
    }

    /// Default names when no alias exists (`Transcript.defaultSpeakerName`):
    /// Them, Me, Local speaker, Speaker unclear; anything else capitalized
    /// ("them 2" → "Them 2").
    pub fn default_speaker_name(speaker: &str) -> String {
        let trimmed = speaker.trim();
        if trimmed.is_empty() {
            return "Speaker".into();
        }
        match Self::canonical_speaker_key(trimmed).as_str() {
            "them" => "Them".into(),
            "me" => "Me".into(),
            "local" => "Local speaker".into(),
            "local unclear" | "them unclear" => "Speaker unclear".into(),
            _ => trimmed
                .split(' ')
                .map(|word| {
                    let lower = word.to_lowercase();
                    let mut chars = lower.chars();
                    match chars.next() {
                        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                        None => String::new(),
                    }
                })
                .collect::<Vec<_>>()
                .join(" "),
        }
    }

    /// A segment's attribution, or the legacy one implied by its label, with
    /// the "my microphone is me" default applied (`resolvedAttribution`).
    pub fn resolved_attribution(segment: &Segment) -> SpeakerAttribution {
        Self::resolved_attribution_with(segment, SpeakerAttribution::microphone_is_user())
    }

    /// [`Self::resolved_attribution`] for a given "my microphone is me".
    pub fn resolved_attribution_with(
        segment: &Segment,
        microphone_is_user: bool,
    ) -> SpeakerAttribution {
        let mut attribution = segment.attribution.unwrap_or_else(|| {
            let is_me = Self::canonical_speaker_key(&segment.speaker) == "me";
            SpeakerAttribution {
                source: if is_me {
                    AttributionSource::Microphone
                } else {
                    AttributionSource::Unknown
                },
                identity: if is_me {
                    SpeakerIdentity::Unresolved
                } else {
                    SpeakerIdentity::Other
                },
                method: AttributionMethod::Legacy,
            }
        });
        if attribution.source == AttributionSource::Microphone
            && matches!(
                attribution.method,
                AttributionMethod::Track
                    | AttributionMethod::Diarization
                    | AttributionMethod::Legacy
            )
        {
            attribution.identity = if microphone_is_user {
                SpeakerIdentity::User
            } else {
                SpeakerIdentity::Unresolved
            };
        }
        attribution
    }

    /// One identity for every segment of a speaker key, else unresolved;
    /// overlapping speech and suspected echo never decide it.
    pub fn speaker_identity(&self, key: &str) -> SpeakerIdentity {
        let mut identities = self
            .segments
            .iter()
            .filter(|s| Self::canonical_speaker_key(&s.speaker) == key)
            .map(Self::resolved_attribution)
            .filter(|a| {
                !matches!(
                    a.method,
                    AttributionMethod::OverlappingSpeech | AttributionMethod::SuspectedEcho
                )
            })
            .map(|a| a.identity);
        match identities.next() {
            Some(first) if identities.all(|i| i == first) => first,
            _ => SpeakerIdentity::Unresolved,
        }
    }

    fn name_for_key(&self, key: &str, identity: SpeakerIdentity) -> String {
        if let Some(alias) = self.speaker_aliases.get(key) {
            return alias.clone();
        }
        if identity == SpeakerIdentity::User {
            return "Me".into();
        }
        if key == "me" {
            "Local speaker".into()
        } else {
            Self::default_speaker_name(key)
        }
    }

    /// Display name for a speaker: the user's alias, "Me" for the user's own
    /// voice, else the default name (`displaySpeaker(for:)`).
    pub fn speaker_name(&self, speaker: &str) -> String {
        let key = Self::canonical_speaker_key(speaker);
        self.name_for_key(&key, self.speaker_identity(&key))
    }

    /// Every speaker key's display name, computed once (`speakerRoster`).
    pub fn speaker_roster(&self) -> std::collections::HashMap<String, String> {
        let mut identities: std::collections::HashMap<String, Option<SpeakerIdentity>> =
            std::collections::HashMap::new();
        for segment in &self.segments {
            let key = Self::canonical_speaker_key(&segment.speaker);
            let attribution = Self::resolved_attribution(segment);
            let entry = identities.entry(key).or_insert(None);
            if matches!(
                attribution.method,
                AttributionMethod::OverlappingSpeech | AttributionMethod::SuspectedEcho
            ) {
                continue;
            }
            *entry = match *entry {
                None => Some(attribution.identity),
                Some(existing) if existing == attribution.identity => Some(existing),
                Some(_) => Some(SpeakerIdentity::Unresolved),
            };
        }
        identities
            .into_iter()
            .map(|(key, identity)| {
                let name = self.name_for_key(&key, identity.unwrap_or(SpeakerIdentity::Unresolved));
                (key, name)
            })
            .collect()
    }

    /// Carries the names the user gave speakers in `previous`, an earlier
    /// transcription of the same audio, onto this one
    /// (`SpeakerIdentityResolver.remap`). Diarization labels can change
    /// between runs, so a speaker takes a name by time, not by label: at
    /// least 80% of its speech must overlap one named speaker on the same
    /// track, and no other named speaker. Ambiguous and unnamed speakers keep
    /// their defaults, so a name the user removed stays removed.
    pub fn carry_speaker_names_from(&mut self, previous: &Transcript) {
        let named: Vec<_> = previous
            .speaker_turns()
            .into_iter()
            .filter(|(key, _)| {
                previous.speaker_aliases.contains_key(key)
                    || previous.speaker_calendar_identity_ids.contains_key(key)
            })
            .collect();
        if named.is_empty() {
            return;
        }
        for (key, (source, ranges)) in self.speaker_turns() {
            if self.speaker_aliases.contains_key(&key) {
                continue;
            }
            let duration: f64 = ranges.iter().map(|(start, end)| end - start).sum();
            if duration <= 0.0 {
                continue;
            }
            let mut candidates = named
                .iter()
                .filter(|(_, (old_source, _))| *old_source == source)
                .map(|(old_key, (_, old_ranges))| (old_key, overlap_seconds(&ranges, old_ranges)))
                .filter(|(_, seconds)| *seconds > 0.25);
            let Some((old_key, seconds)) = candidates.next() else {
                continue;
            };
            if candidates.next().is_some() || seconds / duration < 0.8 {
                continue;
            }
            if let Some(alias) = previous.speaker_aliases.get(old_key) {
                self.speaker_aliases.insert(key.clone(), alias.clone());
            }
            if let Some(id) = previous.speaker_calendar_identity_ids.get(old_key) {
                self.speaker_calendar_identity_ids.insert(key, id.clone());
            }
        }
    }

    /// Each speaker key's track and merged speaking time
    /// (`SpeakerAudioTurn`, with `legacySource` for unattributed segments).
    fn speaker_turns(&self) -> BTreeMap<String, (AttributionSource, Vec<(f64, f64)>)> {
        let mut turns: BTreeMap<String, (AttributionSource, Vec<(f64, f64)>)> = BTreeMap::new();
        for segment in &self.segments {
            let key = Self::canonical_speaker_key(&segment.speaker);
            let entry = turns.entry(key).or_insert_with_key(|key| {
                let source = match Self::resolved_attribution(segment).source {
                    AttributionSource::Unknown if key == "me" || key.starts_with("local") => {
                        AttributionSource::Microphone
                    }
                    AttributionSource::Unknown => AttributionSource::System,
                    known => known,
                };
                (source, Vec::new())
            });
            if segment.end > segment.start {
                entry.1.push((segment.start, segment.end));
            }
        }
        for (_, ranges) in turns.values_mut() {
            ranges.sort_by(|a, b| a.0.total_cmp(&b.0));
            let mut merged: Vec<(f64, f64)> = Vec::with_capacity(ranges.len());
            for &(start, end) in ranges.iter() {
                match merged.last_mut() {
                    Some(last) if start <= last.1 => last.1 = last.1.max(end),
                    _ => merged.push((start, end)),
                }
            }
            *ranges = merged;
        }
        turns
    }

    /// One `transcript.md` entry, or `None` for a segment without text.
    pub fn markdown_line(
        segment: &Segment,
        roster: &std::collections::HashMap<String, String>,
    ) -> Option<String> {
        let text = Self::display_text(&segment.text);
        if text.is_empty() {
            return None;
        }
        let name = roster
            .get(&Self::canonical_speaker_key(&segment.speaker))
            .cloned()
            .unwrap_or_else(|| Self::default_speaker_name(&segment.speaker));
        Some(format!(
            "**[{}] {}:** {}",
            crate::time::stamp(segment.start),
            name,
            text
        ))
    }

    /// `segment-%04d-%010lld-%010lld`: index, start ms, end ms.
    pub fn segment_id(index: usize, segment: &Segment) -> String {
        format!(
            "segment-{:04}-{:010}-{:010}",
            index,
            (segment.start * 1000.0).round() as i64,
            (segment.end * 1000.0).round() as i64
        )
    }

    /// Text with Whisper-style `<|…|>` control tokens removed and whitespace collapsed.
    pub fn display_text(text: &str) -> String {
        let mut out = String::with_capacity(text.len());
        let mut rest = text;
        while let Some(start) = rest.find("<|") {
            out.push_str(&rest[..start]);
            match rest[start..].find("|>") {
                Some(end) => rest = &rest[start + end + 2..],
                None => {
                    rest = "";
                }
            }
        }
        out.push_str(rest);
        out.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    /// `transcript.md`: `**[HH:MM:SS] Name:** text`, blank-line separated.
    pub fn markdown(&self) -> String {
        let roster = self.speaker_roster();
        self.segments
            .iter()
            .filter_map(|segment| Self::markdown_line(segment, &roster))
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    pub fn word_count(&self) -> usize {
        self.segments
            .iter()
            .map(|s| s.text.split_whitespace().count())
            .sum()
    }

    pub fn duration(&self) -> f64 {
        self.segments.iter().map(|s| s.end).fold(0.0, f64::max)
    }
}

impl SpeakerAttribution {
    pub fn microphone_user() -> Self {
        Self {
            source: AttributionSource::Microphone,
            identity: SpeakerIdentity::User,
            method: AttributionMethod::Track,
        }
    }

    pub fn system_other() -> Self {
        Self {
            source: AttributionSource::System,
            identity: SpeakerIdentity::Other,
            method: AttributionMethod::Track,
        }
    }
}

/// Seconds two sorted, disjoint range lists have in common.
fn overlap_seconds(a: &[(f64, f64)], b: &[(f64, f64)]) -> f64 {
    let (mut i, mut j, mut total) = (0, 0, 0.0);
    while i < a.len() && j < b.len() {
        let start = a[i].0.max(b[j].0);
        let end = a[i].1.min(b[j].1);
        if end > start {
            total += end - start;
        }
        if a[i].1 < b[j].1 {
            i += 1;
        } else {
            j += 1;
        }
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    fn segment(start: f64, end: f64, speaker: &str, source: AttributionSource) -> Segment {
        Segment {
            start,
            end,
            speaker: speaker.into(),
            text: "words".into(),
            confidence: None,
            timing_precision: None,
            attribution: Some(SpeakerAttribution {
                source,
                identity: SpeakerIdentity::Other,
                method: AttributionMethod::Diarization,
            }),
        }
    }

    fn names(transcript: &Transcript) -> Vec<(&str, &str)> {
        transcript
            .speaker_aliases
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect()
    }

    #[test]
    fn speaker_names_follow_the_voice_not_the_label() {
        use AttributionSource::{Microphone, System};
        let mut previous = Transcript {
            segments: vec![
                segment(0.0, 10.0, "them 1", System),
                segment(10.0, 20.0, "them 2", System),
                segment(20.0, 30.0, "them 1", System),
                segment(30.0, 40.0, "local 1", Microphone),
            ],
            ..Default::default()
        };
        previous
            .speaker_aliases
            .insert("them 1".into(), "Ana".into());
        previous
            .speaker_calendar_identity_ids
            .insert("them 1".into(), "ana-id".into());
        previous
            .speaker_aliases
            .insert("local 1".into(), "Marko".into());

        // Diarization swapped the labels and found a short speaker that only
        // partly overlaps Ana.
        let mut next = Transcript {
            segments: vec![
                segment(0.0, 10.0, "them 2", System),
                segment(20.5, 29.5, "them 2", System),
                segment(10.0, 20.0, "them 1", System),
                segment(29.0, 31.0, "them 3", System),
                segment(30.0, 40.0, "local 1", Microphone),
            ],
            ..Default::default()
        };
        next.carry_speaker_names_from(&previous);
        assert_eq!(names(&next), [("local 1", "Marko"), ("them 2", "Ana")]);
        assert_eq!(next.speaker_calendar_identity_ids["them 2"], "ana-id");
        assert_eq!(next.speaker_name("them 1"), "Them 1", "it was never named");
        assert_eq!(next.speaker_name("them 3"), "Them 3");
    }

    #[test]
    fn names_need_most_of_the_speech_and_the_same_track() {
        use AttributionSource::{Microphone, System};
        let mut previous = Transcript {
            segments: vec![segment(0.0, 10.0, "them 1", System)],
            ..Default::default()
        };
        previous
            .speaker_aliases
            .insert("them 1".into(), "Ana".into());
        let mut next = Transcript {
            segments: vec![
                // Half of this speaker's time is new speech.
                segment(5.0, 15.0, "them 1", System),
                // Same time, but the microphone track.
                segment(0.0, 10.0, "local 1", Microphone),
            ],
            ..Default::default()
        };
        next.carry_speaker_names_from(&previous);
        assert!(next.speaker_aliases.is_empty());

        // An alias the user already gave this transcript wins.
        let mut renamed = previous.clone();
        renamed
            .speaker_aliases
            .insert("them 1".into(), "Ana B".into());
        renamed.carry_speaker_names_from(&previous);
        assert_eq!(renamed.speaker_aliases["them 1"], "Ana B");
    }

    #[test]
    fn microphone_speech_is_the_user_only_when_the_setting_says_so() {
        let mut mic = segment(0.0, 1.0, "local", AttributionSource::Microphone);
        mic.attribution.as_mut().unwrap().method = AttributionMethod::Track;
        let legacy = Segment {
            attribution: None,
            ..segment(1.0, 2.0, "me", AttributionSource::Microphone)
        };
        for segment in [&mic, &legacy] {
            assert_eq!(
                Transcript::resolved_attribution_with(segment, true).identity,
                SpeakerIdentity::User
            );
            assert_eq!(
                Transcript::resolved_attribution_with(segment, false).identity,
                SpeakerIdentity::Unresolved
            );
        }
        let mut confirmed = mic.clone();
        confirmed.attribution.as_mut().unwrap().method = AttributionMethod::Confirmation;
        confirmed.attribution.as_mut().unwrap().identity = SpeakerIdentity::User;
        assert_eq!(
            Transcript::resolved_attribution_with(&confirmed, false).identity,
            SpeakerIdentity::User,
            "a confirmation keeps its identity"
        );
    }
}
