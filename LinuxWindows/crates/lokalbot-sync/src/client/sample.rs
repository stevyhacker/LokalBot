//! Extractive answers from the unpaired sample library. Real questions are
//! answered by the paired computer; this never invokes an engine or a network.

use serde_json::{Value, json};

use super::store::ClientStore;
use crate::error::Result;
use crate::records::{MEETING, str_field};

const STOP_WORDS: &[&str] = &[
    "what", "when", "where", "which", "about", "this", "that", "with", "week", "have", "does",
    "did", "from", "were", "will", "there", "they", "their", "decide", "decided",
];

pub(super) fn answer(
    store: &ClientStore,
    request_id: &str,
    request: &Value,
    now: &str,
) -> Result<Value> {
    let question = str_field(request, "question")
        .unwrap_or_default()
        .to_lowercase();
    let terms: Vec<&str> = question
        .split(|character: char| !character.is_alphanumeric())
        .filter(|term| term.chars().count() >= 4 && !STOP_WORDS.contains(term))
        .collect();
    let mut lines = Vec::new();
    let mut citations = Vec::new();

    for (meeting_id, meeting) in
        store.bodies(MEETING, "json_extract(body, '$.startedAt') DESC, key")?
    {
        if meeting
            .get("mergedInto")
            .is_some_and(|value| !value.is_null())
        {
            continue;
        }
        let title = str_field(&meeting, "title").unwrap_or("Meeting");
        let title_lower = title.to_lowercase();
        for field in ["decisions", "actions"] {
            for item in meeting
                .get(field)
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let Some(text) = str_field(item, "text").filter(|text| !text.trim().is_empty())
                else {
                    continue;
                };
                let text_lower = text.to_lowercase();
                if !terms
                    .iter()
                    .any(|term| text_lower.contains(term) || title_lower.contains(term))
                {
                    continue;
                }
                let text = if field == "actions" {
                    let owner = if item.get("ownerIsUser").and_then(Value::as_bool) == Some(true) {
                        "You"
                    } else {
                        str_field(item, "owner").unwrap_or("Someone")
                    };
                    format!("{owner}: {text}")
                } else {
                    text.to_owned()
                };
                let at = item.pointer("/citations/0/start").and_then(Value::as_f64);
                let label = at.map_or_else(
                    || title.to_owned(),
                    |seconds| {
                        let seconds = seconds.max(0.0) as u64;
                        format!("{title} · {}:{:02}", seconds / 60, seconds % 60)
                    },
                );
                let index = citations.len() + 1;
                citations.push(
                    json!({ "index": index, "meetingId": meeting_id, "at": at, "label": label }),
                );
                lines.push(format!("- {} [{index}]", text.trim_end_matches('.')));
                if citations.len() == 4 {
                    break;
                }
            }
            if citations.len() == 4 {
                break;
            }
        }
        if citations.len() == 4 {
            break;
        }
    }

    let answer = if lines.is_empty() {
        "The sample library doesn't cover that. Try asking about onboarding, pricing or the Northwind call.".to_owned()
    } else {
        format!(
            "Here is what the sample library has on that:\n\n{}",
            lines.join("\n")
        )
    };
    Ok(json!({
        "requestId": request_id,
        "answer": answer,
        "citations": citations,
        "engineLabel": "Sample library",
        "location": "mac",
        "answeredAt": now,
    }))
}
