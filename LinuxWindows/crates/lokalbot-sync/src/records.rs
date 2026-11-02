//! Record conventions shared by both ends (records.md): kinds, canonical
//! JSON for change detection, and timestamps.

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::Value;
use sha2::{Digest, Sha256};

pub(crate) const MANIFEST: &str = "manifest";
pub(crate) const MEETING: &str = "meeting";
pub(crate) const TRANSCRIPT: &str = "transcript";
pub(crate) const DAY: &str = "day";
pub(crate) const PERSON: &str = "person";
pub(crate) const PROJECT: &str = "project";
pub(crate) const MANIFEST_KEY: &str = "library";

pub(crate) const KINDS: [&str; 6] = [MANIFEST, MEETING, TRANSCRIPT, DAY, PERSON, PROJECT];

/// Order among records with the same `sortKey`: a meeting goes before its
/// transcript.
pub(crate) fn kind_rank(kind: &str) -> i64 {
    KINDS
        .iter()
        .position(|k| *k == kind)
        .map_or(KINDS.len() as i64, |i| i as i64)
}

/// JSON with object keys sorted and no whitespace, so equal content always
/// serialises to the same bytes.
pub(crate) fn canonical_json(value: &Value) -> String {
    let mut out = String::new();
    write_canonical(value, &mut out);
    out
}

fn write_canonical(value: &Value, out: &mut String) {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<(&String, &Value)> = map.iter().collect();
            entries.sort_by(|a, b| a.0.cmp(b.0));
            out.push('{');
            for (i, (key, value)) in entries.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(key.clone()).to_string());
                out.push(':');
                write_canonical(value, out);
            }
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical(item, out);
            }
            out.push(']');
        }
        scalar => out.push_str(&scalar.to_string()),
    }
}

/// SHA-256 of the canonical JSON, hex.
pub(crate) fn content_hash(canonical: &str) -> String {
    hex::encode(Sha256::digest(canonical.as_bytes()))
}

/// An instant in the records' format: ISO 8601 UTC with milliseconds.
pub(crate) fn iso(instant: DateTime<Utc>) -> String {
    instant.to_rfc3339_opts(SecondsFormat::Millis, true)
}

pub(crate) fn now_iso() -> String {
    iso(Utc::now())
}

pub(crate) fn iso_from_unix(seconds: i64) -> String {
    DateTime::<Utc>::from_timestamp(seconds, 0).map_or_else(now_iso, iso)
}

pub(crate) fn unix_now() -> i64 {
    Utc::now().timestamp()
}

/// Today's date in this device's time zone, `YYYY-MM-DD`.
pub(crate) fn local_today() -> String {
    chrono::Local::now()
        .date_naive()
        .format("%Y-%m-%d")
        .to_string()
}

pub(crate) fn str_field<'a>(value: &'a Value, field: &str) -> Option<&'a str> {
    value.get(field).and_then(Value::as_str)
}
