//! Matching for Find on a meeting page (`MeetingPageSearch.swift`): one source
//! per visible text node, in reading order. Matching ignores case, diacritics
//! and character width. Keeping the location beside the exact text makes
//! matching and scrolling agree.

use unicode_normalization::UnicodeNormalization as _;
use unicode_normalization::char::is_combining_mark;

/// The tab a location lives on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Section {
    MeetingDetails,
    MeetingStatus,
    ActionItems,
    Decisions,
    Notes,
    Summary,
    Transcript,
}

impl Section {
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::MeetingDetails => "Meeting details",
            Self::MeetingStatus => "Meeting status",
            Self::ActionItems => "Action items",
            Self::Decisions => "Decisions",
            Self::Notes => "Notes",
            Self::Summary => "Summary",
            Self::Transcript => "Transcript",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MetadataField {
    Date,
    Duration,
    App,
    AudioSource,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ActionField {
    Text,
    Owner,
    Due,
    Evidence,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DecisionField {
    Text,
    Evidence,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Location {
    Title,
    Metadata(MetadataField),
    Status,
    EmptyState(Section),
    /// An action's field, by its index among the actions the page shows.
    Action(usize, ActionField),
    Decision(usize, DecisionField),
    Notes,
    SummaryMeta,
    Summary,
    TranscriptEngine,
    /// A transcript row's text, by index.
    Row(usize),
    RowTime(usize),
    RowSpeaker(usize),
}

impl Location {
    pub(crate) fn section(&self) -> Section {
        match self {
            Self::Title | Self::Metadata(_) => Section::MeetingDetails,
            Self::Status => Section::MeetingStatus,
            Self::EmptyState(section) => *section,
            Self::Action(..) => Section::ActionItems,
            Self::Decision(..) => Section::Decisions,
            Self::Notes => Section::Notes,
            Self::SummaryMeta | Self::Summary => Section::Summary,
            Self::TranscriptEngine | Self::Row(_) | Self::RowTime(_) | Self::RowSpeaker(_) => {
                Section::Transcript
            }
        }
    }

    /// `MeetingWorkspaceTab.containing`.
    pub(crate) fn tab(&self) -> crate::state::MeetingTab {
        use crate::state::MeetingTab;
        match self.section() {
            Section::Notes => MeetingTab::Notes,
            Section::Transcript => MeetingTab::Transcript,
            _ => MeetingTab::Summary,
        }
    }

    /// Lives in the Summary tab's collapsed full notes.
    pub(crate) fn needs_full_notes(&self) -> bool {
        self.section() == Section::Summary
    }

    /// The row a transcript location scrolls to.
    pub(crate) fn transcript_row(&self) -> Option<usize> {
        match self {
            Self::Row(row) | Self::RowTime(row) | Self::RowSpeaker(row) => Some(*row),
            _ => None,
        }
    }

    /// Lives in the scrolling overview, not the fixed header or another view.
    pub(crate) fn scrolls_overview(&self) -> bool {
        !matches!(self, Self::Title | Self::Metadata(_) | Self::Notes)
            && self.tab() == crate::state::MeetingTab::Summary
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Source {
    pub location: Location,
    pub text: String,
}

/// One occurrence: where, and which bytes of that source's text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PageMatch {
    pub location: Location,
    pub range: std::ops::Range<usize>,
}

/// Fullwidth forms as their ASCII, the part of width folding meetings show.
fn narrow(c: char) -> char {
    match c {
        '\u{FF01}'..='\u{FF5E}' => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
        '\u{3000}' => ' ',
        _ => c,
    }
}

/// The folded text, and the byte offset in `text` each folded char came from.
fn folded(text: &str) -> (Vec<char>, Vec<(usize, usize)>) {
    let mut chars = Vec::with_capacity(text.len());
    let mut spans = Vec::with_capacity(text.len());
    for (start, c) in text.char_indices() {
        let end = start + c.len_utf8();
        for piece in narrow(c)
            .nfd()
            .filter(|p| !is_combining_mark(*p))
            .flat_map(char::to_lowercase)
        {
            chars.push(piece);
            spans.push((start, end));
        }
    }
    (chars, spans)
}

/// Every non-overlapping occurrence of `query` in `text`, as byte ranges.
pub(crate) fn ranges(text: &str, query: &str) -> Vec<std::ops::Range<usize>> {
    let needle: Vec<char> = folded(query.trim()).0;
    if needle.is_empty() || text.is_empty() {
        return Vec::new();
    }
    let (chars, spans) = folded(text);
    let mut out = Vec::new();
    let mut at = 0;
    while at + needle.len() <= chars.len() {
        if chars[at..at + needle.len()] == needle[..] {
            out.push(spans[at].0..spans[at + needle.len() - 1].1);
            at += needle.len();
        } else {
            at += 1;
        }
    }
    out
}

/// `searchSources`: every visible text node in reading order. The field in
/// the Transcript panel searches only that tab; Ctrl+F searches the page.
/// `notes` is the editor's text, which can be newer than `doc`. Panel titles
/// are not searched: a panel's header can't mark its words.
pub(crate) fn sources(
    doc: &super::model::MeetingDoc,
    stage: Option<String>,
    processing: bool,
    notes: &str,
    whole_page: bool,
) -> Vec<Source> {
    use lokalbot_i18n::tr;
    let short = crate::ui::action_row::short_stamp;
    let mut out = Vec::new();
    let mut push = |text: String, location: Location| {
        if !text.is_empty() {
            out.push(Source { location, text });
        }
    };
    if whole_page {
        let meeting = &doc.meeting;
        push(meeting.display_title(), Location::Title);
        push(
            super::presentation::date_text(meeting.started_at, chrono::Local::now().date_naive()),
            Location::Metadata(MetadataField::Date),
        );
        push(
            super::model::duration_label(meeting),
            Location::Metadata(MetadataField::Duration),
        );
        if let Some(app) = app_chip(meeting) {
            push(app, Location::Metadata(MetadataField::App));
        }
        if let Some(audio) = audio_chip(meeting) {
            push(
                audio.to_string(),
                Location::Metadata(MetadataField::AudioSource),
            );
        }
        if let Some(stage) = stage {
            push(stage, Location::Status);
        }
        if doc.has_summary_content() {
            for (index, decision) in doc.shown_decisions().iter().enumerate() {
                push(
                    doc.speakers_text(&decision.text).to_string(),
                    Location::Decision(index, DecisionField::Text),
                );
                if let Some(citation) = decision.citations.first() {
                    push(
                        short(citation.start),
                        Location::Decision(index, DecisionField::Evidence),
                    );
                }
            }
            let actions = doc.shown_actions();
            let panel = super::presentation::ActionsPanel::new(actions);
            if !panel.shows_bands() {
                push(
                    tr("No action items were extracted from this meeting.").to_string(),
                    Location::EmptyState(Section::ActionItems),
                );
            }
            for index in panel.order() {
                let action = &actions[index];
                push(
                    action.text.clone(),
                    Location::Action(index, ActionField::Text),
                );
                if !action.is_for_user {
                    push(
                        super::detail::owner_text(action),
                        Location::Action(index, ActionField::Owner),
                    );
                }
                if let Some(due) = &action.due {
                    push(
                        action.due_label.clone().unwrap_or_else(|| due.clone()),
                        Location::Action(index, ActionField::Due),
                    );
                }
                if let Some(citation) = &action.citation {
                    push(
                        short(citation.start),
                        Location::Action(index, ActionField::Evidence),
                    );
                }
            }
        } else if !processing {
            push(
                tr("No summary yet.").to_string(),
                Location::EmptyState(Section::Summary),
            );
        }
        if !notes.is_empty() {
            push(notes.to_string(), Location::Notes);
        }
        if doc.has_summary() {
            push(
                doc.summary_meta.clone().unwrap_or_default(),
                Location::SummaryMeta,
            );
            push(doc.summary_body.clone(), Location::Summary);
        }
    }
    if doc.rows.is_empty() {
        push(
            tr("No transcript yet.").to_string(),
            Location::EmptyState(Section::Transcript),
        );
    } else if let Some(line) = engine_line(doc) {
        push(line, Location::TranscriptEngine);
    }
    for (index, row) in doc.rows.iter().enumerate() {
        // A speaker's name is shown once, where the turn begins.
        if row.begins_turn {
            push(row.name.to_string(), Location::RowSpeaker(index));
        }
        push(short(row.start), Location::RowTime(index));
        push(row.text.to_string(), Location::Row(index));
    }
    out
}

/// The app chip beside the date, where one shows.
pub(crate) fn app_chip(meeting: &lokalbot_core::Meeting) -> Option<String> {
    if meeting.is_sample() {
        Some(lokalbot_i18n::tr("Sample meeting").to_string())
    } else if meeting.is_merged_meeting() {
        None
    } else {
        Some(meeting.app_name.clone())
    }
}

/// "Mic only", the date line's one capture limitation. An imported file's
/// audio came from neither this PC's microphone nor its system audio, so it
/// carries none.
pub(crate) fn audio_chip(meeting: &lokalbot_core::Meeting) -> Option<&'static str> {
    (!meeting.is_imported() && !meeting.has_system_track).then(|| lokalbot_i18n::tr("Mic only"))
}

/// "Transcribed with …", where the transcript shows it.
pub(crate) fn engine_line(doc: &super::model::MeetingDoc) -> Option<String> {
    let engine = doc.transcript.as_ref()?.engine.as_str();
    (!engine.is_empty() && engine != "merged").then(|| {
        lokalbot_i18n::format(
            "Transcribed with {engine}",
            &[("engine", engine.to_string())],
        )
    })
}

pub(crate) fn matches(query: &str, sources: &[Source]) -> Vec<PageMatch> {
    sources
        .iter()
        .flat_map(|source| {
            ranges(&source.text, query)
                .into_iter()
                .map(|range| PageMatch {
                    location: source.location.clone(),
                    range,
                })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matching_ignores_case_diacritics_and_width() {
        assert_eq!(ranges("Ana Petrović spoke", "petrovic"), vec![4..13]);
        assert_eq!(ranges("MEETING", "meeting"), vec![0..7]);
        assert_eq!(ranges("ＡＢＣ", "abc"), vec![0..9]);
        assert_eq!(ranges("cafe\u{301} and café", "café").len(), 2);
    }

    #[test]
    fn occurrences_do_not_overlap_and_blank_finds_nothing() {
        assert_eq!(ranges("aaaa", "aa"), vec![0..2, 2..4]);
        assert!(ranges("text", "   ").is_empty());
        assert!(ranges("", "x").is_empty());
    }

    #[test]
    fn ranges_cut_on_character_boundaries_when_lengths_change() {
        // "İ" lowercases to two chars and changes byte length.
        let text = "İstanbul plan";
        let found = ranges(text, "plan");
        assert_eq!(&text[found[0].clone()], "plan");
    }

    #[test]
    fn matches_stay_in_reading_order_with_their_section() {
        let sources = vec![
            Source {
                location: Location::Title,
                text: "Launch plan".into(),
            },
            Source {
                location: Location::Action(0, ActionField::Text),
                text: "Plan the launch".into(),
            },
            Source {
                location: Location::Row(3),
                text: "the launch plan moved".into(),
            },
        ];
        let found = matches("plan", &sources);
        assert_eq!(found.len(), 3);
        assert_eq!(found[0].location.section(), Section::MeetingDetails);
        assert_eq!(found[1].location.section(), Section::ActionItems);
        assert_eq!(found[2].location.section(), Section::Transcript);
    }

    #[test]
    fn fields_of_one_action_keep_their_own_ranges() {
        // An owner's match must not mark the same bytes of the action's text.
        let sources = vec![
            Source {
                location: Location::Action(0, ActionField::Text),
                text: "Send the plan".into(),
            },
            Source {
                location: Location::Action(0, ActionField::Owner),
                text: "Send Ana".into(),
            },
        ];
        let found = matches("send", &sources);
        assert_eq!(found.len(), 2);
        assert_ne!(found[0].location, found[1].location);
    }

    #[test]
    fn each_location_opens_the_tab_that_shows_it() {
        use crate::state::MeetingTab;
        assert_eq!(Location::Notes.tab(), MeetingTab::Notes);
        assert_eq!(Location::Summary.tab(), MeetingTab::Summary);
        assert_eq!(Location::Title.tab(), MeetingTab::Summary);
        assert_eq!(
            Location::Action(0, ActionField::Due).tab(),
            MeetingTab::Summary
        );
        assert_eq!(Location::RowTime(2).tab(), MeetingTab::Transcript);
        assert_eq!(
            Location::EmptyState(Section::Transcript).tab(),
            MeetingTab::Transcript
        );
        assert!(Location::SummaryMeta.needs_full_notes());
        assert!(Location::EmptyState(Section::Summary).needs_full_notes());
        assert!(!Location::Decision(0, DecisionField::Text).needs_full_notes());
        assert_eq!(Location::RowSpeaker(4).transcript_row(), Some(4));
        assert!(!Location::Title.scrolls_overview());
        assert!(!Location::Notes.scrolls_overview());
        assert!(!Location::Row(0).scrolls_overview());
        assert!(Location::Status.scrolls_overview());
        assert!(Location::Summary.scrolls_overview());
    }
}
