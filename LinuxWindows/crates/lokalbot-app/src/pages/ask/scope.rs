//! What a question may draw on: sources and a date scope (`AskSourceScope`,
//! `AskDateScope`). Files and Agent notes are part of "All sources" whether or
//! not they are on, so turning one on or off never makes an earlier question
//! look narrowed; each is offered only while it is on.

use chrono::{DateTime, Datelike as _, Days, Local, NaiveDate, Utc};
use lokalbot_core::{AskDateScope, AskSourceScope, ChatMessage, ChatRole, QuestionScope};
use uuid::Uuid;

use crate::state::AskScope;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Sources {
    pub meetings: bool,
    pub activity: bool,
    pub screen: bool,
    pub files: bool,
    /// Notes the person's coding agents saved for themselves.
    pub agent_notes: bool,
}

impl Default for Sources {
    fn default() -> Self {
        Self {
            meetings: true,
            activity: true,
            screen: true,
            files: true,
            agent_notes: true,
        }
    }
}

/// The optional sources that are on now, and so can be chosen and searched.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Offered {
    pub files: bool,
    pub agent_notes: bool,
}

impl Offered {
    pub fn new(settings: &lokalbot_core::Settings) -> Self {
        Self {
            files: settings.file_search_enabled,
            agent_notes: settings.coding_agent_notes_enabled,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Meetings,
    Activity,
    Screen,
    Files,
    AgentNotes,
}

impl Source {
    pub const ALL: [Source; 5] = [
        Source::Meetings,
        Source::Activity,
        Source::Screen,
        Source::Files,
        Source::AgentNotes,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Source::Meetings => lokalbot_i18n::tr("Meetings"),
            Source::Activity => lokalbot_i18n::tr("Activity"),
            Source::Screen => lokalbot_i18n::tr("Screen"),
            Source::Files => lokalbot_i18n::tr("Files"),
            Source::AgentNotes => lokalbot_i18n::tr("Agent notes"),
        }
    }

    /// The sources a person can choose now: Files and Agent notes only while
    /// each is on.
    pub fn available(offered: Offered) -> impl Iterator<Item = Source> {
        Self::ALL.into_iter().filter(move |source| match source {
            Source::Files => offered.files,
            Source::AgentNotes => offered.agent_notes,
            _ => true,
        })
    }
}

impl Sources {
    pub fn contains(&self, source: Source) -> bool {
        match source {
            Source::Meetings => self.meetings,
            Source::Activity => self.activity,
            Source::Screen => self.screen,
            Source::Files => self.files,
            Source::AgentNotes => self.agent_notes,
        }
    }

    fn set(&mut self, source: Source, on: bool) {
        match source {
            Source::Meetings => self.meetings = on,
            Source::Activity => self.activity = on,
            Source::Screen => self.screen = on,
            Source::Files => self.files = on,
            Source::AgentNotes => self.agent_notes = on,
        }
    }

    pub fn count(&self, offered: Offered) -> usize {
        Source::available(offered)
            .filter(|s| self.contains(*s))
            .count()
    }

    /// Toggles a source, keeping at least one selected.
    pub fn toggle(&mut self, source: Source, offered: Offered) {
        if self.contains(source) && self.count(offered) == 1 {
            return;
        }
        self.set(source, !self.contains(source));
    }

    /// The sources a saved question named, or all of them on a legacy turn.
    pub fn from_saved(saved: &[AskSourceScope]) -> Self {
        if saved.is_empty() {
            return Self::default();
        }
        Self {
            meetings: saved.contains(&AskSourceScope::Meetings),
            activity: saved.contains(&AskSourceScope::Today),
            screen: saved.contains(&AskSourceScope::Screen),
            files: saved.contains(&AskSourceScope::Files),
            agent_notes: saved.contains(&AskSourceScope::AgentNotes),
        }
    }

    /// "All sources" or "Screen".
    pub fn summary(&self, offered: Offered) -> String {
        if Source::available(offered).all(|s| self.contains(s)) {
            return lokalbot_i18n::tr("All sources").into();
        }
        Source::available(offered)
            .filter(|s| self.contains(*s))
            .map(|s| lokalbot_i18n::tr(s.label()))
            .collect::<Vec<_>>()
            .join(", ")
    }
}

/// The calendar range a question or search is limited to.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DateScope {
    #[default]
    AnyTime,
    Today,
    Yesterday,
    LastSevenDays,
    Day(NaiveDate),
    /// Both ends included: a saved question's range, which keeps its days
    /// whenever it is reopened.
    Range(NaiveDate, NaiveDate),
}

