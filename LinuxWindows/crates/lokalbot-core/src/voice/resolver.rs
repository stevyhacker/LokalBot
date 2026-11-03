//! Carrying names across transcriptions and applying matches
//! (`SpeakerIdentityResolver.swift`).

use std::collections::BTreeMap;

use super::{
    Assignment, AudioTurn, MatchSource, MatchTier, NameMatch, Origin, VoiceProfile, name_key, union,
};

/// Match by retained turns in the same audio revision. A clean split can
/// inherit; a merge of different people or any ambiguous overlap cannot.
pub fn remap(
    previous: &[Assignment],
    turns: &[AudioTurn],
    audio_revision: &str,
) -> Vec<Assignment> {
    let mut groups: BTreeMap<&str, Vec<&AudioTurn>> = BTreeMap::new();
    for turn in turns {
        groups.entry(turn.speaker.as_str()).or_default().push(turn);
    }
    let mut output = Vec::new();
    for (label, new_turns) in groups {
        let anchors = union(new_turns.iter().map(|t| t.range));
        let duration: f64 = anchors.iter().map(|a| a.duration()).sum();
        if duration <= 0.0 {
            continue;
        }
        let source = new_turns.first().map(|t| t.resolved_source());
        let mut candidates: Vec<(&Assignment, f64)> = previous
            .iter()
            .filter(|a| a.audio_revision == audio_revision && Some(a.resolved_source()) == source)
            .map(|assignment| {
                let theirs = union(assignment.anchors.iter().copied());
                let overlap: f64 = anchors
                    .iter()
                    .map(|anchor| theirs.iter().map(|t| anchor.overlap(t)).sum::<f64>())
                    .sum();
                (assignment, overlap / duration)
            })
            .filter(|(_, share)| share * duration > 0.25)
            .collect();
        candidates.sort_by(|a, b| b.1.total_cmp(&a.1));
        let Some((best, share)) = candidates.first().copied() else {
            continue;
        };
        if share < 0.8 || candidates[1..].iter().any(|(other, _)| other.id != best.id) {
            continue;
        }
        let mut assignment = best.clone();
        assignment.label = label.to_string();
        assignment.anchors = anchors;
        output.push(assignment);
    }
    output
}

/// Applies voice matches to an unprotected assignment and returns the ones to
/// offer. A different name is withdrawn into review, never silently replaced.
pub fn apply(
    candidates: &[NameMatch],
    assignment: &mut Assignment,
    profiles: &[VoiceProfile],
) -> Vec<NameMatch> {
    let allowed: Vec<NameMatch> = candidates
        .iter()
        .filter(|c| !assignment.suppressed_names.contains(&name_key(&c.name)))
        .cloned()
        .collect();
    if assignment.origin.is_protected() || assignment.automatic_disabled {
        return Vec::new();
    }
    let visual = allowed.iter().find(|c| c.source == MatchSource::Visual);
    let voice = allowed.iter().find(|c| c.source == MatchSource::Profile);
    let mut conflict = false;
    if let (Some(visual), Some(voice)) = (visual, voice)
        && visual.support_seconds >= 2.0
    {
        let linked = profiles
            .iter()
            .find(|p| Some(p.id) == voice.profile_id)
            .map(|p| p.confirmed_names.clone())
            .unwrap_or_else(|| vec![voice.name.clone()]);
        conflict = !linked.iter().any(|n| name_key(n) == name_key(&visual.name));
    }
    let winner = if conflict {
        None
    } else {
        allowed.iter().find(|c| c.tier == MatchTier::Automatic)
    };
    let shown: Vec<NameMatch> = allowed.iter().take(3).cloned().collect();
    if let (Some(existing), Some(winner)) = (assignment.name.as_ref(), winner)
        && name_key(existing) != name_key(&winner.name)
    {
        assignment.name = None;
        assignment.matched = None;
        assignment.supporting_matches = None;
        assignment.automatic_disabled = true;
        return shown;
    }
    if let Some(winner) = winner {
        assignment.name = Some(winner.name.clone());
        assignment.origin = if winner.source == MatchSource::Visual {
            Origin::VisualAutomatic
        } else {
            Origin::ProfileAutomatic
        };
        assignment.matched = Some(winner.clone());
        assignment.supporting_matches = Some(
            [visual, voice]
                .into_iter()
                .flatten()
                .cloned()
                .collect::<Vec<_>>(),
        );
        assignment.profile_id = winner.profile_id;
    } else if conflict
        || visual.is_some_and(|v| {
            name_key(&v.name) != name_key(assignment.name.as_deref().unwrap_or(""))
        })
    {
        assignment.name = None;
        assignment.matched = None;
        assignment.supporting_matches = None;
    }
    shown
}
