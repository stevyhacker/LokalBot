//! The transcript as the notes pipeline reads it (`Transcript.swift`,
//! `SpeakerAttribution.swift`): normalized text, resolved attribution, the
//! speaker roster, stable segment IDs and the short `s#` citation IDs.

use std::collections::BTreeMap;
use std::sync::LazyLock;

use regex::Regex;

use lokalbot_core::Transcript;
use lokalbot_core::model::{
    AttributionMethod, AttributionSource, SpeakerAttribution, SpeakerIdentity,
};

static CONTROL_TOKEN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<\|[^>]*\|>").expect("valid regex"));

/// `Transcript.normalizedText`: control tokens removed, whitespace collapsed,
/// empty when nothing alphanumeric remains.
pub fn normalized_text(raw: &str) -> String {
    let without = CONTROL_TOKEN.replace_all(raw, " ");
    let collapsed = without.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().any(char::is_alphanumeric) {
        collapsed
    } else {
        String::new()
    }
}

/// `Transcript.defaultSpeakerName(for:)`.
pub fn default_speaker_name(speaker: &str) -> String {
    Transcript::default_speaker_name(speaker)
}

/// `SpeakerAttribution.legacy(speaker:).applyingMicrophoneDefault`.
pub fn resolved_attribution(
    segment: &lokalbot_core::model::Segment,
    microphone_is_user: bool,
) -> SpeakerAttribution {
    let key = Transcript::canonical_speaker_key(&segment.speaker);
    let mut attribution = segment.attribution.unwrap_or(SpeakerAttribution {
        source: if key == "me" {
            AttributionSource::Microphone
        } else {
            AttributionSource::Unknown
        },
        identity: if key == "me" {
            SpeakerIdentity::Unresolved
        } else {
            SpeakerIdentity::Other
        },
        method: AttributionMethod::Legacy,
    });
    if attribution.source == AttributionSource::Microphone
        && matches!(
            attribution.method,
            AttributionMethod::Track | AttributionMethod::Diarization | AttributionMethod::Legacy
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

pub fn identity_label(identity: SpeakerIdentity) -> &'static str {
    match identity {
        SpeakerIdentity::User => "user",
        SpeakerIdentity::Other => "other",
        SpeakerIdentity::Unresolved => "unresolved",
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Speaker {
    /// Canonical speaker key.
    pub id: String,
    pub name: String,
    pub identity: SpeakerIdentity,
}

impl Speaker {
    /// "You", or the name with "(identity unconfirmed)" / "(other speaker)".
    pub fn label(&self) -> String {
        let base = if self.identity == SpeakerIdentity::User {
            "You".to_string()
        } else {
            self.name.clone()
        };
        let suffix = match self.identity {
            SpeakerIdentity::Unresolved => " (identity unconfirmed)",
            SpeakerIdentity::Other if self.name.eq_ignore_ascii_case("me") => " (other speaker)",
            _ => "",
        };
        format!("{base}{suffix}")
    }
}

pub struct View<'a> {
    pub transcript: &'a Transcript,
    pub texts: Vec<String>,
    pub attributions: Vec<SpeakerAttribution>,
    pub keys: Vec<String>,
    pub roster: BTreeMap<String, Speaker>,
    pub segment_ids: Vec<String>,
}

impl<'a> View<'a> {
    pub fn new(transcript: &'a Transcript, microphone_is_user: bool) -> Self {
        let texts: Vec<String> = transcript
            .segments
            .iter()
            .map(|s| normalized_text(&s.text))
            .collect();
        let attributions: Vec<SpeakerAttribution> = transcript
            .segments
            .iter()
            .map(|s| resolved_attribution(s, microphone_is_user))
            .collect();
        let keys: Vec<String> = transcript
            .segments
            .iter()
            .map(|s| Transcript::canonical_speaker_key(&s.speaker))
            .collect();
        let segment_ids = transcript
            .segments
            .iter()
            .enumerate()
            .map(|(i, s)| Transcript::segment_id(i, s))
            .collect();
        let mut groups: BTreeMap<String, Vec<usize>> = BTreeMap::new();
        for (index, key) in keys.iter().enumerate() {
            groups.entry(key.clone()).or_default().push(index);
        }
        let roster = groups
            .into_iter()
            .map(|(key, rows)| {
                // Mixed voices and suspected echo cannot outvote the speaker.
                let mut identities: Vec<SpeakerIdentity> = rows
                    .iter()
                    .map(|i| attributions[*i])
                    .filter(|a| {
                        !matches!(
                            a.method,
                            AttributionMethod::OverlappingSpeech | AttributionMethod::SuspectedEcho
                        )
                    })
                    .map(|a| a.identity)
                    .collect();
                identities.dedup();
                identities.sort_by_key(|i| identity_label(*i));
                identities.dedup();
                let identity = if identities.len() == 1 {
                    identities[0]
                } else {
                    SpeakerIdentity::Unresolved
                };
                let name = match transcript.speaker_aliases.get(&key) {
                    Some(alias) => alias.clone(),
                    None if identity == SpeakerIdentity::User => "Me".into(),
                    None if key == "me" => "Local speaker".into(),
                    None => default_speaker_name(&key),
                };
                (
                    key.clone(),
                    Speaker {
                        id: key,
                        name,
                        identity,
                    },
                )
            })
            .collect();
        Self {
            transcript,
            texts,
            attributions,
            keys,
            roster,
            segment_ids,
        }
    }

    pub fn len(&self) -> usize {
        self.texts.len()
    }

    pub fn is_empty(&self) -> bool {
        self.texts.is_empty()
    }

    pub fn citation_id(index: usize) -> String {
        format!("s{}", index + 1)
    }

    /// The segment a `s#` citation ID names.
    pub fn index_of(&self, citation: &str) -> Option<usize> {
        let n: usize = citation.strip_prefix('s')?.parse().ok()?;
        (n >= 1 && n <= self.len()).then_some(n - 1)
    }

    pub fn is_own_voice(&self, index: usize) -> bool {
        !matches!(
            self.attributions[index].method,
            AttributionMethod::OverlappingSpeech | AttributionMethod::SuspectedEcho
        )
    }

    /// One prompt turn per piece of each non-empty segment; a segment longer
    /// than `max_characters` is split at word boundaries, each piece keeping
    /// the segment's `s#` (`summaryPromptTurns`).
    pub fn prompt_turns(&self, max_characters: usize) -> Vec<(usize, String)> {
        let limit = max_characters.max(200);
        let mut turns = Vec::new();
        for (index, text) in self.texts.iter().enumerate() {
            if text.is_empty() {
                continue;
            }
            for part in text_parts(text, limit) {
                turns.push((index, part));
            }
        }
        turns
    }
}

fn text_parts(text: &str, max_characters: usize) -> Vec<String> {
    let mut parts = Vec::new();
    let mut current = String::new();
    for word in text.split_whitespace() {
        let mut word: String = word.to_string();
        while word.chars().count() > max_characters {
            if !current.is_empty() {
                parts.push(std::mem::take(&mut current));
            }
            let head: String = word.chars().take(max_characters).collect();
            word = word.chars().skip(max_characters).collect();
            parts.push(head);
        }
        let proposed =
            current.chars().count() + usize::from(!current.is_empty()) + word.chars().count();
        if proposed > max_characters && !current.is_empty() {
            parts.push(std::mem::take(&mut current));
        }
        if !current.is_empty() {
            current.push(' ');
        }
        current.push_str(&word);
    }
    if !current.is_empty() {
        parts.push(current);
    }
    parts
}

/// SHA-256 over the transcript's sorted-key JSON: identifies the evidence a
/// summary or checkpoint was made from (`Transcript.evidenceRevision`; the
/// bytes differ from Swift's encoder, so the value is local to this port).
pub fn evidence_revision(transcript: &Transcript) -> String {
    let value = serde_json::to_value(transcript).unwrap_or_default();
    let bytes = serde_json::to_vec(&crate::json::sort_keys(value)).unwrap_or_default();
    lokalbot_core::library::sha256_hex(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::model::Segment;

    fn segment(speaker: &str, text: &str, attribution: Option<SpeakerAttribution>) -> Segment {
        Segment {
            start: 0.0,
            end: 1.0,
            speaker: speaker.into(),
            text: text.into(),
            confidence: None,
            timing_precision: None,
            attribution,
        }
    }

    #[test]
    fn legacy_rows_resolve_like_macos() {
        let transcript = Transcript {
            segments: vec![
                segment("me", "Hello <|en|> there", None),
                segment("them", "...", None),
                segment("them 2", "Sure", None),
                segment(
                    "local 2",
                    "Mixed",
                    Some(SpeakerAttribution {
                        source: AttributionSource::Microphone,
                        identity: SpeakerIdentity::Unresolved,
                        method: AttributionMethod::OverlappingSpeech,
                    }),
                ),
            ],
            ..Default::default()
        };
        let view = View::new(&transcript, true);
        assert_eq!(view.texts[0], "Hello there");
        assert_eq!(view.texts[1], "");
        assert_eq!(view.roster["me"].name, "Me");
        assert_eq!(view.roster["me"].identity, SpeakerIdentity::User);
        assert_eq!(view.roster["them"].name, "Them");
        assert_eq!(view.roster["them 2"].name, "Them 2");
        assert_eq!(view.roster["local 2"].identity, SpeakerIdentity::Unresolved);
        assert_eq!(
            view.roster["local 2"].label(),
            "Local 2 (identity unconfirmed)"
        );
        assert_eq!(view.roster["me"].label(), "You");
        assert_eq!(view.index_of("s2"), Some(1));
        assert_eq!(view.index_of("s9"), None);
        let unclear = View::new(&transcript, false);
        assert_eq!(unclear.roster["me"].identity, SpeakerIdentity::Unresolved);
        assert_eq!(unclear.roster["me"].name, "Local speaker");
    }

    #[test]
    fn long_segments_split_at_words() {
        let parts = text_parts("aaa bbb ccc ddd", 7);
        assert_eq!(parts, ["aaa bbb", "ccc ddd"]);
        let long = "x".repeat(450);
        let parts = text_parts(&long, 200);
        assert_eq!(
            parts.iter().map(|p| p.len()).collect::<Vec<_>>(),
            [200, 200, 50]
        );
    }
}