impl DateScope {
    pub fn label(self) -> String {
        match self {
            DateScope::AnyTime => lokalbot_i18n::tr("Any time").into(),
            DateScope::Today => lokalbot_i18n::tr("Today").into(),
            DateScope::Yesterday => lokalbot_i18n::tr("Yesterday").into(),
            DateScope::LastSevenDays => lokalbot_i18n::tr("Last 7 days").into(),
            DateScope::Day(day) => {
                let today = Local::now().date_naive();
                if day == today {
                    lokalbot_i18n::tr("Today").into()
                } else if Some(day) == today.pred_opt() {
                    lokalbot_i18n::tr("Yesterday").into()
                } else if day.year() == today.year() {
                    day.format_localized(
                        lokalbot_i18n::date_pattern("%b %-d"),
                        lokalbot_i18n::date_locale(),
                    )
                    .to_string()
                } else {
                    day.format_localized(
                        lokalbot_i18n::date_pattern("%b %-d, %Y"),
                        lokalbot_i18n::date_locale(),
                    )
                    .to_string()
                }
            }
            DateScope::Range(first, last) => {
                let today = Local::now().date_naive();
                if last == today && today.checked_sub_days(Days::new(6)) == Some(first) {
                    return lokalbot_i18n::tr("Last 7 days").into();
                }
                let format = |day: NaiveDate| {
                    day.format_localized(
                        lokalbot_i18n::date_pattern("%b %-d, %Y"),
                        lokalbot_i18n::date_locale(),
                    )
                    .to_string()
                };
                format!("{} – {}", format(first), format(last))
            }
        }
    }

    /// The civil days this is, as a question saves them.
    fn days(self) -> Option<(NaiveDate, NaiveDate)> {
        let today = Local::now().date_naive();
        Some(match self {
            DateScope::AnyTime => return None,
            DateScope::Today => (today, today),
            DateScope::Yesterday => {
                let day = today.pred_opt()?;
                (day, day)
            }
            DateScope::LastSevenDays => (today.checked_sub_days(Days::new(6))?, today),
            DateScope::Day(day) => (day, day),
            DateScope::Range(first, last) => (first, last),
        })
    }

    /// `[since, until)` in UTC; `None` for any time.
    pub fn bounds(self) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
        let (first, last) = self.days()?;
        let (since, _) = lokalbot_core::time::local_day_bounds(first);
        let (_, until) = lokalbot_core::time::local_day_bounds(last);
        Some((since, until))
    }

    /// `AskDateScope.storageKey`: "Today" is saved as the day it was.
    pub fn storage_key(self) -> Option<String> {
        let (first_day, last_day) = self.days()?;
        Some(
            AskDateScope {
                first_day,
                last_day,
            }
            .storage_key(),
        )
    }

    /// The days a saved question was limited to. A key that doesn't parse names
    /// no days, as on the Mac; such a turn was already marked ambiguous.
    pub fn from_storage_key(key: &str) -> Self {
        match AskDateScope::from_storage_key(key) {
            Some(range) if range.first_day == range.last_day => DateScope::Day(range.first_day),
            Some(range) => DateScope::Range(range.first_day, range.last_day),
            None => DateScope::AnyTime,
        }
    }
}

/// What a question is bound to, beyond its sources (`RecallWorkspaceState`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Evidence {
    /// Evidence boundary from "Ask This Meeting" or from asking about results.
    pub meetings: Option<Vec<Uuid>>,
    /// The screen moments among those results.
    pub screens: Option<Vec<i64>>,
    /// Asked about results: Activity has no result rows to bound, so a selected
    /// Activity source stays, or "How long was I in Figma today?" would lose the
    /// only tool that answers it. Files stays when file rows were among them,
    /// and Agent notes when note rows were.
    pub from_results: bool,
    pub had_file_results: bool,
    pub had_note_results: bool,
    /// Screens the person attached to this question.
    pub pins: Vec<i64>,
    /// The civil days of those screens, sorted, each once.
    pub pin_days: Vec<String>,
    pub screen_app: Option<String>,
}

