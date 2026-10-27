//! Tolerant reading of model output (`ChatPrompt.extractJSONObject`,
//! `CompleteJSONRecords`, `strippingReasoning`).

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value};

/// Removes `<think>…</think>` blocks that Qwen 3 and similar models emit
/// before the answer, then trims.
pub fn strip_reasoning(text: &str) -> String {
    let mut result = text.to_string();
    while let Some(open) = result.find("<think>") {
        let Some(close_rel) = result[open + 7..].find("</think>") else {
            break;
        };
        let close = open + 7 + close_rel + "</think>".len();
        result.replace_range(open..close, "");
    }
    result.trim().to_string()
}

/// A truncated reply's visible part: an unclosed thinking block is reasoning.
pub fn visible_text_of_truncated(reply: &str) -> String {
    match reply.find("<think>") {
        Some(open) => reply[..open].trim().to_string(),
        None => reply.to_string(),
    }
}

/// The first balanced `{…}` object in `text`, honouring strings and escapes.
pub fn extract_json_object(text: &str) -> Option<&str> {
    let start = text.find('{')?;
    let mut depth = 0i32;
    let mut in_string = false;
    let mut escaped = false;
    for (offset, ch) in text[start..].char_indices() {
        if in_string {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_string = false;
            }
            continue;
        }
        match ch {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(&text[start..start + offset + 1]);
                }
            }
            _ => {}
        }
    }
    None
}

/// Parses the first JSON object in a model reply.
pub fn parse_object(text: &str) -> Option<Map<String, Value>> {
    let cleaned = strip_reasoning(text);
    let json = extract_json_object(&cleaned)?;
    match serde_json::from_str::<Value>(json).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

/// Complete top-level array records, even from a truncated envelope.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CompleteRecords {
    pub arrays: BTreeMap<String, Vec<Map<String, Value>>>,
    /// The envelope parsed whole and every requested key held an array.
    pub complete: bool,
    pub malformed_records: usize,
}

/// `CompleteJSONRecords.parse`: never closes a partial object or invents
/// fields; it keeps only records that were fully written.
pub fn complete_records(text: &str, keys: &[&str]) -> CompleteRecords {
    let keys: BTreeSet<&str> = keys.iter().copied().collect();
    let text = strip_reasoning(text);
    let text = text.trim();
    if text.len() > 262_144 {
        return CompleteRecords::default();
    }
    if let Some(json) = extract_json_object(text)
        && let Ok(Value::Object(object)) = serde_json::from_str::<Value>(json)
    {
        let mut result = CompleteRecords {
            complete: keys
                .iter()
                .all(|k| object.get(*k).is_some_and(Value::is_array)),
            ..Default::default()
        };
        for key in &keys {
            let values = object
                .get(*key)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let records: Vec<Map<String, Value>> = values
                .iter()
                .filter_map(|v| v.as_object().cloned())
                .collect();
            result.malformed_records += values.len() - records.len();
            result.arrays.insert((*key).to_string(), records);
        }
        return result;
    }

    // The strict envelope starts with an object, not arbitrary prose.
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    if chars.first().map(|c| c.1) != Some('{') {
        return CompleteRecords::default();
    }
    let mut result = CompleteRecords::default();
    let mut stack: Vec<char> = Vec::new();
    let mut in_string = false;
    let mut escaped = false;
    let mut string_start = 0usize;
    let mut pending_key: Option<String> = None;
    let mut array_key: Option<String> = None;
    let mut record_start: Option<usize> = None;
    for &(byte, ch) in &chars {
        if in_string {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_string = false;
                if stack == ['{'] {
                    pending_key =
                        serde_json::from_str::<String>(&text[string_start..byte + 1]).ok();
                }
            }
            continue;
        }
        match ch {
            '"' => {
                in_string = true;
                string_start = byte;
            }
            '{' | '[' => {
                if ch == '[' && stack == ['{'] {
                    array_key = pending_key.take().filter(|k| keys.contains(k.as_str()));
                }
                if ch == '{' && stack == ['{', '['] && array_key.is_some() {
                    record_start = Some(byte);
                }
                stack.push(ch);
            }
            '}' | ']' => {
                let opener = if ch == '}' { '{' } else { '[' };
                if stack.last() != Some(&opener) {
                    break;
                }
                if ch == '}' && stack == ['{', '[', '{'] {
                    if let (Some(start), Some(key)) = (record_start, array_key.as_ref()) {
                        match serde_json::from_str::<Value>(&text[start..byte + 1]) {
                            Ok(Value::Object(record)) => {
                                result.arrays.entry(key.clone()).or_default().push(record)
                            }
                            _ => result.malformed_records += 1,
                        }
                    }
                    record_start = None;
                }
                stack.pop();
                if ch == ']' && stack == ['{'] {
                    array_key = None;
                }
            }
            _ => {}
        }
    }
    result
}

