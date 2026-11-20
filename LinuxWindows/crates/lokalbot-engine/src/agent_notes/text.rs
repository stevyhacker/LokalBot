use std::path::Path;

use chrono::{DateTime, Utc};
use lokalbot_ai::sanitize;

use crate::coding_agents::text as agent_text;

pub const MAX_FILE_BYTES: u64 = 4 * 1_024 * 1_024;
pub const MAX_NOTE_CHARACTERS: usize = 24_000;
pub const MAX_TITLE_CHARACTERS: usize = 160;
pub const MAX_SUMMARY_CHARACTERS: usize = 400;
pub const MAX_NOTES_PER_AGENT: usize = 5_000;

#[derive(Debug, PartialEq, Eq)]
pub enum ReadFailure {
    Unreadable,
    TooLarge,
}

pub fn contents(path: &Path) -> Result<String, ReadFailure> {
    let size = std::fs::metadata(path).map(|meta| meta.len()).unwrap_or(0);
    if size > MAX_FILE_BYTES {
        return Err(ReadFailure::TooLarge);
    }
    let bytes = std::fs::read(path).map_err(|_| ReadFailure::Unreadable)?;
    Ok(String::from_utf8_lossy(&bytes).replace("\r\n", "\n"))
}

pub fn body(raw: &str) -> String {
    let text = sanitize::redact(raw)
        .replace("\r\n", "\n")
        .replace('\0', "");
    let text = text.trim();
    let Some((cut, _)) = text.char_indices().nth(MAX_NOTE_CHARACTERS) else {
        return text.to_string();
    };
    let kept = &text[..cut];
    let kept = kept.rfind('\n').map_or(kept, |line_end| &kept[..line_end]);
    format!("{}\n…", kept.trim())
}

pub fn line(raw: Option<&str>, max_characters: usize) -> Option<String> {
    let text = agent_text::sanitized(raw?, max_characters);
    (!text.is_empty()).then_some(text)
}

pub fn modification_date(path: &Path) -> DateTime<Utc> {
    std::fs::metadata(path)
        .and_then(|meta| meta.modified())
        .map(DateTime::<Utc>::from)
        .unwrap_or(DateTime::UNIX_EPOCH)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Section {
    pub level: usize,
    pub heading: String,
    pub body: String,
}

pub fn sections(markdown: &str, levels: &[usize]) -> Vec<Section> {
    fn close(result: &mut Vec<Section>, mut current: Section, lines: &mut Vec<&str>) {
        current.body = lines.join("\n").trim().to_string();
        if current.level > 0 || !current.body.is_empty() {
            result.push(current);
        }
        lines.clear();
    }
    let mut result = Vec::new();
    let mut current = Section {
        level: 0,
        heading: String::new(),
        body: String::new(),
    };
    let mut lines: Vec<&str> = Vec::new();
    let mut fence: Option<&str> = None;
    for line in markdown.split('\n') {
        let trimmed = line.trim_start_matches(' ');
        if let Some(open) = fence {
            if trimmed.starts_with(open) {
                fence = None;
            }
            lines.push(line);
            continue;
        }
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            fence = Some(&trimmed[..3]);
            lines.push(line);
            continue;
        }
        let hashes = line.bytes().take_while(|byte| *byte == b'#').count();
        if hashes > 0 && levels.contains(&hashes) && line[hashes..].starts_with(' ') {
            let finished = std::mem::replace(
                &mut current,
                Section {
                    level: hashes,
                    heading: line[hashes..].trim().to_string(),
                    body: String::new(),
                },
            );
            close(&mut result, finished, &mut lines);
        } else {
            lines.push(line);
        }
    }
    close(&mut result, current, &mut lines);
    result
}

pub fn value(key: &str, line: &str) -> Option<String> {
    let rest = line.strip_prefix(key)?.strip_prefix(':')?;
    Some(unquoted(rest.trim()))
}

pub fn unquoted(value: &str) -> String {
    let mut characters = value.chars();
    let (Some(first), Some(last)) = (characters.next(), characters.next_back()) else {
        return value.to_string();
    };
    if first != last {
        return value.to_string();
    }
    let inner = characters.as_str();
    match first {
        '"' => inner.replace("\\\"", "\"").replace("\\\\", "\\"),
        '\'' => inner.replace("''", "'"),
        _ => value.to_string(),
    }
}

pub fn is_folder_path(text: &str) -> bool {
    text.starts_with('/') || agent_text::is_windows_path(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_long_note_is_cut_at_a_line_end() {
        let cut = body(&"one line of the note\n".repeat(2_000));

        assert!(cut.chars().count() <= MAX_NOTE_CHARACTERS + 2);
        assert!(cut.ends_with("one line of the note\n…"));
        assert_eq!(body("  short\r\nnote\0 \n"), "short\nnote");
    }

    #[test]
    fn sections_split_at_the_chosen_levels_outside_fenced_code() {
        let found = sections(
            "intro\n\n# One\n\ntext\n\n```sh\n# not a heading\n```\n\n## Two\n\nmore\n#NoSpace\n# Three\n",
            &[1],
        );
        assert_eq!(
            found
                .iter()
                .map(|s| (s.level, s.heading.as_str()))
                .collect::<Vec<_>>(),
            [(0, ""), (1, "One"), (1, "Three")]
        );
        assert_eq!(found[0].body, "intro");
        assert!(found[1].body.contains("# not a heading"));
        assert!(found[1].body.contains("## Two"));
        assert!(found[1].body.ends_with("#NoSpace"));
        assert_eq!(found[2].body, "");
        assert!(sections("\n\n", &[1]).is_empty());
    }

    #[test]
    fn header_values_lose_their_quotes() {
        assert_eq!(
            value("scope", "scope: Find receipts.").as_deref(),
            Some("Find receipts.")
        );
        assert_eq!(value("scope", "scoped: no"), None);
        assert_eq!(value("cwd", "cwd:").as_deref(), Some(""));
        assert_eq!(
            unquoted(r#""retry the \"501\" upload""#),
            r#"retry the "501" upload"#
        );
        assert_eq!(unquoted("'it''s'"), "it's");
        assert_eq!(unquoted("\""), "\"");
        assert_eq!(unquoted("plain"), "plain");
        assert!(is_folder_path("/Users/me/app"));
        assert!(is_folder_path(r"C:\Users\me\app"));
        assert!(!is_folder_path("User preferences"));
    }
}