/// What Ask goes back to when a saved question is reopened
/// (`currentQuestionScope`, `restoreAskScope`).
#[derive(Clone, Debug, PartialEq)]
pub struct Restored {
    pub sources: Sources,
    pub date: DateScope,
    pub evidence: Evidence,
}

/// A saved scope as Ask's selection. The sources it names stay as they are:
/// nothing that scope excluded comes back, and evidence stays bound.
pub fn restore(saved: &QuestionScope) -> Restored {
    let sources = Sources::from_saved(&saved.sources);
    Restored {
        sources,
        date: saved
            .day_scope_key
            .as_deref()
            .map_or(DateScope::AnyTime, DateScope::from_storage_key),
        evidence: Evidence {
            meetings: saved.meeting_ids.clone(),
            screens: saved.screen_snapshot_ids.clone(),
            from_results: true,
            had_file_results: sources.files,
            had_note_results: sources.agent_notes,
            pins: Vec::new(),
            pin_days: Vec::new(),
            screen_app: saved.screen_app.clone(),
        },
    }
}

/// The request for a question asked within a saved scope: a retry, or a follow-up
/// in Quick Recall.
pub fn scope_for(saved: &QuestionScope) -> AskScope {
    let restored = restore(saved);
    ask_scope(restored.sources, restored.date, &restored.evidence)
}

/// `AskDayScope.key` of a moment, for the days of attached screens.
pub fn pin_days(moments: &[lokalbot_core::ScreenMoment]) -> Vec<String> {
    let days: std::collections::BTreeSet<String> = moments
        .iter()
        .map(|moment| lokalbot_core::day_key(moment.ts.with_timezone(&Local).date_naive()))
        .collect();
    days.into_iter().collect()
}

/// `questionScopeSummary`: "Meetings, Screen · Oct 1 · attached screen: Oct 1".
/// While agent notes aren't offered, a question that names every other source
/// reads as "All sources": that is how questions from before that source
/// existed were saved.
pub fn question_scope_summary(message: &ChatMessage, offered: Offered) -> Option<String> {
    if message.role != ChatRole::User
        || (message.source_scopes.is_empty() && message.day_scope_key.is_none())
    {
        return None;
    }
    let mut selected: std::collections::BTreeSet<_> =
        message.source_scopes.iter().copied().collect();
    if !offered.agent_notes {
        let mut with_notes = selected.clone();
        with_notes.insert(AskSourceScope::AgentNotes);
        if with_notes == AskSourceScope::defaults() {
            selected = with_notes;
        }
    }
    let sources = if selected == AskSourceScope::defaults() {
        lokalbot_i18n::tr("All sources").to_string()
    } else {
        AskSourceScope::ALL
            .into_iter()
            .filter(|source| selected.contains(source))
            .map(|source| match source {
                AskSourceScope::Meetings => Source::Meetings.label(),
                AskSourceScope::Today => Source::Activity.label(),
                AskSourceScope::Screen => Source::Screen.label(),
                AskSourceScope::Files => Source::Files.label(),
                AskSourceScope::AgentNotes => Source::AgentNotes.label(),
            })
            .collect::<Vec<_>>()
            .join(", ")
    };
    let mut parts = vec![sources];
    if let Some(key) = &message.day_scope_key {
        parts.push(DateScope::from_storage_key(key).label());
    }
    if !message.attached_screen_day_keys.is_empty() {
        let days: Vec<String> = message
            .attached_screen_day_keys
            .iter()
            .map(|key| match DateScope::from_storage_key(key) {
                DateScope::AnyTime => key.clone(),
                day => day.label(),
            })
            .collect();
        parts.push(lokalbot_i18n::format(
            "attached screen: {0}",
            &[("0", days.join(", "))],
        ));
    }
    Some(parts.join(" · "))
}

/// The sources a session's moments leave (`selectEvidence`): its screens, or the
/// day's meetings when it has none.
pub fn session_sources(screen_ids: &[i64]) -> Sources {
    Sources {
        meetings: screen_ids.is_empty(),
        activity: false,
        screen: !screen_ids.is_empty(),
        files: false,
        agent_notes: false,
    }
}

/// `selectEvidence` with no sources named: whichever of them the evidence holds,
/// when the meetings are bound too. Only screens is a session.
pub fn evidence_sources(meetings: Option<&[Uuid]>, screen_ids: &[i64]) -> Sources {
    match meetings {
        Some(meetings) if !meetings.is_empty() => Sources {
            meetings: true,
            activity: false,
            screen: !screen_ids.is_empty(),
            files: false,
            agent_notes: false,
        },
        _ => session_sources(screen_ids),
    }
}