/// Rebuilds every object with sorted keys. Grammar-constrained servers emit
/// schema properties in wire order, so request bodies must be stable.
pub fn sort_keys(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let sorted: BTreeMap<String, Value> =
                map.into_iter().map(|(k, v)| (k, sort_keys(v))).collect();
            let mut out = Map::new();
            for (k, v) in sorted {
                out.insert(k, v);
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.into_iter().map(sort_keys).collect()),
        other => other,
    }
}

/// Strips one surrounding Markdown code fence (```json … ```), if present.
pub fn strip_code_fence(text: &str) -> &str {
    let trimmed = text.trim();
    let Some(rest) = trimmed.strip_prefix("```") else {
        return trimmed;
    };
    let body = match rest.find('\n') {
        Some(newline) => &rest[newline + 1..],
        None => rest,
    };
    body.strip_suffix("```").unwrap_or(body).trim()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reasoning_blocks_are_removed() {
        assert_eq!(
            strip_reasoning("<think>hmm</think>\n Answer <think>x</think>!"),
            "Answer !"
        );
        assert_eq!(strip_reasoning("<think>unclosed"), "<think>unclosed");
        assert_eq!(visible_text_of_truncated("Hi <think>long"), "Hi");
    }

    #[test]
    fn extracts_balanced_objects_with_strings() {
        let text = r#"Sure: {"a": "brace } in \"string\"", "b": {"c": 1}} trailing {"x":1}"#;
        assert_eq!(
            extract_json_object(text),
            Some(r#"{"a": "brace } in \"string\"", "b": {"c": 1}}"#)
        );
        assert_eq!(extract_json_object("no json"), None);
        assert_eq!(extract_json_object("{\"open\": 1"), None);
    }

    #[test]
    fn complete_records_survive_truncation() {
        let full = r#"{"notes":[{"t":"a"},{"t":"b"}],"actions":[],"has_more":false}"#;
        let parsed = complete_records(full, &["notes", "actions"]);
        assert!(parsed.complete);
        assert_eq!(parsed.arrays["notes"].len(), 2);

        let cut = r#"{"notes":[{"t":"a, with } brace"},{"t":"b"},{"t":"unfinish"#;
        let parsed = complete_records(cut, &["notes", "actions"]);
        assert!(!parsed.complete);
        assert_eq!(parsed.arrays["notes"].len(), 2);
        assert_eq!(parsed.arrays["notes"][0]["t"], "a, with } brace");

        assert_eq!(
            complete_records("prose {\"notes\":[{\"a\":1}", &["notes"])
                .arrays
                .len(),
            0
        );
    }

    #[test]
    fn keys_are_sorted_recursively() {
        let value = serde_json::json!({"b": 1, "a": {"d": [ {"z": 1, "y": 2} ], "c": 3}});
        assert_eq!(
            sort_keys(value).to_string(),
            r#"{"a":{"c":3,"d":[{"y":2,"z":1}]},"b":1}"#
        );
    }

    #[test]
    fn code_fences_are_stripped() {
        assert_eq!(strip_code_fence("```json\n{\"a\":1}\n```"), "{\"a\":1}");
        assert_eq!(strip_code_fence("plain"), "plain");
    }
}
