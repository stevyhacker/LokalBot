//! What a question may draw on: sources and a date scope (`AskSourceScope`,
//! `AskDateScope`). The sources are meetings and screen memory; the Mac's
//! activity source is not offered because `lokalbot_ai::ask` does not read
//! activity totals.

use chrono::{DateTime, Datelike as _, Days, Local, NaiveDate, Utc};
use uuid::Uuid;

use crate::state::AskScope;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Sources {
    pub meetings: bool,
    pub screen: bool,
}

impl Default for Sources {
    fn default() -> Self {
        Self {
            meetings: true,
            screen: true,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Meetings,
    Screen,
}

impl Source {
    pub const ALL: [Source; 2] = [Source::Meetings, Source::Screen];

    pub fn label(self) -> &'static str {
        match self {
            Source::Meetings => lokalbot_i18n::tr("Meetings"),
            Source::Screen => lokalbot_i18n::tr("Screen"),
        }
    }
}

impl Sources {
    pub fn contains(&self, source: Source) -> bool {
        match source {
            Source::Meetings => self.meetings,
            Source::Screen => self.screen,
        }
    }

    pub fn count(&self) -> usize {
        Source::ALL.iter().filter(|s| self.contains(**s)).count()
    }

    /// Toggles a source, keeping at least one selected.
    pub fn toggle(&mut self, source: Source) {
        if self.contains(source) && self.count() == 1 {
            return;
        }
        match source {
            Source::Meetings => self.meetings = !self.meetings,
            Source::Screen => self.screen = !self.screen,
        }
    }

    /// "All sources" or "Screen".
    pub fn summary(&self) -> String {
        if *self == Sources::default() {
            return lokalbot_i18n::tr("All sources").into();
        }
        Source::ALL
            .iter()
            .filter(|s| self.contains(**s))
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
        }
    }

    /// `[since, until)` in UTC; `None` for any time.
    pub fn bounds(self) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
        let today = Local::now().date_naive();
        let (first, last) = match self {
            DateScope::AnyTime => return None,
            DateScope::Today => (today, today),
            DateScope::Yesterday => {
                let day = today.pred_opt()?;
                (day, day)
            }
            DateScope::LastSevenDays => (today.checked_sub_days(Days::new(6))?, today),
            DateScope::Day(day) => (day, day),
        };
        let (since, _) = lokalbot_core::time::local_day_bounds(first);
        let (_, until) = lokalbot_core::time::local_day_bounds(last);
        Some((since, until))
    }
}

/// The request sent to the engine for one question. Screen memory is left
/// out when the question is bound to chosen meetings.
pub fn ask_scope(sources: Sources, date: DateScope, meeting_ids: Option<&[Uuid]>) -> AskScope {
    let bounds = date.bounds();
    AskScope {
        meeting_ids: meeting_ids.map(<[Uuid]>::to_vec).unwrap_or_default(),
        include_meetings: sources.meetings,
        include_activity: false,
        include_screen: sources.screen && meeting_ids.is_none(),
        since: bounds.map(|(since, _)| since),
        until: bounds.map(|(_, until)| until),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_one_source() {
        let mut sources = Sources::default();
        assert_eq!(sources.summary(), "All sources");
        sources.toggle(Source::Meetings);
        assert_eq!(sources.summary(), "Screen");
        sources.toggle(Source::Screen);
        assert_eq!(sources.summary(), "Screen", "the last source stays");
    }

    #[test]
    fn screen_memory_joins_unbound_questions() {
        let scope = ask_scope(Sources::default(), DateScope::Today, None);
        assert!(scope.include_meetings && scope.include_screen);
        assert!(!scope.include_activity);
        assert!(scope.since.is_some() && scope.until.is_some());
        let bound = ask_scope(Sources::default(), DateScope::AnyTime, Some(&[Uuid::nil()]));
        assert!(bound.include_meetings && !bound.include_screen);
        let screen_only = ask_scope(
            Sources {
                meetings: false,
                screen: true,
            },
            DateScope::AnyTime,
            None,
        );
        assert!(!screen_only.include_meetings && screen_only.include_screen);
    }

    #[test]
    fn seven_days_include_today() {
        let (since, until) = DateScope::LastSevenDays.bounds().unwrap();
        assert!(until > Utc::now());
        assert!((until - since).num_hours() >= 7 * 24 - 1);
        assert_eq!(DateScope::AnyTime.bounds(), None);
    }
}
