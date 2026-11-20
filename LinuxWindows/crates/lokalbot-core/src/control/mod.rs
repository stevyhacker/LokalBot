pub mod approvals;
pub mod audit;
pub mod change;
pub mod protocol;
pub mod registry;
mod registry_table;
pub mod setup;
pub mod socket;

use serde_json::{Map, Value};

use crate::settings::Settings;

pub fn redact_url(value: &str) -> String {
    let Some((scheme, rest)) = value.split_once("://") else {
        return value.to_string();
    };
    let valid_scheme = scheme
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic())
        && scheme
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c));
    if !valid_scheme || value.chars().any(char::is_whitespace) {
        return value.to_string();
    }
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let (authority, tail) = rest.split_at(end);
    let host = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    if host.is_empty() || host.starts_with(':') {
        return value.to_string();
    }
    let path = tail.split(['?', '#']).next().unwrap_or("");
    format!("{scheme}://{host}{path}")
}

pub fn encoded(settings: &Settings) -> Map<String, Value> {
    let Value::Object(mut object) = serde_json::to_value(settings).unwrap_or(Value::Null) else {
        return Map::new();
    };
    object.insert(
        "codingAgentEvidenceEnabled".into(),
        Value::Bool(settings.coding_agent_evidence_active()),
    );
    object
}

pub fn json_eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(a), Value::Number(b)) => a == b || a.as_f64() == b.as_f64(),
        (Value::Array(a), Value::Array(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(a, b)| json_eq(a, b))
        }
        (Value::Object(a), Value::Object(b)) => {
            a.len() == b.len()
                && a.iter()
                    .all(|(key, value)| b.get(key).is_some_and(|other| json_eq(value, other)))
        }
        _ => a == b,
    }
}

pub fn optional_json_eq(a: Option<&Value>, b: Option<&Value>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => json_eq(a, b),
        (None, None) => true,
        _ => false,
    }
}

pub mod iso8601 {
    use chrono::{DateTime, SecondsFormat, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn text(date: &DateTime<Utc>) -> String {
        date.to_rfc3339_opts(SecondsFormat::Secs, true)
    }

    pub fn serialize<S: Serializer>(
        date: &DateTime<Utc>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&text(date))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<DateTime<Utc>, D::Error> {
        let raw = String::deserialize(deserializer)?;
        DateTime::parse_from_rfc3339(&raw)
            .map(|date| date.with_timezone(&Utc))
            .map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_compare_by_value() {
        assert!(json_eq(&serde_json::json!(15), &serde_json::json!(15.0)));
        assert!(!json_eq(&serde_json::json!(15), &serde_json::json!(15.5)));
        assert!(json_eq(
            &serde_json::json!({"a": [1, 2.0]}),
            &serde_json::json!({"a": [1.0, 2]})
        ));
    }

    #[test]
    fn urls_lose_credentials_and_queries_only() {
        assert_eq!(
            redact_url("https://user:secret@host.example:8443/v1?key=1#x"),
            "https://host.example:8443/v1"
        );
        assert_eq!(redact_url("not a url"), "not a url");
    }

    #[test]
    fn coding_agent_reading_shows_what_happens() {
        let mut settings = Settings::default();
        assert_eq!(encoded(&settings)["codingAgentEvidenceEnabled"], false);
        settings.coding_agent_evidence_confirmed = true;
        assert_eq!(encoded(&settings)["codingAgentEvidenceEnabled"], true);
    }
}
