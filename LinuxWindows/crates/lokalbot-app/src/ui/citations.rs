//! Evidence markers in Ask answers (`ChatCitationParser.swift`).
//!
//! The assistant writes `[meeting:<id>@m:ss]`, `[meeting:<id>]` or
//! `[screen:<n>]` inline. The UI shows them as numbered `[n]` references,
//! deduped in order of first appearance, so a repeated source keeps its number.

use std::collections::HashMap;

use chrono::{DateTime, Local, Utc};
use lokalbot_core::{Meeting, ScreenMoment};
use uuid::Uuid;

/// Screen moments that citations name, loaded off the UI thread; `None`
/// once a moment is known to be gone (deleted or expired).
pub type ScreenCitations = HashMap<i64, Option<ScreenMoment>>;

/// One cited source. Meeting ids may be full UUIDs or short-id prefixes.
#[derive(Clone, Debug, PartialEq)]
pub enum CitationSource {
    Meeting { id: String, at: Option<f64> },
    Screen { snapshot_id: i64 },
}

impl CitationSource {
    /// The meeting this citation names, if it resolves against `meetings`.
    pub fn meeting<'a>(&self, meetings: &'a [Meeting]) -> Option<&'a Meeting> {
        let CitationSource::Meeting { id, .. } = self else {
            return None;
        };
        resolve_meeting(id, meetings)
    }

    /// Key that identifies the underlying source (ignoring the moment).
    fn source_key(&self) -> String {
        match self {
            CitationSource::Meeting { id, .. } => format!("meeting:{}", id.to_lowercase()),
            CitationSource::Screen { snapshot_id } => format!("screen:{snapshot_id}"),
        }
    }
}

/// Text with markers replaced by `[n]`, plus where each `[n]` landed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CitedText {
    pub text: String,
    /// Byte range of each `[n]` in `text`, with its 0-based citation index.
    pub markers: Vec<(std::ops::Range<usize>, usize)>,
    pub citations: Vec<CitationSource>,
}

/// A piece of answer text: plain text or a citation reference.
#[derive(Clone, Debug, PartialEq)]
pub enum Piece {
    Text(String),
    Cite(usize),
}

/// Splits `text` into plain pieces and numbered citations. Invalid markers
/// stay as written. Spaces before punctuation and doubled spaces left around
/// markers are tidied the way the macOS parser does.
pub fn split(text: &str) -> (Vec<Piece>, Vec<CitationSource>) {
    let mut pieces = Vec::new();
    let mut citations: Vec<CitationSource> = Vec::new();
    let mut plain = String::new();
    let mut cursor = 0;
    while let Some(open_rel) = text[cursor..].find('[') {
        let open = cursor + open_rel;
        match parse_marker(&text[open..]) {
            Some((len, source)) => {
                plain.push_str(&text[cursor..open]);
                pieces.push(Piece::Text(std::mem::take(&mut plain)));
                let number = match citations.iter().position(|c| *c == source) {
                    Some(existing) => existing,
                    None => {
                        citations.push(source);
                        citations.len() - 1
                    }
                };
                pieces.push(Piece::Cite(number));
                cursor = open + len;
            }
            None => {
                plain.push_str(&text[cursor..open + 1]);
                cursor = open + 1;
            }
        }
    }
    plain.push_str(&text[cursor..]);
    pieces.push(Piece::Text(plain));

    let mut tidied: Vec<Piece> = Vec::with_capacity(pieces.len());
    for piece in pieces {
        match piece {
            Piece::Text(text) => {
                let after_cite = matches!(tidied.last(), Some(Piece::Cite(_)));
                let text = tidy(&text, after_cite);
                if !text.is_empty() {
                    tidied.push(Piece::Text(text));
                }
            }
            cite => tidied.push(cite),
        }
    }
    if let Some(Piece::Text(first)) = tidied.first_mut() {
        *first = first.trim_start().to_string();
    }
    if let Some(Piece::Text(last)) = tidied.last_mut() {
        *last = last.trim_end().to_string();
    }
    (tidied, citations)
}

/// Replaces markers with `[n]` and records their ranges.
pub fn extract(text: &str) -> CitedText {
    let (pieces, citations) = split(text);
    let mut out = CitedText {
        citations,
        ..Default::default()
    };
    for piece in pieces {
        match piece {
            Piece::Text(text) => out.text.push_str(&text),
            Piece::Cite(index) => {
                let start = out.text.len();
                out.text.push_str(&format!("[{}]", index + 1));
                out.markers.push((start..out.text.len(), index));
            }
        }
    }
    out
}

/// Plain answer text for the clipboard: markers become `[n]`.
pub fn display_text(text: &str) -> String {
    extract(text).text
}

