//! `transcript.json` (`LokalBot/Models/Transcript.swift`, `SpeakerAttribution.swift`).

use std::collections::BTreeMap;

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
            attribution.identity = SpeakerIdentity::User;
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
