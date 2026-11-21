use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Local, NaiveDate, Utc};
use lokalbot_core::Transcript;
use unicode_normalization::UnicodeNormalization as _;
use unicode_normalization::char::is_combining_mark;

use super::model::{MeetingAction, Speakers};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Speaker {
    pub key: String,
    pub name: String,
    pub color: usize,
    pub is_user: bool,
    pub needs_name: bool,
}

pub fn speakers(transcript: Option<&Transcript>, names: &Speakers) -> Vec<Speaker> {
    let Some(transcript) = transcript else {
        return Vec::new();
    };
    let unnamed: HashSet<String> = unnamed_speaker_keys(transcript).into_iter().collect();
    let mut seen = HashSet::new();
    let ordered: Vec<Speaker> = transcript
        .segments
        .iter()
        .filter_map(|segment| {
            let key = Transcript::canonical_speaker_key(&segment.speaker);
            if !seen.insert(key.clone()) {
                return None;
            }
            Some(Speaker {
                name: names.name(&key),
                color: names.color_index(&key),
                is_user: names.is_user(&key),
                needs_name: unnamed.contains(&key),
                key,
            })
        })
        .collect();
    let (users, others): (Vec<_>, Vec<_>) = ordered.into_iter().partition(|s| s.is_user);
    users.into_iter().chain(others).collect()
}

pub fn unnamed_speaker_keys(transcript: &Transcript) -> Vec<String> {
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
    seen
}

pub fn date_text(at: DateTime<Utc>, today: NaiveDate) -> String {
    let local = at.with_timezone(&Local);
    let day = local.date_naive();
    let relative = if day == today {
        Some(lokalbot_i18n::tr("Today"))
    } else if Some(day) == today.pred_opt() {
        Some(lokalbot_i18n::tr("Yesterday"))
    } else {
        None
    };
    match relative {
        Some(day) => lokalbot_i18n::format(
            "{day} at {time}",
            &[
                ("day", day.to_string()),
                ("time", lokalbot_core::time::clock_time(at)),
            ],
        ),
        None => super::model::date_label(at),
    }
}

pub fn row_subtitle(time: &str, duration: &str, source: Option<&str>) -> String {
    lokalbot_i18n::directional(
        [Some(time), Some(duration), source]
            .into_iter()
            .flatten()
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" · "),
    )
}

pub fn speech_seconds(transcript: Option<&Transcript>) -> HashMap<String, f64> {
    let mut result = HashMap::new();
    for segment in transcript
        .map(|t| t.segments.as_slice())
        .unwrap_or_default()
    {
        if segment.start.is_finite()
            && segment.end.is_finite()
            && segment.end > segment.start
            && segment.start >= 0.
        {
            *result
                .entry(Transcript::canonical_speaker_key(&segment.speaker))
                .or_insert(0.) += segment.end - segment.start;
        }
    }
    result
}

pub fn speech_minutes(seconds: f64) -> u64 {
    ((seconds / 60.).round() as u64).max(1)
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ActionsPanel {
    pub for_you: Vec<usize>,
    pub for_others: Vec<usize>,
}

impl ActionsPanel {
    pub fn new(actions: &[MeetingAction]) -> Self {
        let (for_you, for_others) = (0..actions.len()).partition(|&ix| actions[ix].is_for_user);
        Self {
            for_you,
            for_others,
        }
    }

    pub fn total(&self) -> usize {
        self.for_you.len() + self.for_others.len()
    }

    pub fn count(&self) -> Option<usize> {
        (self.total() > 0).then_some(self.total())
    }

    pub fn shows_bands(&self) -> bool {
        self.total() > 0
    }

    pub fn order(&self) -> impl Iterator<Item = usize> + '_ {
        self.for_you.iter().chain(&self.for_others).copied()
    }

    pub fn shows_actions_link(&self, has_saved_outcomes: bool, is_sample: bool) -> bool {
        !self.for_you.is_empty() && has_saved_outcomes && !is_sample
    }
}

pub fn is_placeholder_speaker_name(name: &str) -> bool {
    let lower = name.trim().to_lowercase();
    let numbered = |prefix: &str| {
        lower == prefix
            || lower.strip_prefix(prefix).is_some_and(|rest| {
                rest.strip_prefix(' ')
                    .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
            })
    };
    numbered("them")
        || numbered("speaker")
        || lower == "speaker unclear"
        || lower == "local speaker"
}

