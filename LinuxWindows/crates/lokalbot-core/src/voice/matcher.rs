//! Voice comparison and enrollment rules (`SpeakerVoiceMatcher.swift`).
//!
//! The scores are the Mac's, measured there on pyannote vectors from real
//! calls. On TitaNet they were checked with `voice_calibration` and
//! `voice_meeting_check` (LibriSpeech dev-clean, 40 speakers, through Opus and
//! varied channels): no wrong automatic decision, but different people reached
//! 0.72 through one narrow noisy channel, and no real call has been measured.
//! So the engine shows strong matches for a person to apply; see
//! `NAME_SPEAKERS_AUTOMATICALLY` in `lokalbot-engine`.

use crate::model::AttributionSource;

use super::{
    AudioTurn, MatchSource, MatchTier, NameMatch, VOICE_DIMENSION, VOICE_MODEL, VoiceProfile,
    VoiceSample, merged_turns, name_key,
};

/// Call audio arrives codec-compressed, so a single 3–10 s chunk varies too
/// much to compare on its own; a speaker's average over many turns is stable.
pub mod call {
    pub const SAMPLE_LIMIT: usize = 16;
    /// Median sample-to-average similarity. A label that mixes voices falls below it.
    pub const MINIMUM_CONSISTENCY: f64 = 0.75;
    pub const SUGGESTED_SCORE: f64 = 0.60;
    pub const AUTOMATIC_SCORE: f64 = 0.70;
    /// Over the best remembered person with a different name.
    pub const AUTOMATIC_MARGIN: f64 = 0.15;
    pub const POLICY_VERSION: &str = "call-voiceprint-1";
}

#[derive(Clone, Debug, PartialEq)]
pub struct Voiceprint {
    pub vector: Vec<f32>,
    pub consistency: f64,
}

/// A unit vector of this model's length, or `None`.
pub fn normalized(vector: &[f32]) -> Option<Vec<f32>> {
    if vector.len() != VOICE_DIMENSION || vector.iter().any(|v| !v.is_finite()) {
        return None;
    }
    let norm = vector
        .iter()
        .map(|v| f64::from(*v) * f64::from(*v))
        .sum::<f64>()
        .sqrt();
    if norm <= 0.00001 || !norm.is_finite() {
        return None;
    }
    Some(
        vector
            .iter()
            .map(|v| (f64::from(*v) / norm) as f32)
            .collect(),
    )
}

pub fn cosine(lhs: &[f32], rhs: &[f32]) -> f64 {
    let (Some(a), Some(b)) = (normalized(lhs), normalized(rhs)) else {
        return -1.0;
    };
    a.iter()
        .zip(&b)
        .map(|(x, y)| f64::from(*x) * f64::from(*y))
        .sum()
}

/// The normalized average of `vectors` and how closely they agree with it.
pub fn voiceprint(vectors: &[&[f32]]) -> Option<Voiceprint> {
    let unit: Vec<Vec<f32>> = vectors.iter().filter_map(|v| normalized(v)).collect();
    if unit.is_empty() || unit.len() != vectors.len() {
        return None;
    }
    let mut sum = vec![0f64; VOICE_DIMENSION];
    for vector in &unit {
        for (total, value) in sum.iter_mut().zip(vector) {
            *total += f64::from(*value);
        }
    }
    let average = normalized(&sum.iter().map(|v| *v as f32).collect::<Vec<_>>())?;
    let mut agreement: Vec<f64> = unit.iter().map(|v| cosine(v, &average)).collect();
    agreement.sort_by(f64::total_cmp);
    let middle = agreement.len() / 2;
    let consistency = if agreement.len().is_multiple_of(2) {
        (agreement[middle - 1] + agreement[middle]) / 2.0
    } else {
        agreement[middle]
    };
    Some(Voiceprint {
        vector: average,
        consistency,
    })
}

pub(crate) fn sample_voiceprint(samples: &[VoiceSample]) -> Option<Voiceprint> {
    if samples.iter().any(|s| s.model != VOICE_MODEL) {
        return None;
    }
    voiceprint(
        &samples
            .iter()
            .map(|s| s.vector.as_slice())
            .collect::<Vec<_>>(),
    )
}

/// A remembered person's call voice: each confirmed meeting counts once.
fn call_voiceprint(profile: &VoiceProfile) -> Option<Voiceprint> {
    if profile.model != VOICE_MODEL {
        return None;
    }
    let mut meetings: Vec<Vec<f32>> = Vec::new();
    for contribution in &profile.contributions {
        let samples: Vec<VoiceSample> = contribution
            .samples
            .iter()
            .filter(|s| s.resolved_source() == AttributionSource::System)
            .cloned()
            .collect();
        if samples.is_empty() {
            continue;
        }
        let vector = contribution
            .voiceprint
            .clone()
            .or_else(|| sample_voiceprint(&samples).map(|p| p.vector));
        if let Some(vector) = vector {
            meetings.push(vector);
        }
    }
    voiceprint(&meetings.iter().map(Vec::as_slice).collect::<Vec<_>>())
}

