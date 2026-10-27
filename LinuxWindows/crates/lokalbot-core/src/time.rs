//! Date encodings and display helpers shared by every crate.
//!
//! The macOS app writes four date encodings (see `docs/library-format.md`).
//! Each JSON file uses the matching serde helper below so libraries stay
//! readable by both apps.

use chrono::{DateTime, Local, NaiveDate, SecondsFormat, TimeZone, Utc};

/// ISO-8601 with whole seconds and a `Z` suffix (`meta.json`, chats, projects).
/// Swift's `ISO8601DateFormatter` rejects fractional seconds, so writers must
/// not emit them. Readers accept fractions anyway.
pub mod iso_seconds {
    use super::*;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(
        value: &DateTime<Utc>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&value.to_rfc3339_opts(SecondsFormat::Secs, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<DateTime<Utc>, D::Error> {
        let raw = String::deserialize(deserializer)?;
        super::parse_iso(&raw)
            .ok_or_else(|| serde::de::Error::custom(format!("invalid ISO-8601 date {raw:?}")))
    }

    pub mod option {
        use super::*;
        use serde::{Deserialize, Deserializer, Serializer};

        pub fn serialize<S: Serializer>(
            value: &Option<DateTime<Utc>>,
            serializer: S,
        ) -> Result<S::Ok, S::Error> {
            match value {
                Some(value) => {
                    serializer.serialize_str(&value.to_rfc3339_opts(SecondsFormat::Secs, true))
                }
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Option<DateTime<Utc>>, D::Error> {
            let raw = Option::<String>::deserialize(deserializer)?;
            match raw {
                None => Ok(None),
                Some(raw) => super::super::parse_iso(&raw).map(Some).ok_or_else(|| {
                    serde::de::Error::custom(format!("invalid ISO-8601 date {raw:?}"))
                }),
            }
        }
    }
}

/// ISO-8601 with milliseconds (`outcome-state.json`, `follow-up-draft.json`).
pub mod iso_millis {
    use super::*;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(
        value: &DateTime<Utc>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&value.to_rfc3339_opts(SecondsFormat::Millis, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<DateTime<Utc>, D::Error> {
        let raw = String::deserialize(deserializer)?;
        super::parse_iso(&raw)
            .ok_or_else(|| serde::de::Error::custom(format!("invalid ISO-8601 date {raw:?}")))
    }

    pub mod option {
        use super::*;
        use serde::{Deserialize, Deserializer, Serializer};

        pub fn serialize<S: Serializer>(
            value: &Option<DateTime<Utc>>,
            serializer: S,
        ) -> Result<S::Ok, S::Error> {
            match value {
                Some(value) => {
                    serializer.serialize_str(&value.to_rfc3339_opts(SecondsFormat::Millis, true))
                }
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Option<DateTime<Utc>>, D::Error> {
            let raw = Option::<String>::deserialize(deserializer)?;
            match raw {
                None => Ok(None),
                Some(raw) => super::super::parse_iso(&raw).map(Some).ok_or_else(|| {
                    serde::de::Error::custom(format!("invalid ISO-8601 date {raw:?}"))
                }),
            }
        }
    }
}

/// Seconds between 1970-01-01 and Swift's reference date, 2001-01-01Z.
pub const SWIFT_REFERENCE_EPOCH: f64 = 978_307_200.0;

/// Swift's default `JSONEncoder` date: a number of seconds since
/// 2001-01-01Z (`journal/*.meta.json`, `coding_agent_bursts.payload`).
/// Readers also accept ISO-8601 strings.
pub mod swift_date {
    use super::*;
    use serde::{Deserialize, Deserializer, Serializer};

    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Raw {
        Number(f64),
        Text(String),
    }

    fn decode<E: serde::de::Error>(raw: Raw) -> Result<DateTime<Utc>, E> {
        match raw {
            Raw::Number(seconds) => Ok(super::from_epoch(seconds + SWIFT_REFERENCE_EPOCH)),
            Raw::Text(text) => {
                super::parse_iso(&text).ok_or_else(|| E::custom(format!("invalid date {text:?}")))
            }
        }
    }

    pub fn serialize<S: Serializer>(
        value: &DateTime<Utc>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        serializer.serialize_f64(super::to_epoch(*value) - SWIFT_REFERENCE_EPOCH)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<DateTime<Utc>, D::Error> {
        decode(Raw::deserialize(deserializer)?)
    }

    pub mod option {
        use super::*;

        pub fn serialize<S: Serializer>(
            value: &Option<DateTime<Utc>>,
            serializer: S,
        ) -> Result<S::Ok, S::Error> {
            match value {
                Some(value) => super::serialize(value, serializer),
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Option<DateTime<Utc>>, D::Error> {
            Option::<Raw>::deserialize(deserializer)?
                .map(decode)
                .transpose()
        }
    }
}

/// Parses ISO-8601/RFC 3339 with or without fractional seconds.
pub fn parse_iso(raw: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(raw.trim())
        .ok()
        .map(|d| d.with_timezone(&Utc))
}

/// SQLite timestamp columns hold REAL Unix epoch seconds.
pub fn from_epoch(seconds: f64) -> DateTime<Utc> {
    let whole = seconds.floor();
    let nanos = ((seconds - whole) * 1e9).round().clamp(0.0, 999_999_999.0) as u32;
    Utc.timestamp_opt(whole as i64, nanos)
        .single()
        .unwrap_or_else(Utc::now)
}

pub fn to_epoch(value: DateTime<Utc>) -> f64 {
    value.timestamp() as f64 + f64::from(value.timestamp_subsec_nanos()) / 1e9
}

/// Current time at millisecond precision, as ISO-8601 millisecond files
/// store it (`outcomePersistedTimestamp`).
pub fn now_millis() -> DateTime<Utc> {
    let now = Utc::now();
    DateTime::from_timestamp_millis(now.timestamp_millis()).unwrap_or(now)
}

/// Current time truncated to whole seconds, for values written to `meta.json`.
pub fn now_seconds() -> DateTime<Utc> {
    let now = Utc::now();
    Utc.timestamp_opt(now.timestamp(), 0)
        .single()
        .unwrap_or(now)
}

/// The local calendar day of a UTC instant.
pub fn local_day(value: DateTime<Utc>) -> NaiveDate {
    value.with_timezone(&Local).date_naive()
}

/// `[start, end)` of a local calendar day in UTC.
pub fn local_day_bounds(day: NaiveDate) -> (DateTime<Utc>, DateTime<Utc>) {
    let start = day.and_hms_opt(0, 0, 0).expect("midnight exists");
    let next = (day + chrono::Days::new(1))
        .and_hms_opt(0, 0, 0)
        .expect("midnight exists");
    let to_utc = |naive: chrono::NaiveDateTime| {
        Local
            .from_local_datetime(&naive)
            .earliest()
            .unwrap_or_else(|| Local.from_utc_datetime(&naive))
            .with_timezone(&Utc)
    };
    (to_utc(start), to_utc(next))
}

/// `HH:MM:SS`, the stamp used by transcripts, citations and evidence pills.
pub fn stamp(seconds: f64) -> String {
    let total = seconds.max(0.0).floor() as u64;
    format!(
        "{:02}:{:02}:{:02}",
        total / 3600,
        (total % 3600) / 60,
        total % 60
    )
}

/// Parses `HH:MM:SS`, `MM:SS` or `H:MM:SS` into seconds.
pub fn parse_stamp(raw: &str) -> Option<f64> {
    let parts: Vec<&str> = raw.trim().split(':').collect();
    if parts.is_empty() || parts.len() > 3 {
        return None;
    }
    let mut total = 0f64;
    for part in parts {
        let value: u64 = part.parse().ok()?;
        total = total * 60.0 + value as f64;
    }
    Some(total)
}

/// `MM:SS`, or `H:MM:SS` past an hour: the recording timer.
pub fn timer(seconds: f64) -> String {
    let total = seconds.max(0.0).floor() as u64;
    if total >= 3600 {
        format!(
            "{}:{:02}:{:02}",
            total / 3600,
            (total % 3600) / 60,
            total % 60
        )
    } else {
        format!("{:02}:{:02}", total / 60, total % 60)
    }
}

/// Meeting list durations: "2 min", "25 min", "1 hr 5 min".
pub fn meeting_duration_label(seconds: f64) -> String {
    let minutes = (seconds / 60.0).round().max(1.0) as u64;
    if minutes < 60 {
        format!("{minutes} min")
    } else if minutes.is_multiple_of(60) {
        format!("{} hr", minutes / 60)
    } else {
        format!("{} hr {} min", minutes / 60, minutes % 60)
    }
}

/// Tracked-time chips and legends: "3h 50m", "48m", "<1m".
pub fn compact_duration(seconds: f64) -> String {
    let minutes = (seconds / 60.0).floor() as u64;
    if minutes == 0 {
        return "<1m".into();
    }
    if minutes < 60 {
        format!("{minutes}m")
    } else {
        format!("{}h {}m", minutes / 60, minutes % 60)
    }
}

/// A time of day in the user's locale style, e.g. "10:57 AM".
pub fn clock_time(value: DateTime<Utc>) -> String {
    value
        .with_timezone(&Local)
        .format_localized(
            lokalbot_i18n::date_pattern("%-I:%M %p"),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stamps_round_trip() {
        assert_eq!(stamp(26.9), "00:00:26");
        assert_eq!(stamp(3725.0), "01:02:05");
        assert_eq!(parse_stamp("01:02:05"), Some(3725.0));
        assert_eq!(parse_stamp("0:12"), Some(12.0));
        assert_eq!(parse_stamp("x"), None);
    }

    #[test]
    fn durations_match_the_mac_labels() {
        assert_eq!(meeting_duration_label(120.0), "2 min");
        assert_eq!(meeting_duration_label(3900.0), "1 hr 5 min");
        assert_eq!(compact_duration(13800.0), "3h 50m");
        assert_eq!(compact_duration(20.0), "<1m");
        assert_eq!(timer(65.0), "01:05");
        assert_eq!(timer(3725.0), "1:02:05");
    }

    #[test]
    fn iso_parsing_accepts_fractions() {
        assert!(parse_iso("2026-10-15T10:27:00Z").is_some());
        assert!(parse_iso("2026-10-15T10:27:00.123Z").is_some());
        assert!(parse_iso("2026-10-15T10:27:00+02:00").is_some());
    }
}
