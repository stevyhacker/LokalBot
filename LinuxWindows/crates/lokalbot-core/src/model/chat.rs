//! Ask conversations (`chats/<UUID>.json`, encrypted as `.json.enc` on macOS).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ids::uuid_upper_serde;
use crate::time::iso_seconds;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub title: String,
    #[serde(with = "iso_seconds")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "iso_seconds")]
    pub updated_at: DateTime<Utc>,
    #[serde(default)]
    pub messages: Vec<ChatMessage>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChatRole {
    User,
    Assistant,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessage {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub role: ChatRole,
    /// Assistant text keeps citations inline as `[meeting:<UUID>@m:ss]`,
    /// `[meeting:<UUID>]` or `[screen:<id>]`; the UI renders them as `[n]`.
    pub text: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub activity: Vec<ChatActivity>,
    #[serde(
        default,
        with = "iso_seconds::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub created_at: Option<DateTime<Utc>>,
}

/// One tool step shown as "worked: searched transcripts · read summary".
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ChatActivity {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub tool: String,
    #[serde(default)]
    pub icon: String,
    pub text: String,
    #[serde(default)]
    pub done: bool,
}

/// A citation parsed from assistant text.
#[derive(Clone, Debug, PartialEq)]
pub enum Citation {
    Meeting { meeting_id: Uuid, at: Option<f64> },
    Screen { snapshot_id: i64 },
}

impl Citation {
    /// Parses every `[meeting:…]`/`[screen:…]` marker in order of appearance,
    /// keeping the first occurrence of each.
    pub fn parse_all(text: &str) -> Vec<(std::ops::Range<usize>, Citation)> {
        let mut out = Vec::new();
        let mut cursor = 0;
        while let Some(open) = text[cursor..].find('[') {
            let start = cursor + open;
            let Some(close_rel) = text[start..].find(']') else {
                break;
            };
            let end = start + close_rel + 1;
            let inner = &text[start + 1..end - 1];
            if let Some(rest) = inner.strip_prefix("meeting:") {
                let (id, at) = match rest.split_once('@') {
                    Some((id, at)) => (id, crate::time::parse_stamp(at)),
                    None => (rest, None),
                };
                if let Ok(meeting_id) = Uuid::parse_str(id.trim()) {
                    out.push((start..end, Citation::Meeting { meeting_id, at }));
                }
            } else if let Some(rest) = inner.strip_prefix("screen:")
                && let Ok(snapshot_id) = rest.trim().parse()
            {
                out.push((start..end, Citation::Screen { snapshot_id }));
            }
            cursor = end;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_meeting_and_screen_citations() {
        let text = "Redis [meeting:11111111-1111-4111-8111-111111111111@0:12] and [screen:42] [x]";
        let parsed = Citation::parse_all(text);
        assert_eq!(parsed.len(), 2);
        assert!(matches!(parsed[0].1, Citation::Meeting { at: Some(t), .. } if t == 12.0));
        assert!(matches!(parsed[1].1, Citation::Screen { snapshot_id: 42 }));
    }
}