pub fn owner_needs_attention(
    owner: Option<&str>,
    display_owner: Option<&str>,
    is_for_user: bool,
) -> bool {
    if is_for_user {
        return false;
    }
    let Some(owner) = owner.filter(|o| !owner_key(o).is_empty()) else {
        return true;
    };
    [owner, display_owner.unwrap_or("")].iter().any(|name| {
        let trimmed = name.trim();
        is_placeholder_speaker_name(trimmed)
            || ["other speaker", "unresolved speaker"].contains(&trimmed.to_lowercase().as_str())
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OwnerKind {
    You,
    Speaker,
    Invited,
    None,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OwnerOption {
    pub id: String,
    pub title: String,
    pub value: String,
    pub kind: OwnerKind,
    pub is_selected: bool,
}

impl OwnerOption {
    pub fn label(&self) -> String {
        match self.kind {
            OwnerKind::You | OwnerKind::None => lokalbot_i18n::tr(&self.title).to_string(),
            OwnerKind::Speaker | OwnerKind::Invited => self.title.clone(),
        }
    }
}

pub fn owner_options(
    owner: Option<&str>,
    is_for_user: bool,
    speakers: &[Speaker],
    stored_names: &HashMap<String, String>,
    invited: &[String],
) -> Vec<OwnerOption> {
    let current = owner.map(owner_key).unwrap_or_default();
    let mut options = vec![OwnerOption {
        id: "you".into(),
        title: "You".into(),
        value: "Me".into(),
        kind: OwnerKind::You,
        is_selected: is_for_user,
    }];
    let mut taken = HashSet::new();
    let mut any_selected = is_for_user;
    for speaker in speakers.iter().filter(|s| !s.is_user) {
        let stored = stored_names
            .get(&speaker.key)
            .cloned()
            .unwrap_or_else(|| speaker.name.clone());
        if !taken.insert(owner_key(&speaker.name)) {
            continue;
        }
        taken.insert(owner_key(&stored));
        let selected = !any_selected
            && !current.is_empty()
            && [owner_key(&speaker.name), owner_key(&stored)].contains(&current);
        any_selected |= selected;
        options.push(OwnerOption {
            id: format!("speaker:{}", speaker.key),
            title: speaker.name.clone(),
            value: stored,
            kind: OwnerKind::Speaker,
            is_selected: selected,
        });
    }
    for name in invited {
        let trimmed = name.trim();
        if trimmed.is_empty() || !taken.insert(owner_key(trimmed)) {
            continue;
        }
        let selected = !any_selected && current == owner_key(trimmed);
        any_selected |= selected;
        options.push(OwnerOption {
            id: format!("invited:{}", owner_key(trimmed)),
            title: trimmed.to_string(),
            value: trimmed.to_string(),
            kind: OwnerKind::Invited,
            is_selected: selected,
        });
    }
    options.push(OwnerOption {
        id: "none".into(),
        title: "No owner".into(),
        value: String::new(),
        kind: OwnerKind::None,
        is_selected: !any_selected && current.is_empty(),
    });
    options
}

pub fn owner_correction(option: &OwnerOption, action: &MeetingAction) -> Option<Option<String>> {
    let same = owner_key(&option.value) == owner_key(action.owner.as_deref().unwrap_or(""));
    if same && (option.kind != OwnerKind::You || action.is_for_user) {
        return None;
    }
    Some(Some(option.value.clone()).filter(|value| !value.trim().is_empty()))
}

pub fn stored_speaker_names(
    transcript: Option<&Transcript>,
    speakers: &[Speaker],
) -> HashMap<String, String> {
    let Some(transcript) = transcript else {
        return HashMap::new();
    };
    speakers
        .iter()
        .map(|s| (s.key.clone(), transcript.speaker_name(&s.key)))
        .collect()
}

pub fn owner_key(name: &str) -> String {
    name.trim()
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .collect()
}

#[derive(Clone, Debug, PartialEq)]
pub struct NamingVoice {
    pub key: String,
    pub label: String,
    pub color: usize,
    pub sample: Option<(f64, String)>,
    pub speech_seconds: f64,
    pub action_count: usize,
    pub recognized_name: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NamingKnown {
    pub key: String,
    pub name: String,
    pub color: usize,
    pub was_recognized: bool,
}

pub fn naming_lists(
    speakers: &[Speaker],
    review: &[super::model::ReviewSpeaker],
    speech: &HashMap<String, f64>,
    recognized: &HashMap<String, String>,
    recognized_before: &HashSet<String>,
) -> (Vec<NamingVoice>, Vec<NamingKnown>) {
    let by_key: HashMap<&str, &Speaker> = speakers.iter().map(|s| (s.key.as_str(), s)).collect();
    let voices = review
        .iter()
        .filter_map(|item| {
            let speaker = by_key.get(item.key.as_str())?;
            speaker.needs_name.then(|| NamingVoice {
                key: item.key.clone(),
                label: speaker.name.clone(),
                color: speaker.color,
                sample: item.sample.clone(),
                speech_seconds: speech.get(&item.key).copied().unwrap_or(0.),
                action_count: item.action_count,
                recognized_name: recognized.get(&item.key).cloned(),
            })
        })
        .collect();
    let known = speakers
        .iter()
        .filter(|s| !s.needs_name && !s.is_user)
        .map(|s| NamingKnown {
            key: s.key.clone(),
            name: s.name.clone(),
            color: s.color,
            was_recognized: recognized_before.contains(&s.key),
        })
        .collect();
    (voices, known)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NamingChoice {
    pub speaker: String,
    pub name: String,
    pub calendar_identity_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pick {
    pub id: String,
    pub name: String,
    pub calendar_identity_id: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct NamingDraft {
    picks: HashMap<String, Pick>,
    typing: HashSet<String>,
}

impl NamingDraft {
    pub fn new(
        voices: &[NamingVoice],
        suggestions: &[lokalbot_core::calendar::SpeakerSuggestion],
    ) -> Self {
        let mut draft = Self::default();
        for voice in voices {
            let Some(name) = &voice.recognized_name else {
                continue;
            };
            let pick = recognized_pick(name, &voice.key, suggestions);
            if !draft.picks.values().any(|p| p.id == pick.id) {
                draft.picks.insert(voice.key.clone(), pick);
            }
        }
        draft
    }

    pub fn is_picked(&self, id: &str, speaker: &str) -> bool {
        self.picks.get(speaker).is_some_and(|p| p.id == id)
    }

    pub fn is_typing(&self, speaker: &str) -> bool {
        self.typing.contains(speaker)
    }

    pub fn is_taken_elsewhere(&self, id: &str, speaker: &str) -> bool {
        self.picks
            .iter()
            .any(|(other, pick)| other != speaker && pick.id == id)
    }

    pub fn toggle(&mut self, pick: Pick, speaker: &str) {
        self.typing.remove(speaker);
        if self.picks.get(speaker).is_some_and(|p| p.id == pick.id) {
            self.picks.remove(speaker);
            return;
        }
        self.picks
            .retain(|other, existing| other == speaker || existing.id != pick.id);
        self.picks.insert(speaker.to_string(), pick);
    }

    pub fn type_name(&mut self, speaker: &str) {
        if !self.typing.remove(speaker) {
            self.typing.insert(speaker.to_string());
            self.picks.remove(speaker);
        }
    }

    pub fn choices<'a>(
        &self,
        speakers: impl IntoIterator<Item = &'a str>,
        typed: impl Fn(&str) -> String,
    ) -> Vec<NamingChoice> {
        speakers
            .into_iter()
            .filter_map(|speaker| {
                if self.typing.contains(speaker) {
                    let name = typed(speaker).trim().to_string();
                    return (!name.is_empty()).then(|| NamingChoice {
                        speaker: speaker.to_string(),
                        name,
                        calendar_identity_id: None,
                    });
                }
                let pick = self.picks.get(speaker)?;
                Some(NamingChoice {
                    speaker: speaker.to_string(),
                    name: pick.name.clone(),
                    calendar_identity_id: pick.calendar_identity_id.clone(),
                })
            })
            .collect()
    }
}

pub fn recognized_pick(
    name: &str,
    speaker: &str,
    suggestions: &[lokalbot_core::calendar::SpeakerSuggestion],
) -> Pick {
    use lokalbot_core::calendar::SpeakerSuggestion;
    let key = SpeakerSuggestion::name_key(name);
    if let Some(found) = suggestions
        .iter()
        .find(|s| s.name.as_deref().map(SpeakerSuggestion::name_key) == Some(key.clone()))
    {
        return Pick {
            id: found.id.clone(),
            name: found.name.clone().unwrap_or_else(|| name.to_string()),
            calendar_identity_id: found.calendar.as_ref().map(|guest| guest.id.clone()),
        };
    }
    Pick {
        id: format!("recognized:{speaker}"),
        name: name.to_string(),
        calendar_identity_id: None,
    }
}

pub mod layout {
    use gpui_kit::{Pixels, px};

    pub const GUTTER: Pixels = px(24.);
    pub const PANEL_GAP: Pixels = px(16.);
    pub const COLUMN_MAX: f32 = 1360.;
    pub const PROSE: f32 = 860.;
    pub const FIND_FIELD: f32 = 260.;
    pub const FIND_FIELD_MIN: f32 = 120.;
    pub const TIME_COLUMN: f32 = 52.;
    pub const COLUMN_GAP: f32 = 12.;
    pub const LINE_INSET: f32 = 6.;

    pub fn scaled(width: f32, text_scale: f32) -> Pixels {
        px((width * text_scale.max(0.5)).round())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FindPlacement {
    Hidden,
    TranscriptPanel,
    PinnedBar,
}

pub fn find_placement(tab: crate::state::MeetingTab, page_search_open: bool) -> FindPlacement {
    if page_search_open {
        FindPlacement::PinnedBar
    } else if tab == crate::state::MeetingTab::Transcript {
        FindPlacement::TranscriptPanel
    } else {
        FindPlacement::Hidden
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::ActionStatus;

    fn action(id: &str, owner: Option<&str>, for_user: bool) -> MeetingAction {
        MeetingAction {
            id: id.into(),
            text: format!("Action {id}"),
            original_text: format!("Action {id}"),
            owner: owner.map(str::to_string),
            owner_label: owner.map(str::to_string),
            due: None,
            due_label: None,
            resolved_due_date: None,
            status: ActionStatus::Open,
            citation: None,
            is_for_user: for_user,
        }
    }

    fn speaker(key: &str, name: &str, is_user: bool, needs_name: bool) -> Speaker {
        Speaker {
            key: key.into(),
            name: name.into(),
            color: 1,
            is_user,
            needs_name,
        }
    }

    #[test]
    fn actions_split_into_yours_and_others_keeping_their_order() {
        let actions = vec![
            action("a", Some("Ana"), false),
            action("b", Some("Me"), true),
            action("c", None, false),
            action("d", Some("Me"), true),
        ];
        let panel = ActionsPanel::new(&actions);
        assert_eq!(panel.for_you, vec![1, 3]);
        assert_eq!(panel.for_others, vec![0, 2]);
        assert_eq!(panel.order().collect::<Vec<_>>(), vec![1, 3, 0, 2]);
        assert_eq!(panel.count(), Some(4));
        assert!(panel.shows_bands());
    }

    #[test]
    fn a_meeting_without_actions_has_no_count_or_bands() {
        let panel = ActionsPanel::new(&[]);
        assert_eq!(panel.count(), None);
        assert!(!panel.shows_bands());
        assert!(!panel.shows_actions_link(true, false));
    }

    #[test]
    fn also_in_actions_needs_your_saved_action_in_a_real_meeting() {
        let mine = ActionsPanel::new(&[action("a", Some("Me"), true)]);
        assert!(mine.shows_actions_link(true, false));
        assert!(
            !mine.shows_actions_link(false, false),
            "notes still being written"
        );
        assert!(!mine.shows_actions_link(true, true), "the sample meeting");
        let theirs = ActionsPanel::new(&[action("a", Some("Ana"), false)]);
        assert!(!theirs.shows_actions_link(true, false));
    }

    #[test]
    fn placeholder_voices_are_not_names() {
        for name in [
            "Them",
            "them 2",
            "Speaker",
            "Speaker 3",
            "Speaker unclear",
            "Local speaker",
        ] {
            assert!(is_placeholder_speaker_name(name), "{name}");
        }
        for name in ["Ana", "Themba", "Speakers", "Speaker x", ""] {
            assert!(!is_placeholder_speaker_name(name), "{name}");
        }
    }

    #[test]
    fn an_owner_asks_for_attention_only_when_missing_or_a_voice() {
        assert!(owner_needs_attention(None, None, false));
        assert!(owner_needs_attention(Some("  "), None, false));
        assert!(owner_needs_attention(
            Some("Them 2"),
            Some("Speaker 2"),
            false
        ));
        assert!(owner_needs_attention(
            Some("Unresolved speaker"),
            None,
            false
        ));
        assert!(!owner_needs_attention(
            Some("Ana Petrović"),
            Some("Ana Petrović"),
            false
        ));
        assert!(!owner_needs_attention(None, None, true));
    }

    #[test]
    fn owner_menu_offers_you_speakers_new_guests_and_no_owner() {
        let speakers = vec![
            speaker("me", "You", true, false),
            speaker("them", "Other speaker", false, true),
            speaker("them 2", "Ana Petrović", false, false),
        ];
        let stored = HashMap::from([
            ("them".to_string(), "Them".to_string()),
            ("them 2".to_string(), "Ana Petrović".to_string()),
        ]);
        let invited = vec!["ana petrovic".to_string(), "Marko Marković".to_string()];
        let options = owner_options(Some("Them"), false, &speakers, &stored, &invited);
        let ids: Vec<_> = options.iter().map(|o| o.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "you",
                "speaker:them",
                "speaker:them 2",
                "invited:marko markovic",
                "none"
            ]
        );
        assert_eq!(options[1].value, "Them");
        assert!(options[1].is_selected);
        assert_eq!(options.iter().filter(|o| o.is_selected).count(), 1);
        assert_eq!(options.last().unwrap().value, "");
    }

    #[test]
    fn owner_menu_marks_you_or_no_owner_when_nobody_else_matches() {
        let mine = owner_options(Some("Me"), true, &[], &HashMap::new(), &[]);
        assert!(mine[0].is_selected);
        assert!(!mine.last().unwrap().is_selected);
        let nobody = owner_options(None, false, &[], &HashMap::new(), &[]);
        assert!(!nobody[0].is_selected);
        assert!(nobody.last().unwrap().is_selected);
    }

    #[test]
    fn choosing_the_current_owner_saves_nothing_and_no_owner_clears() {
        let theirs = action("a", Some("Ana"), false);
        let ana = OwnerOption {
            id: "speaker:them".into(),
            title: "Ana".into(),
            value: "ANA ".into(),
            kind: OwnerKind::Speaker,
            is_selected: true,
        };
        assert_eq!(owner_correction(&ana, &theirs), None);
        let none = OwnerOption {
            id: "none".into(),
            title: "No owner".into(),
            value: String::new(),
            kind: OwnerKind::None,
            is_selected: false,
        };
        assert_eq!(owner_correction(&none, &theirs), Some(None));
        let you = OwnerOption {
            id: "you".into(),
            title: "You".into(),
            value: "Me".into(),
            kind: OwnerKind::You,
            is_selected: false,
        };
        assert_eq!(
            owner_correction(&you, &action("b", Some("Me"), false)),
            Some(Some("Me".into()))
        );
        assert_eq!(owner_correction(&you, &action("b", Some("Me"), true)), None);
    }

    #[test]
    fn owner_names_compare_without_case_or_accents() {
        assert_eq!(owner_key("  Ana Petrović "), owner_key("ana petrovic"));
        assert_ne!(owner_key("Ana"), owner_key("Anna"));
    }

    #[test]
    fn row_subtitles_read_when_how_long_then_where() {
        assert_eq!(
            row_subtitle("1:00 PM", "50 min", Some("Zoom")),
            "1:00 PM · 50 min · Zoom"
        );
        assert_eq!(row_subtitle("1:00 PM", "50 min", None), "1:00 PM · 50 min");
        assert_eq!(row_subtitle("1:00 PM", "", Some("")), "1:00 PM");
    }

    #[test]
    fn the_date_line_says_today_and_yesterday_then_the_date() {
        use chrono::TimeZone as _;
        let at = Local.with_ymd_and_hms(2026, 11, 14, 11, 0, 0).unwrap();
        let utc = at.with_timezone(&Utc);
        let today = at.date_naive();
        let clock = lokalbot_core::time::clock_time(utc);
        assert_eq!(date_text(utc, today), format!("Today at {clock}"));
        assert_eq!(
            date_text(utc, today.succ_opt().unwrap()),
            format!("Yesterday at {clock}")
        );
        let later = today.checked_add_days(chrono::Days::new(5)).unwrap();
        assert_eq!(date_text(utc, later), super::super::model::date_label(utc));
    }

    #[test]
    fn any_speech_reads_as_at_least_a_minute() {
        assert_eq!(speech_minutes(5.), 1);
        assert_eq!(speech_minutes(89.), 1);
        assert_eq!(speech_minutes(91.), 2);
        assert_eq!(speech_minutes(720.), 12);
    }

    #[test]
    fn the_find_field_sits_in_the_transcript_panel_until_ctrl_f() {
        use crate::state::MeetingTab;
        assert_eq!(
            find_placement(MeetingTab::Summary, false),
            FindPlacement::Hidden
        );
        assert_eq!(
            find_placement(MeetingTab::Transcript, false),
            FindPlacement::TranscriptPanel
        );
        assert_eq!(
            find_placement(MeetingTab::Notes, true),
            FindPlacement::PinnedBar
        );
        assert_eq!(
            find_placement(MeetingTab::Transcript, true),
            FindPlacement::PinnedBar
        );
    }

    fn voice(key: &str, recognized: Option<&str>) -> NamingVoice {
        NamingVoice {
            key: key.into(),
            label: key.into(),
            color: 1,
            sample: None,
            speech_seconds: 60.,
            action_count: 0,
            recognized_name: recognized.map(str::to_string),
        }
    }

    fn pick(id: &str, name: &str) -> Pick {
        Pick {
            id: id.into(),
            name: name.into(),
            calendar_identity_id: None,
        }
    }

    #[test]
    fn one_person_names_one_voice_in_the_sheet() {
        let mut draft = NamingDraft::default();
        draft.toggle(pick("calendar:1", "Ana"), "them");
        assert!(draft.is_picked("calendar:1", "them"));
        draft.toggle(pick("calendar:1", "Ana"), "them 2");
        assert!(
            !draft.is_picked("calendar:1", "them"),
            "taken from the first voice"
        );
        assert!(draft.is_picked("calendar:1", "them 2"));
        assert!(draft.is_taken_elsewhere("calendar:1", "them"));
        draft.toggle(pick("calendar:1", "Ana"), "them 2");
        assert!(
            draft
                .choices(["them", "them 2"], |_| String::new())
                .is_empty()
        );
    }

    #[test]
    fn typed_names_replace_picks_and_blank_ones_are_skipped() {
        let mut draft = NamingDraft::default();
        draft.toggle(pick("calendar:1", "Ana"), "them");
        draft.type_name("them");
        assert!(draft.is_typing("them"));
        assert!(!draft.is_picked("calendar:1", "them"));
        draft.type_name("them 2");
        let typed = |speaker: &str| {
            if speaker == "them" {
                "  Marko ".to_string()
            } else {
                "   ".to_string()
            }
        };
        assert_eq!(
            draft.choices(["them", "them 2"], typed),
            vec![NamingChoice {
                speaker: "them".into(),
                name: "Marko".into(),
                calendar_identity_id: None,
            }]
        );
    }

    #[test]
    fn recognized_voices_start_picked_but_never_twice() {
        let voices = vec![voice("them", Some("Ana")), voice("them 2", Some("ana"))];
        let draft = NamingDraft::new(&voices, &[]);
        let choices = draft.choices(["them", "them 2"], |_| String::new());
        assert_eq!(choices.len(), 2, "different picks: each voice its own chip");
        let guests = vec![lokalbot_core::calendar::SpeakerSuggestion {
            id: "calendar:g1".into(),
            name: Some("Ana".into()),
            calendar: None,
        }];
        let draft = NamingDraft::new(&voices, &guests);
        let choices = draft.choices(["them", "them 2"], |_| String::new());
        assert_eq!(choices.len(), 1, "one guest starts on one voice only");
        assert_eq!(choices[0].speaker, "them");
    }

    #[test]
    fn the_sheet_lists_unnamed_voices_in_review_order_and_named_ones_apart() {
        let speakers = vec![
            speaker("me", "You", true, false),
            speaker("them", "Other speaker", false, true),
            speaker("them 2", "Speaker 2", false, true),
            speaker("them 3", "Ana", false, false),
        ];
        let review = vec![
            super::super::model::ReviewSpeaker {
                key: "them 2".into(),
                name: "Speaker 2".into(),
                is_user: false,
                is_named: false,
                sample: Some((4., "Hello there all".into())),
                action_count: 2,
            },
            super::super::model::ReviewSpeaker {
                key: "them".into(),
                name: "Other speaker".into(),
                is_user: false,
                is_named: false,
                sample: None,
                action_count: 0,
            },
        ];
        let speech = HashMap::from([("them 2".to_string(), 125.)]);
        let recognized = HashMap::from([("them".to_string(), "Marko".to_string())]);
        let before = HashSet::from(["them 3".to_string()]);
        let (voices, known) = naming_lists(&speakers, &review, &speech, &recognized, &before);
        assert_eq!(
            voices.iter().map(|v| v.key.as_str()).collect::<Vec<_>>(),
            ["them 2", "them"]
        );
        assert_eq!(voices[0].speech_seconds, 125.);
        assert_eq!(voices[1].recognized_name.as_deref(), Some("Marko"));
        assert_eq!(known.len(), 1);
        assert!(known[0].was_recognized);
    }
}
