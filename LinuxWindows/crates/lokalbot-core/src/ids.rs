//! Identifiers shared with the macOS library format.

use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

/// FNV-1a 64-bit, as used for stable outcome, thread and person IDs.
pub fn fnv1a64(input: &str) -> u64 {
    let mut hash: u64 = 14_695_981_039_346_656_037;
    for byte in input.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(1_099_511_628_211);
    }
    hash
}

/// `%016llx` of [`fnv1a64`].
pub fn fnv_hex(input: &str) -> String {
    format!("{:016x}", fnv1a64(input))
}

/// The CLI's short meeting ID: the first 8 lowercase hex characters.
pub fn short_id(id: &Uuid) -> String {
    id.simple().to_string()[..8].to_string()
}

/// Uppercase hyphenated form, matching Swift's `UUID.uuidString`.
pub fn uuid_upper(id: &Uuid) -> String {
    id.hyphenated().to_string().to_uppercase()
}

/// Folder slug: lowercase, diacritics stripped, every non-alphanumeric run
/// becomes one `-`, trimmed at both ends (`StorageManager.slugify`).
pub fn slugify(title: &str) -> String {
    let folded: String = title
        .nfd()
        .filter(|c| !unicode_normalization::char::is_combining_mark(*c))
        .collect::<String>()
        .to_lowercase();
    let mut slug = String::with_capacity(folded.len());
    let mut last_dash = false;
    for c in folded.chars() {
        if c.is_alphanumeric() {
            slug.push(c);
            last_dash = false;
        } else if !last_dash {
            slug.push('-');
            last_dash = true;
        }
    }
    let trimmed = slug.trim_matches('-');
    if trimmed.is_empty() {
        "meeting".into()
    } else {
        trimmed.to_string()
    }
}

/// Case- and diacritic-folded text with collapsed whitespace, used by search
/// and matching.
pub fn fold(text: &str) -> String {
    let folded: String = text
        .nfd()
        .filter(|c| !unicode_normalization::char::is_combining_mark(*c))
        .collect::<String>()
        .to_lowercase();
    folded.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Uppercase serialization for `Uuid` fields, matching the macOS JSON.
pub mod uuid_upper_serde {
    use serde::{Deserialize, Deserializer, Serializer};
    use uuid::Uuid;

    pub fn serialize<S: Serializer>(value: &Uuid, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&super::uuid_upper(value))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Uuid, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Uuid::parse_str(&raw).map_err(serde::de::Error::custom)
    }

    pub mod option {
        use serde::{Deserialize, Deserializer, Serializer};
        use uuid::Uuid;

        pub fn serialize<S: Serializer>(
            value: &Option<Uuid>,
            serializer: S,
        ) -> Result<S::Ok, S::Error> {
            match value {
                Some(id) => serializer.serialize_str(&super::super::uuid_upper(id)),
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Option<Uuid>, D::Error> {
            let raw = Option::<String>::deserialize(deserializer)?;
            raw.map(|r| Uuid::parse_str(&r).map_err(serde::de::Error::custom))
                .transpose()
        }
    }

    pub mod vec {
        use serde::{Deserialize, Deserializer, Serializer, ser::SerializeSeq};
        use uuid::Uuid;

        pub fn serialize<S: Serializer>(
            value: &Option<Vec<Uuid>>,
            serializer: S,
        ) -> Result<S::Ok, S::Error> {
            match value {
                None => serializer.serialize_none(),
                Some(ids) => {
                    let mut seq = serializer.serialize_seq(Some(ids.len()))?;
                    for id in ids {
                        seq.serialize_element(&super::super::uuid_upper(id))?;
                    }
                    seq.end()
                }
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Option<Vec<Uuid>>, D::Error> {
            let raw = Option::<Vec<String>>::deserialize(deserializer)?;
            raw.map(|items| {
                items
                    .iter()
                    .map(|r| Uuid::parse_str(r).map_err(serde::de::Error::custom))
                    .collect::<Result<Vec<_>, _>>()
            })
            .transpose()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_matches_storage_manager() {
        assert_eq!(
            slugify("Customer call - Northwind"),
            "customer-call-northwind"
        );
        assert_eq!(slugify("Čaj s Anom"), "caj-s-anom");
        assert_eq!(slugify("  ***  "), "meeting");
    }

    #[test]
    fn short_id_is_lowercase_prefix() {
        let id = Uuid::parse_str("44444444-4444-4444-8444-444444444444").unwrap();
        assert_eq!(short_id(&id), "44444444");
        assert_eq!(uuid_upper(&id), "44444444-4444-4444-8444-444444444444");
    }

    #[test]
    fn fnv_is_stable() {
        assert_eq!(fnv_hex(""), "cbf29ce484222325");
        assert_eq!(fnv_hex("a"), "af63dc4c8601ec8c");
    }
}