/// The request sent to the engine for one question. Attached screens grant the
/// screen source for that question, and never widen its dates.
pub fn ask_scope(sources: Sources, date: DateScope, evidence: &Evidence) -> AskScope {
    let bounds = date.bounds();
    let bound = evidence.meetings.is_some() || evidence.screens.is_some();
    let meeting_ids = evidence.meetings.clone().unwrap_or_default();
    let mut screen_ids = evidence.screens.clone().unwrap_or_default();
    let (mut include_meetings, mut include_activity, mut include_screen, mut include_files) = (
        sources.meetings,
        sources.activity,
        sources.screen,
        sources.files,
    );
    let mut include_agent_notes = sources.agent_notes;
    if bound {
        // No meeting boundary (a session's screens) leaves the source as chosen.
        include_meetings =
            sources.meetings && evidence.meetings.as_ref().is_none_or(|ids| !ids.is_empty());
        include_screen = sources.screen && !screen_ids.is_empty();
        include_activity = sources.activity && evidence.from_results;
        include_files = sources.files && evidence.from_results && evidence.had_file_results;
        include_agent_notes =
            sources.agent_notes && evidence.from_results && evidence.had_note_results;
    }
    if !evidence.pins.is_empty() {
        include_screen = true;
        screen_ids = evidence.pins.clone();
    }
    let mut saved_sources: Vec<AskSourceScope> = [
        (AskSourceScope::Meetings, include_meetings),
        (AskSourceScope::Today, include_activity),
        (AskSourceScope::Screen, include_screen),
        (AskSourceScope::Files, include_files),
        (AskSourceScope::AgentNotes, include_agent_notes),
    ]
    .into_iter()
    .filter_map(|(source, on)| on.then_some(source))
    .collect();
    // Nothing left to read within the boundary. A saved empty list would read as
    // every source, so it names the boundary's own source, which stays empty.
    if saved_sources.is_empty() {
        saved_sources.push(if evidence.meetings.is_some() {
            AskSourceScope::Meetings
        } else {
            AskSourceScope::Screen
        });
    }
    let saved = QuestionScope {
        sources: saved_sources,
        day_scope_key: date.storage_key(),
        attached_screen_day_keys: evidence.pin_days.clone(),
        meeting_ids: evidence.meetings.clone(),
        screen_snapshot_ids: if evidence.pins.is_empty() {
            evidence.screens.clone()
        } else {
            Some(evidence.pins.clone())
        },
        screen_app: evidence.screen_app.clone(),
    };
    AskScope {
        meeting_ids,
        include_meetings,
        include_activity,
        include_screen,
        include_files,
        include_agent_notes,
        screen_ids,
        attached_screens: !evidence.pins.is_empty(),
        screen_app: evidence.screen_app.clone(),
        since: bounds.map(|(since, _)| since),
        until: bounds.map(|(_, until)| until),
        saved,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_session_bounds_the_question_to_its_screens() {
        let evidence = Evidence {
            screens: Some(vec![4, 5]),
            ..Default::default()
        };
        let scope = ask_scope(session_sources(&[4, 5]), DateScope::AnyTime, &evidence);
        assert!(scope.include_screen);
        assert!(!scope.include_meetings);
        assert!(!scope.include_activity);
        assert!(!scope.include_files);
        assert_eq!(scope.screen_ids, [4, 5]);
        assert!(scope.meeting_ids.is_empty());
        // Nothing attached: the model searches them, they aren't in the prompt.
        assert!(!scope.attached_screens);
    }

    #[test]
    fn a_session_without_moments_asks_about_the_days_meetings() {
        let evidence = Evidence {
            screens: Some(Vec::new()),
            ..Default::default()
        };
        let scope = ask_scope(session_sources(&[]), DateScope::AnyTime, &evidence);
        assert!(scope.include_meetings);
        assert!(!scope.include_screen);
        assert!(scope.meeting_ids.is_empty());
    }

    #[test]
    fn keeps_one_source() {
        let (none, files) = (
            Offered::default(),
            Offered {
                files: true,
                agent_notes: false,
            },
        );
        let mut sources = Sources::default();
        assert_eq!(sources.summary(none), "All sources");
        assert_eq!(sources.summary(files), "All sources");
        sources.toggle(Source::Meetings, none);
        sources.toggle(Source::Activity, none);
        assert_eq!(sources.summary(none), "Screen");
        sources.toggle(Source::Screen, none);
        assert_eq!(sources.summary(none), "Screen", "the last source stays");
    }

    #[test]
    fn files_is_offered_only_while_on() {
        let files = Offered {
            files: true,
            agent_notes: false,
        };
        assert_eq!(Source::available(Offered::default()).count(), 3);
        assert_eq!(Source::available(files).count(), 4);
        let mut sources = Sources::default();
        sources.toggle(Source::Files, files);
        assert_eq!(sources.summary(files), "Meetings, Activity, Screen");
        // Off, it doesn't make the question look narrowed.
        assert_eq!(sources.summary(Offered::default()), "All sources");
    }

    #[test]
    fn agent_notes_is_part_of_all_sources_but_offered_only_while_on() {
        assert!(AskSourceScope::defaults().contains(&AskSourceScope::AgentNotes));
        let notes = Offered {
            files: false,
            agent_notes: true,
        };
        assert_eq!(
            Source::available(notes).collect::<Vec<_>>(),
            [
                Source::Meetings,
                Source::Activity,
                Source::Screen,
                Source::AgentNotes
            ]
        );
        assert!(
            !Source::available(Offered {
                files: true,
                agent_notes: false
            })
            .any(|source| source == Source::AgentNotes)
        );
        let mut sources = Sources::default();
        sources.toggle(Source::AgentNotes, notes);
        assert!(!sources.agent_notes);
        assert_eq!(sources.summary(notes), "Meetings, Activity, Screen");
        assert_eq!(sources.summary(Offered::default()), "All sources");
        let saved = Sources::from_saved(&[AskSourceScope::Meetings, AskSourceScope::AgentNotes]);
        assert!(saved.meetings && saved.agent_notes && !saved.screen && !saved.files);
        // The Mac's name for the source, so a shared conversation reads the same.
        assert_eq!(
            serde_json::to_string(&AskSourceScope::AgentNotes).unwrap(),
            "\"Agent notes\""
        );
    }

    #[test]
    fn asking_about_results_keeps_agent_notes_when_note_rows_were_shown() {
        let mut evidence = Evidence {
            meetings: Some(vec![Uuid::nil()]),
            screens: Some(Vec::new()),
            from_results: true,
            ..Evidence::default()
        };
        let scope = ask_scope(Sources::default(), DateScope::AnyTime, &evidence);
        assert!(!scope.include_agent_notes, "no note rows");
        assert!(!scope.saved.sources.contains(&AskSourceScope::AgentNotes));
        evidence.had_note_results = true;
        let scope = ask_scope(Sources::default(), DateScope::AnyTime, &evidence);
        assert!(scope.include_agent_notes);
        assert!(scope.saved.sources.contains(&AskSourceScope::AgentNotes));
        // A reopened question keeps the source it named.
        assert!(scope_for(&scope.saved).include_agent_notes);
        // Unbound, the source is as chosen.
        let unbound = ask_scope(
            Sources {
                agent_notes: false,
                ..Sources::default()
            },
            DateScope::AnyTime,
            &Evidence::default(),
        );
        assert!(!unbound.include_agent_notes && unbound.include_files);
    }

    #[test]
    fn every_source_joins_unbound_questions() {
        let scope = ask_scope(Sources::default(), DateScope::Today, &Evidence::default());
        assert!(scope.include_meetings && scope.include_screen);
        assert!(scope.include_activity && scope.include_files);
        assert!(scope.include_agent_notes);
        assert!(scope.since.is_some() && scope.until.is_some());
        let screen_only = ask_scope(
            Sources {
                meetings: false,
                activity: false,
                screen: true,
                files: false,
                agent_notes: false,
            },
            DateScope::AnyTime,
            &Evidence::default(),
        );
        assert!(!screen_only.include_meetings && screen_only.include_screen);
        assert!(!screen_only.include_activity && !screen_only.include_files);
    }

    #[test]
    fn a_question_bound_to_a_meeting_reads_only_it() {
        let evidence = Evidence {
            meetings: Some(vec![Uuid::nil()]),
            ..Evidence::default()
        };
        let bound = ask_scope(Sources::default(), DateScope::AnyTime, &evidence);
        assert!(bound.include_meetings);
        assert!(!bound.include_screen && !bound.include_activity && !bound.include_files);
    }

    #[test]
    fn asking_about_results_keeps_activity_and_files_with_file_rows() {
        let mut evidence = Evidence {
            meetings: Some(vec![Uuid::nil()]),
            screens: Some(vec![7]),
            from_results: true,
            ..Evidence::default()
        };
        let scope = ask_scope(Sources::default(), DateScope::AnyTime, &evidence);
        assert!(scope.include_meetings && scope.include_screen && scope.include_activity);
        assert_eq!(scope.screen_ids, [7]);
        assert!(!scope.include_files, "no file rows");
        evidence.had_file_results = true;
        assert!(ask_scope(Sources::default(), DateScope::AnyTime, &evidence).include_files);
        // Only files matched: no meeting or screen source widens to "all".
        let only_files = Evidence {
            meetings: Some(Vec::new()),
            screens: Some(Vec::new()),
            from_results: true,
            had_file_results: true,
            ..Evidence::default()
        };
        let scope = ask_scope(Sources::default(), DateScope::AnyTime, &only_files);
        assert!(!scope.include_meetings && !scope.include_screen && scope.include_files);
    }

    #[test]
    fn attached_screens_grant_the_screen_source_and_keep_the_dates() {
        let evidence = Evidence {
            pins: vec![9],
            ..Evidence::default()
        };
        let sources = Sources {
            screen: false,
            ..Sources::default()
        };
        let scope = ask_scope(sources, DateScope::Today, &evidence);
        assert!(scope.include_screen);
        assert_eq!(scope.screen_ids, [9]);
        assert!(scope.since.is_some(), "the selected day still applies");
    }

    /// Reopening keeps every limit, and a follow-up or retry asks within it.
    #[test]
    fn a_reopened_question_never_widens() {
        let day = NaiveDate::from_ymd_opt(2026, 10, 1).unwrap();
        let cases = [
            ask_scope(
                Sources {
                    meetings: true,
                    activity: false,
                    screen: false,
                    files: false,
                    agent_notes: false,
                },
                DateScope::Day(day),
                &Evidence::default(),
            ),
            ask_scope(
                Sources::default(),
                DateScope::Range(day, day + Days::new(6)),
                &Evidence {
                    meetings: Some(vec![Uuid::from_u128(1)]),
                    screens: Some(vec![7]),
                    from_results: true,
                    ..Evidence::default()
                },
            ),
            ask_scope(
                session_sources(&[4, 5]),
                DateScope::AnyTime,
                &Evidence {
                    screens: Some(vec![4, 5]),
                    ..Evidence::default()
                },
            ),
            ask_scope(
                Sources::default(),
                DateScope::Day(day),
                &Evidence {
                    pins: vec![9],
                    pin_days: vec!["2026-10-01".into()],
                    ..Evidence::default()
                },
            ),
            ask_scope(
                Sources::default(),
                DateScope::AnyTime,
                &Evidence {
                    meetings: Some(Vec::new()),
                    screens: Some(Vec::new()),
                    from_results: true,
                    had_file_results: true,
                    ..Evidence::default()
                },
            ),
        ];
        for asked in cases {
            let question = ChatMessage::new(ChatRole::User, "Q").with_scope(&asked.saved);
            let saved = QuestionScope::current(std::slice::from_ref(&question)).unwrap();
            let follow_up = scope_for(&saved);
            assert_eq!(follow_up.since, asked.since, "{asked:?}");
            assert_eq!(follow_up.until, asked.until, "{asked:?}");
            assert_eq!(follow_up.meeting_ids, asked.meeting_ids, "{asked:?}");
            // An attached moment stays the boundary, no longer in the prompt.
            assert_eq!(follow_up.screen_ids, asked.screen_ids, "{asked:?}");
            assert!(!follow_up.attached_screens);
            assert!(
                !follow_up.include_meetings || asked.include_meetings,
                "{asked:?}"
            );
            assert!(
                !follow_up.include_activity || asked.include_activity,
                "{asked:?}"
            );
            assert!(
                !follow_up.include_screen || asked.include_screen,
                "{asked:?}"
            );
            assert!(!follow_up.include_files || asked.include_files, "{asked:?}");
            assert!(
                !follow_up.include_agent_notes || asked.include_agent_notes,
                "{asked:?}"
            );
            assert_eq!(follow_up.saved.day_scope_key, asked.saved.day_scope_key);
            assert_eq!(follow_up.saved.meeting_ids, asked.saved.meeting_ids);
            assert_eq!(
                follow_up.saved.screen_snapshot_ids,
                asked.saved.screen_snapshot_ids
            );
            assert!(!asked.saved.sources.is_empty(), "empty reads as everything");
        }
    }

    #[test]
    fn a_saved_range_keeps_its_days_when_reopened() {
        let first = NaiveDate::from_ymd_opt(2026, 9, 25).unwrap();
        let last = NaiveDate::from_ymd_opt(2026, 10, 1).unwrap();
        let range = DateScope::Range(first, last);
        assert_eq!(
            range.storage_key().as_deref(),
            Some("2026-09-25...2026-10-01")
        );
        assert_eq!(
            DateScope::from_storage_key("2026-09-25...2026-10-01"),
            range
        );
        assert_eq!(
            DateScope::from_storage_key("2026-10-01"),
            DateScope::Day(last)
        );
        assert_eq!(DateScope::AnyTime.storage_key(), None);
        let today = Local::now().date_naive();
        assert_eq!(
            DateScope::Today.storage_key(),
            Some(lokalbot_core::day_key(today))
        );
        // Last 7 days is saved as its days, and still labelled while it is that.
        let seven = DateScope::from_storage_key(&DateScope::LastSevenDays.storage_key().unwrap());
        assert_eq!(seven.label(), "Last 7 days");
        assert_eq!(seven.bounds(), DateScope::LastSevenDays.bounds());
    }

    #[test]
    fn a_question_says_what_it_was_limited_to() {
        let all = ChatMessage::new(ChatRole::User, "Q").with_scope(&QuestionScope {
            sources: AskSourceScope::ALL.to_vec(),
            ..Default::default()
        });
        let (none, notes) = (
            Offered::default(),
            Offered {
                files: false,
                agent_notes: true,
            },
        );
        assert_eq!(
            question_scope_summary(&all, none).as_deref(),
            Some("All sources")
        );
        assert_eq!(
            question_scope_summary(&all, notes).as_deref(),
            Some("All sources")
        );
        // Saved before agent notes were a source: still everything, until
        // they are offered and the question can be seen to leave them out.
        let before_notes = ChatMessage::new(ChatRole::User, "Q").with_scope(&QuestionScope {
            sources: AskSourceScope::ALL[..4].to_vec(),
            ..Default::default()
        });
        assert_eq!(
            question_scope_summary(&before_notes, none).as_deref(),
            Some("All sources")
        );
        assert_eq!(
            question_scope_summary(&before_notes, notes).as_deref(),
            Some("Meetings, Activity, Screen, Files")
        );
        let narrow = ChatMessage::new(ChatRole::User, "Q").with_scope(&QuestionScope {
            sources: vec![AskSourceScope::Today, AskSourceScope::Screen],
            day_scope_key: Some("2026-10-01".into()),
            attached_screen_day_keys: vec!["2026-10-01".into()],
            ..Default::default()
        });
        let summary = question_scope_summary(&narrow, none).unwrap();
        assert!(summary.starts_with("Activity, Screen · "), "{summary}");
        assert!(summary.contains("attached screen: "), "{summary}");
        // Legacy turns name nothing, and answers aren't questions.
        assert_eq!(
            question_scope_summary(&ChatMessage::new(ChatRole::User, "Q"), none),
            None
        );
        assert_eq!(
            question_scope_summary(&ChatMessage::new(ChatRole::Assistant, "A"), none),
            None
        );
    }

    #[test]
    fn asking_about_matches_keeps_the_sources_they_came_from() {
        let meeting = [Uuid::nil()];
        let both = evidence_sources(Some(&meeting), &[7]);
        assert!(both.meetings && both.screen);
        assert!(!both.activity && !both.files && !both.agent_notes);
        let meetings = evidence_sources(Some(&meeting), &[]);
        assert!(meetings.meetings && !meetings.screen);
        let screens = evidence_sources(None, &[7]);
        assert!(!screens.meetings && screens.screen);
    }

    #[test]
    fn seven_days_include_today() {
        let (since, until) = DateScope::LastSevenDays.bounds().unwrap();
        assert!(until > Utc::now());
        assert!((until - since).num_hours() >= 7 * 24 - 1);
        assert_eq!(DateScope::AnyTime.bounds(), None);
    }
}
