//! What the person chose to share (`CompanionSettings.swift`): captured from
//! `Settings` and handed to the builders as a value.

use chrono::{DateTime, Local, NaiveDate, Utc};
use lokalbot_core::Settings;
use lokalbot_core::time::{local_day, local_day_bounds};
use serde::{Deserialize, Serialize};

#[cfg(test)]
pub const DEFAULT_PORT: u16 = 17890;
pub const LOWEST_PORT: u16 = 1024;

pub fn clamped_port(port: u16) -> u16 {
    port.max(LOWEST_PORT)
}

/// How far back the copy on paired devices reaches. The value is the number
/// of days, 0 for all history, as records.md's `historyDays`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum HistoryWindow {
    #[default]
    All,
    Days30,
    Days90,
    Days365,
}

impl HistoryWindow {
    pub const ALL: [Self; 4] = [Self::All, Self::Days30, Self::Days90, Self::Days365];

    /// An unknown value keeps the default, as the Mac's decoder does.
    pub fn from_days(days: u32) -> Self {
        match days {
            30 => Self::Days30,
            90 => Self::Days90,
            365 => Self::Days365,
            _ => Self::All,
        }
    }

    pub fn days(self) -> u32 {
        match self {
            Self::All => 0,
            Self::Days30 => 30,
            Self::Days90 => 90,
            Self::Days365 => 365,
        }
    }

    /// The first local day inside the window, or `None` for all history.
    pub fn first_day(self, today: NaiveDate) -> Option<NaiveDate> {
        (self != Self::All).then(|| today - chrono::Duration::days(i64::from(self.days()) - 1))
    }

    pub fn start(self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        self.first_day(local_day(now))
            .map(|day| local_day_bounds(day).0)
    }

    pub fn contains(self, at: DateTime<Utc>, now: DateTime<Utc>) -> bool {
        self.start(now).is_none_or(|start| at >= start)
    }

    pub fn contains_day(self, day: NaiveDate, now: DateTime<Utc>) -> bool {
        self.first_day(local_day(now))
            .is_none_or(|first| day >= first)
    }
}

/// The data classes in records.md's manifest, in its order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DataClasses {
    pub meetings: bool,
    pub transcripts: bool,
    pub digests: bool,
    pub timeline: bool,
    pub window_titles: bool,
    pub people: bool,
    pub projects: bool,
}

impl DataClasses {
    #[cfg(test)]
    pub const ALL: Self = Self {
        meetings: true,
        transcripts: true,
        digests: true,
        timeline: true,
        window_titles: true,
        people: true,
        projects: true,
    };

    /// A transcript belongs to its meeting: without the meeting record a
    /// phone has nothing to open it from.
    pub fn shares_transcripts(self) -> bool {
        self.meetings && self.transcripts
    }

    /// Window titles are part of the Timeline.
    pub fn shares_window_titles(self) -> bool {
        self.timeline && self.window_titles
    }

    /// What devices actually receive, as the manifest reports it.
    pub fn effective(self) -> Self {
        Self {
            transcripts: self.shares_transcripts(),
            window_titles: self.shares_window_titles(),
            ..self
        }
    }
}

/// What decides which records exist. Changing only these rebuilds the
/// library; the port and advertising restart the listener instead.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RecordScope {
    pub data_classes: DataClasses,
    pub history: HistoryWindow,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Sharing {
    pub enabled: bool,
    pub data_classes: DataClasses,
    pub history: HistoryWindow,
    pub answers_questions: bool,
    pub accepts_recordings: bool,
    pub port: u16,
    pub advertises: bool,
}

impl Sharing {
    pub fn new(settings: &Settings) -> Self {
        Self {
            enabled: settings.companion_sharing_enabled,
            data_classes: DataClasses {
                meetings: settings.companion_share_meetings,
                transcripts: settings.companion_share_transcripts,
                digests: settings.companion_share_digests,
                timeline: settings.companion_share_timeline,
                window_titles: settings.companion_share_window_titles,
                people: settings.companion_share_people,
                projects: settings.companion_share_projects,
            },
            history: HistoryWindow::from_days(settings.companion_history),
            answers_questions: settings.companion_answers_questions,
            accepts_recordings: settings.companion_accepts_recordings,
            port: clamped_port(settings.companion_port),
            advertises: settings.companion_advertises_on_bonjour,
        }
    }

    pub fn record_scope(&self) -> RecordScope {
        RecordScope {
            data_classes: self.data_classes,
            history: self.history,
        }
    }
}

/// `YYYY-MM-DD`, the day in this computer's time zone.
pub fn day_key(day: NaiveDate) -> String {
    day.format("%Y-%m-%d").to_string()
}

pub fn today() -> NaiveDate {
    Local::now().date_naive()
}

/// A canonical `YYYY-MM-DD` key (`AskDayScope.isCanonicalKey`).
pub fn parse_day_key(key: &str) -> Option<NaiveDate> {
    let day = NaiveDate::parse_from_str(key, "%Y-%m-%d").ok()?;
    (day_key(day) == key).then_some(day)
}