/// At most one disjoint chunk from each independent, uncontaminated speaking
/// turn. Overlapping diarizer windows are never extra votes.
pub fn eligible(samples: &[VoiceSample], turns: &[AudioTurn], speaker: &str) -> Vec<VoiceSample> {
    if turns
        .iter()
        .find(|t| t.speaker == speaker)
        .is_some_and(|t| t.resolved_source() == AttributionSource::System)
    {
        return call_eligible(samples, turns, speaker);
    }
    let clean_turns: Vec<AudioTurn> = merged_turns(turns)
        .into_iter()
        .filter(|t| t.speaker == speaker && t.range.duration() >= 3.0)
        .collect();
    let mut selected: Vec<VoiceSample> = Vec::new();
    for turn in &clean_turns {
        let mut candidates: Vec<&VoiceSample> = samples
            .iter()
            .filter(|sample| {
                sample.speaker == speaker
                    && sample.model == VOICE_MODEL
                    && sample.range.is_valid()
                    && sample.range.duration() >= 3.0
                    && sample.range.overlap(&turn.range) >= sample.range.duration() * 0.95
                    && !turns.iter().any(|other| {
                        other.speaker != speaker
                            && other.resolved_source() == sample.resolved_source()
                            && other.range.overlap(&sample.range) > 0.02
                    })
                    && !selected
                        .iter()
                        .any(|s| s.range.overlap(&sample.range) > 0.0)
                    && normalized(&sample.vector).is_some()
            })
            .collect();
        candidates.sort_by(|a, b| b.range.duration().total_cmp(&a.range.duration()));
        if let Some(best) = candidates.first()
            && let Some(vector) = normalized(&best.vector)
        {
            let mut best = (*best).clone();
            best.vector = vector;
            selected.push(best);
        }
        if selected.len() == 8 {
            break;
        }
    }
    // A mixed cluster is unsafe to enroll, even if some of its samples agree.
    let consistent = selected.iter().all(|a| {
        selected
            .iter()
            .all(|b| cosine(&a.vector, &b.vector) >= 0.75)
    });
    if consistent { selected } else { Vec::new() }
}

/// Call speakers: the longest disjoint chunks no other speaker overlaps,
/// wherever they fall. Their average is checked for a mixed voice instead of
/// every pair.
fn call_eligible(samples: &[VoiceSample], turns: &[AudioTurn], speaker: &str) -> Vec<VoiceSample> {
    let others: Vec<&AudioTurn> = turns
        .iter()
        .filter(|t| t.speaker != speaker && t.resolved_source() == AttributionSource::System)
        .collect();
    let mut candidates: Vec<&VoiceSample> = samples
        .iter()
        .filter(|sample| {
            sample.speaker == speaker
                && sample.model == VOICE_MODEL
                && sample.resolved_source() == AttributionSource::System
                && sample.range.is_valid()
                && sample.range.duration() >= 3.0
                && !others.iter().any(|t| t.range.overlap(&sample.range) > 0.02)
        })
        .collect();
    candidates.sort_by(|a, b| b.range.duration().total_cmp(&a.range.duration()));
    let mut selected: Vec<VoiceSample> = Vec::new();
    for sample in candidates {
        if selected
            .iter()
            .any(|s| s.range.overlap(&sample.range) > 0.0)
        {
            continue;
        }
        let Some(vector) = normalized(&sample.vector) else {
            continue;
        };
        let mut sample = sample.clone();
        sample.vector = vector;
        selected.push(sample);
        if selected.len() == call::SAMPLE_LIMIT {
            break;
        }
    }
    selected.sort_by(|a, b| a.range.start.total_cmp(&b.range.start));
    selected
}

/// Three separate turns of clear speech totaling 15 seconds, from one voice.
pub fn can_enroll(samples: &[VoiceSample]) -> bool {
    let Some(first) = samples.first() else {
        return false;
    };
    let is_call = first.resolved_source() == AttributionSource::System;
    if samples.len() < 3
        || samples.len() > if is_call { call::SAMPLE_LIMIT } else { 8 }
        || samples.iter().any(|s| {
            s.model != VOICE_MODEL || !s.range.is_valid() || normalized(&s.vector).is_none()
        })
        || samples.iter().any(|s| s.speaker != first.speaker)
        || samples
            .iter()
            .any(|s| s.resolved_source() != first.resolved_source())
        || samples.iter().map(|s| s.range.duration()).sum::<f64>() < 15.0
    {
        return false;
    }
    for (index, sample) in samples.iter().enumerate() {
        for other in &samples[index + 1..] {
            if sample.range.overlap(&other.range) > 0.0
                || (!is_call && cosine(&sample.vector, &other.vector) < 0.75)
            {
                return false;
            }
        }
    }
    !is_call
        || sample_voiceprint(samples).is_some_and(|p| p.consistency >= call::MINIMUM_CONSISTENCY)
}