/// "1 source · Design review", "3 citations · Design review" or
/// "3 citations · 2 sources" (`EvidenceDisclosure.evidenceSummary`).
pub fn evidence_summary(
    citations: &[CitationSource],
    meetings: &[Meeting],
    screens: &ScreenCitations,
) -> String {
    let Some(first) = citations.first() else {
        return lokalbot_i18n::tr("No sources").into();
    };
    let mut keys: Vec<String> = citations.iter().map(CitationSource::source_key).collect();
    keys.sort();
    keys.dedup();
    let title = resolve(first, meetings, screens).title;
    if citations.len() == 1 {
        lokalbot_i18n::format("1 source · {title}", &[("title", title.to_string())])
    } else if keys.len() == 1 {
        lokalbot_i18n::format(
            "{0} citations · {title}",
            &[
                ("0", format!("{}", citations.len())),
                ("title", title.to_string()),
            ],
        )
    } else {
        lokalbot_i18n::format(
            "{0} citations · {1} sources",
            &[
                ("0", format!("{}", citations.len())),
                ("1", format!("{}", keys.len())),
            ],
        )
    }
}

/// What an evidence row shows for a citation.
#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedCitation {
    pub title: String,
    pub detail: String,
    pub available: bool,
    pub is_screen: bool,
}

pub fn resolve(
    source: &CitationSource,
    meetings: &[Meeting],
    screens: &ScreenCitations,
) -> ResolvedCitation {
    match source {
        CitationSource::Meeting { id, at } => match resolve_meeting(id, meetings) {
            Some(meeting) => {
                let stamp = at
                    .map(|t| format!(" · {}", lokalbot_core::time::stamp(t)))
                    .unwrap_or_default();
                ResolvedCitation {
                    title: meeting.display_title(),
                    detail: lokalbot_i18n::format(
                        "Meeting · {0}{stamp}",
                        &[
                            ("0", date_and_time(meeting.started_at).to_string()),
                            ("stamp", stamp.to_string()),
                        ],
                    ),
                    available: true,
                    is_screen: false,
                }
            }
            None => ResolvedCitation {
                title: lokalbot_i18n::format("Meeting {id}", &[("id", id.to_string())]),
                detail: lokalbot_i18n::tr("Local source missing").into(),
                available: false,
                is_screen: false,
            },
        },
        CitationSource::Screen { snapshot_id } => match screens.get(snapshot_id) {
            Some(Some(moment)) => {
                let title = [&moment.window_title, &moment.document_name]
                    .into_iter()
                    .find(|t| !t.trim().is_empty())
                    .cloned()
                    .unwrap_or_else(|| moment.app.clone());
                ResolvedCitation {
                    title,
                    detail: lokalbot_i18n::format(
                        "Screen · {0} · {1}",
                        &[
                            ("0", moment.app.to_string()),
                            ("1", date_and_time(moment.ts).to_string()),
                        ],
                    ),
                    available: true,
                    is_screen: true,
                }
            }
            known => ResolvedCitation {
                title: lokalbot_i18n::tr("Screen moment").into(),
                detail: if known.is_some() {
                    lokalbot_i18n::tr("Local source missing").into()
                } else {
                    lokalbot_i18n::tr("Screen · Loading…").into()
                },
                available: false,
                is_screen: true,
            },
        },
    }
}

/// "Oct 8, 2026 at 11:57 AM" (Swift's abbreviated date + shortened time).
pub fn date_and_time(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local)
        .format_localized(
            lokalbot_i18n::date_pattern("%b %-d, %Y at %-I:%M %p"),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}

/// Full UUIDs, or a unique prefix of the dashless id (`SessionLookup.find`).
pub fn resolve_meeting<'a>(id: &str, meetings: &'a [Meeting]) -> Option<&'a Meeting> {
    if let Ok(uuid) = Uuid::parse_str(id.trim()) {
        return meetings.iter().find(|m| m.id == uuid);
    }
    let prefix = id.trim().replace('-', "").to_lowercase();
    if prefix.len() < 3 {
        return None;
    }
    let mut matches = meetings
        .iter()
        .filter(|m| m.id.simple().to_string().starts_with(&prefix));
    let first = matches.next()?;
    matches.next().is_none().then_some(first)
}

