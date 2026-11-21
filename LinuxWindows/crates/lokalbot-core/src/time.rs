use chrono::{DateTime, Local, NaiveDate, SecondsFormat, TimeZone, Utc};

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

pub const SWIFT_REFERENCE_EPOCH: f64 = 978_307_200.0;

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

pub fn parse_iso(raw: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(raw.trim())
        .ok()
        .map(|d| d.with_timezone(&Utc))
}

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

pub fn now_millis() -> DateTime<Utc> {
    let now = Utc::now();
    DateTime::from_timestamp_millis(now.timestamp_millis()).unwrap_or(now)
}

pub fn now_seconds() -> DateTime<Utc> {
    let now = Utc::now();
    Utc.timestamp_opt(now.timestamp(), 0)
        .single()
        .unwrap_or(now)
}

pub fn local_day(value: DateTime<Utc>) -> NaiveDate {
    value.with_timezone(&Local).date_naive()
}

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

pub fn stamp(seconds: f64) -> String {
    let total = seconds.max(0.0).floor() as u64;
    format!(
        "{:02}:{:02}:{:02}",
        total / 3600,
        (total % 3600) / 60,
        total % 60
    )
}

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