/// Remembered people these samples sound like, best first.
pub fn matches(samples: &[VoiceSample], profiles: &[VoiceProfile]) -> Vec<NameMatch> {
    if samples.is_empty()
        || samples.iter().any(|s| {
            s.model != VOICE_MODEL || !s.range.is_valid() || normalized(&s.vector).is_none()
        })
    {
        return Vec::new();
    }
    let domain = samples[0].resolved_source();
    if samples.iter().any(|s| s.resolved_source() != domain) {
        return Vec::new();
    }
    if domain == AttributionSource::System {
        return call_matches(samples, profiles);
    }
    let mut scored: Vec<(&VoiceProfile, f64, f64)> = Vec::new();
    for profile in profiles.iter().filter(|p| p.model == VOICE_MODEL) {
        let exemplars: Vec<&VoiceSample> = profile
            .contributions
            .iter()
            .flat_map(|c| &c.samples)
            .filter(|s| {
                s.model == VOICE_MODEL
                    && normalized(&s.vector).is_some()
                    && s.resolved_source() == domain
            })
            .collect();
        if exemplars.len() < 3 {
            continue;
        }
        let scores: Vec<f64> = samples
            .iter()
            .map(|sample| {
                exemplars
                    .iter()
                    .map(|e| cosine(&sample.vector, &e.vector))
                    .fold(-1.0, f64::max)
            })
            .collect();
        let mean = scores.iter().sum::<f64>() / scores.len() as f64;
        let minimum = scores.iter().copied().fold(f64::INFINITY, f64::min);
        scored.push((profile, mean, minimum));
    }
    scored.sort_by(|a, b| b.1.total_cmp(&a.1));
    let seconds: f64 = samples.iter().map(|s| s.range.duration()).sum();
    scored
        .into_iter()
        .take(3)
        .filter(|(_, mean, minimum)| *mean >= 0.72 && *minimum >= 0.65)
        // Microphone recognition requires its own held-out calibration.
        .map(|(profile, mean, _)| {
            name_match(profile, samples, MatchTier::Suggested, seconds, mean, None)
        })
        .collect()
}

/// One average per call speaker against each remembered person's average.
/// Remembered people who share a name never block each other.
fn call_matches(samples: &[VoiceSample], profiles: &[VoiceProfile]) -> Vec<NameMatch> {
    if samples.len() < 2 {
        return Vec::new();
    }
    let Some(query) =
        sample_voiceprint(samples).filter(|q| q.consistency >= call::MINIMUM_CONSISTENCY)
    else {
        return Vec::new();
    };
    let mut scored: Vec<(&VoiceProfile, f64)> = profiles
        .iter()
        .filter_map(|profile| {
            let remembered = call_voiceprint(profile)?;
            Some((profile, cosine(&query.vector, &remembered.vector)))
        })
        .collect();
    scored.sort_by(|a, b| b.1.total_cmp(&a.1));
    let seconds: f64 = samples.iter().map(|s| s.range.duration()).sum();
    scored
        .iter()
        .take(3)
        .filter(|(_, score)| *score >= call::SUGGESTED_SCORE)
        .map(|(profile, score)| {
            let name = name_key(&profile.name);
            let next = scored
                .iter()
                .filter(|(other, _)| name_key(&other.name) != name)
                .map(|(_, score)| *score)
                .fold(-1.0, f64::max);
            let automatic = samples.len() >= 3
                && seconds >= 15.0
                && *score >= call::AUTOMATIC_SCORE
                && *score - next >= call::AUTOMATIC_MARGIN;
            name_match(
                profile,
                samples,
                if automatic {
                    MatchTier::Automatic
                } else {
                    MatchTier::Suggested
                },
                seconds,
                *score,
                Some(call::POLICY_VERSION),
            )
        })
        .collect()
}

fn name_match(
    profile: &VoiceProfile,
    samples: &[VoiceSample],
    tier: MatchTier,
    seconds: f64,
    score: f64,
    policy: Option<&str>,
) -> NameMatch {
    NameMatch {
        name: profile.name.clone(),
        participant_reference: crate::ids::uuid_upper(&profile.id),
        tier,
        source: MatchSource::Profile,
        support_seconds: seconds,
        independent_turns: samples.len(),
        support_fraction: score,
        contradiction_seconds: 0.0,
        evidence: samples.iter().take(8).map(|s| s.range).collect(),
        profile_id: Some(profile.id),
        profile_revision: Some(profile.revision),
        policy_version: policy
            .map(str::to_string)
            .unwrap_or_else(super::default_policy_version),
    }
}
