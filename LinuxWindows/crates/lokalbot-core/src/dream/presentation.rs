//! Resolves a brief's citations against the current library without rewriting
//! what was saved (`DreamBriefPresentation`). An id the library no longer has
//! reads as unavailable rather than a raw handle.

use std::sync::LazyLock;

use regex::Regex;
use uuid::Uuid;

use crate::model::Meeting;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BriefPiece {
    Text(String),
    Meeting { id: Uuid, title: String },
}

static CITATION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"`([0-9a-fA-F]{8}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})`",
    )
    .expect("valid regex")
});
static OWNER_NOUN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)`?\bowner:\s*me\b`?\s+(actions|tasks|commitments|items)\b")
        .expect("valid regex")
});
static OWNER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)`?\bowner:\s*me\b`?").expect("valid regex"));

fn natural_ownership(text: &str) -> String {
    let first = OWNER_NOUN.replace_all(text, "$1 assigned to you");
    OWNER.replace_all(&first, "assigned to you").into_owned()
}

/// The text with each cited id as a meeting. Older briefs sometimes say "Demo Day
/// `12345678`": the title already there becomes the link instead of repeating.
pub fn brief_pieces(text: &str, meetings: &[Meeting]) -> Vec<BriefPiece> {
    let source = natural_ownership(text);
    let mut pieces = Vec::new();
    let mut plain = String::new();
    let mut cursor = 0;
    for captures in CITATION.captures_iter(&source) {
        let (Some(whole), Some(id)) = (captures.get(0), captures.get(1)) else {
            continue;
        };
        plain.push_str(&source[cursor..whole.start()]);
        cursor = whole.end();
        let id = id.as_str().to_lowercase();
        let candidates: Vec<&Meeting> = meetings
            .iter()
            .filter(|m| m.id.hyphenated().to_string() == id || m.short_id().to_lowercase() == id)
            .collect();
        match candidates[..] {
            [] => plain.push_str(lokalbot_i18n::tr("Unavailable meeting")),
            [meeting] => {
                let title = meeting.display_title();
                let kept = plain.trim_end().len();
                let lowered = plain[..kept].to_lowercase();
                let wanted = title.to_lowercase();
                if lowered.ends_with(&wanted) {
                    let start = kept - wanted.len();
                    if plain.is_char_boundary(start)
                        && (start == 0 || plain[..start].ends_with(char::is_whitespace))
                    {
                        plain.truncate(start);
                    }
                }
                if !plain.is_empty() {
                    pieces.push(BriefPiece::Text(std::mem::take(&mut plain)));
                }
                pieces.push(BriefPiece::Meeting {
                    id: meeting.id,
                    title,
                });
            }
            _ => plain.push_str(lokalbot_i18n::tr("Ambiguous meeting reference")),
        }
    }
    plain.push_str(&source[cursor..]);
    if !plain.is_empty() {
        pieces.push(BriefPiece::Text(plain));
    }
    pieces
}

/// The same text on one line, with titles in place of ids.
pub fn brief_plain(text: &str, meetings: &[Meeting]) -> String {
    brief_pieces(text, meetings)
        .into_iter()
        .map(|piece| match piece {
            BriefPiece::Text(text) => text,
            BriefPiece::Meeting { title, .. } => title,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ids;

    fn meeting(title: &str) -> Meeting {
        let id = Uuid::new_v4();
        serde_json::from_value(serde_json::json!({
            "id": ids::uuid_upper(&id), "title": title, "appName": "Zoom",
            "startedAt": "2026-10-19T09:00:00Z", "endedAt": "2026-10-19T09:30:00Z",
            "relativePath": format!("meetings/{}", id.simple())
        }))
        .unwrap()
    }

    #[test]
    fn cited_ids_become_titles_and_unknown_ones_say_so() {
        let review = meeting("Design review");
        let text = format!("Decided in `{}` and `deadbeef`.", review.short_id());
        let pieces = brief_pieces(&text, std::slice::from_ref(&review));
        assert_eq!(
            pieces,
            vec![
                BriefPiece::Text("Decided in ".into()),
                BriefPiece::Meeting {
                    id: review.id,
                    title: "Design review".into()
                },
                BriefPiece::Text(" and Unavailable meeting.".into()),
            ]
        );
    }

    #[test]
    fn a_title_already_there_isnt_repeated() {
        let review = meeting("Design review");
        let text = format!("See design review `{}`.", review.short_id());
        let pieces = brief_pieces(&text, std::slice::from_ref(&review));
        assert_eq!(pieces[0], BriefPiece::Text("See ".into()));
        assert!(matches!(pieces[1], BriefPiece::Meeting { .. }));
        assert_eq!(pieces[2], BriefPiece::Text(".".into()));
    }

    #[test]
    fn internal_labels_read_naturally() {
        assert_eq!(
            brief_pieces("Finish owner:me actions and `owner: me`", &[]),
            vec![BriefPiece::Text(
                "Finish actions assigned to you and assigned to you".into()
            )]
        );
    }
}