/// Parses one marker at the start of `text`; returns its byte length.
fn parse_marker(text: &str) -> Option<(usize, CitationSource)> {
    let body = text.strip_prefix('[')?;
    let (kind, rest) = match body.strip_prefix("meeting:") {
        Some(rest) => ("meeting", rest),
        None => ("screen", body.strip_prefix("screen:")?),
    };
    let id_len = rest
        .bytes()
        .take_while(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
        .count();
    if id_len == 0 || id_len > 64 {
        return None;
    }
    let id = &rest[..id_len];
    let mut after = &rest[id_len..];
    let mut stamp = None;
    if let Some(time) = after.strip_prefix('@') {
        let stamp_len = time
            .bytes()
            .take_while(|b| b.is_ascii_digit() || *b == b':')
            .count();
        let raw = &time[..stamp_len];
        if !valid_stamp(raw) {
            return None;
        }
        stamp = lokalbot_core::time::parse_stamp(raw);
        after = &time[stamp_len..];
    }
    after.strip_prefix(']')?;
    let consumed = text.len() - after.len() + 1;
    let source = if kind == "screen" {
        let snapshot_id: i64 = id.parse().ok().filter(|n| *n > 0)?;
        if stamp.is_some() {
            return None;
        }
        CitationSource::Screen { snapshot_id }
    } else {
        if id.len() < 3 {
            return None;
        }
        CitationSource::Meeting {
            id: id.to_string(),
            at: stamp,
        }
    };
    Some((consumed, source))
}

/// `M:SS`, `MM:SS` or `HH:MM:SS`.
fn valid_stamp(raw: &str) -> bool {
    let parts: Vec<&str> = raw.split(':').collect();
    if !(2..=3).contains(&parts.len()) {
        return false;
    }
    let first_ok = !parts[0].is_empty() && parts[0].len() <= 2;
    first_ok
        && parts[1..].iter().all(|p| p.len() == 2)
        && parts.iter().all(|p| p.bytes().all(|b| b.is_ascii_digit()))
}

/// Drops spaces before punctuation and collapses repeated spaces after text.
/// `after_text` says whether the piece follows visible text (a marker).
fn tidy(text: &str, after_text: bool) -> String {
    let mut out = String::with_capacity(text.len());
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == ' ' || c == '\t' {
            let mut j = i;
            while j < chars.len() && (chars[j] == ' ' || chars[j] == '\t') {
                j += 1;
            }
            let next_is_punct =
                j < chars.len() && matches!(chars[j], '.' | ',' | ';' | ':' | '!' | '?');
            if next_is_punct {
                i = j;
                continue;
            }
            let previous_is_text = match out.chars().last() {
                Some(previous) => !previous.is_whitespace(),
                None => after_text,
            };
            if j - i >= 2 && previous_is_text {
                out.push(' ');
            } else {
                out.extend(&chars[i..j]);
            }
            i = j;
            continue;
        }
        out.push(c);
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const REDIS: &str = "adopt Redis [meeting:11111111-1111-4111-8111-111111111111@0:12]. Deferred [meeting:11111111-1111-4111-8111-111111111111@0:38]. Again [meeting:11111111-1111-4111-8111-111111111111@0:12]; and [meeting:00000006-0000-4000-8000-000000000006].";

    #[test]
    fn numbers_markers_in_order_and_reuses_repeats() {
        let cited = extract(REDIS);
        assert_eq!(
            cited.text,
            "adopt Redis [1]. Deferred [2]. Again [1]; and [3]."
        );
        assert_eq!(cited.citations.len(), 3);
        assert_eq!(cited.markers.len(), 4);
        let (range, index) = &cited.markers[2];
        assert_eq!(&cited.text[range.clone()], "[1]");
        assert_eq!(*index, 0);
        assert_eq!(
            cited.citations[1],
            CitationSource::Meeting {
                id: "11111111-1111-4111-8111-111111111111".into(),
                at: Some(38.0)
            }
        );
    }

    #[test]
    fn invalid_markers_stay_as_text() {
        let cited = extract("See [meeting:ab] and [screen:0] and [screen:7] [note].");
        assert_eq!(
            cited.text,
            "See [meeting:ab] and [screen:0] and [1] [note]."
        );
        assert_eq!(
            cited.citations,
            vec![CitationSource::Screen { snapshot_id: 7 }]
        );
    }

    #[test]
    fn tidies_spaces_before_punctuation() {
        assert_eq!(extract("Done [screen:4] .").text, "Done [1].");
        assert_eq!(extract("a  b").text, "a b");
    }

    #[test]
    fn summary_counts_sources() {
        let cited = extract(REDIS);
        assert_eq!(
            evidence_summary(&cited.citations, &[], &ScreenCitations::new()),
            "3 citations · 2 sources"
        );
        let one = extract("x [screen:3]");
        assert_eq!(
            evidence_summary(&one.citations, &[], &ScreenCitations::new()),
            "1 source · Screen moment"
        );
        let moment = ScreenMoment {
            id: 3,
            ts: Utc::now(),
            app: "Firefox".into(),
            window_title: "Quarterly plan".into(),
            capture_trigger: "app_switch".into(),
            path: String::new(),
            source_url: String::new(),
            document_name: String::new(),
            meeting_id: None,
            privacy_redactions: 0,
            text: None,
            saved_note: None,
            is_saved: false,
        };
        let screens = ScreenCitations::from([(3, Some(moment))]);
        let resolved = resolve(&one.citations[0], &[], &screens);
        assert!(resolved.available && resolved.is_screen);
        assert_eq!(resolved.title, "Quarterly plan");
        assert!(resolved.detail.starts_with("Screen · Firefox · "));
        let gone = ScreenCitations::from([(3, None)]);
        assert!(!resolve(&one.citations[0], &[], &gone).available);
    }

    #[test]
    fn stamps_must_be_well_formed() {
        assert!(valid_stamp("0:12"));
        assert!(valid_stamp("01:02:03"));
        assert!(!valid_stamp("012"));
        assert!(!valid_stamp("1:2"));
    }
}
