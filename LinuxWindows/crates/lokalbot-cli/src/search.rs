//! Word search over on-disk meeting artifacts (`LibrarySearch.swift`), so
//! the CLI and MCP need no index. A meeting matches when it contains every
//! query word (any order, case- and accent-insensitive); otherwise partial
//! matches follow. Rare words weigh more, exact-phrase hits lead and ties
//! keep recency. Words of up to three ASCII letters or digits match only
//! whole words; a quoted query matches only its exact phrase.

use std::collections::{HashMap, HashSet};

use lokalbot_core::{Meeting, ids::fold};
use unicode_fold::fold_char;

use crate::session::{SearchHit, Session, short_id};

pub const DEFAULT_LIMIT: usize = 50;
pub const MAXIMUM_TRANSCRIPT_HITS_PER_MEETING: usize = 5;
pub const MAXIMUM_SEARCH_HITS: usize = 500;
pub const MAXIMUM_QUERY_CHARACTERS: usize = 4096;

mod unicode_fold {
    /// One character case- and accent-folded (may be empty or several chars).
    pub fn fold_char(c: char) -> String {
        lokalbot_core::ids::fold(&c.to_string())
    }
}

struct Candidate {
    hit: SearchHit,
    meeting: usize,
    kind: u8,
    position: usize,
    matched: Vec<String>,
    exact: bool,
}

/// Distinct alphanumeric words in query order. A single Latin letter is
/// dropped unless it is the whole query.
pub fn search_terms(folded_query: &str) -> Vec<String> {
    let mut seen = HashSet::new();
    let words: Vec<String> = folded_query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty() && seen.insert(w.to_string()))
        .map(str::to_string)
        .collect();
    let meaningful: Vec<String> = words
        .iter()
        .filter(|w| w.chars().count() > 1 || !w.is_ascii())
        .cloned()
        .collect();
    if meaningful.is_empty() {
        words
    } else {
        meaningful
    }
}

fn is_word_char(c: Option<char>) -> bool {
    c.is_some_and(char::is_alphanumeric)
}

/// Byte range of the first match of `needle` in `text`; short ASCII words
/// must stand alone.
pub fn word_range(needle: &str, text: &str) -> Option<std::ops::Range<usize>> {
    if needle.is_empty() {
        return None;
    }
    let whole_word = needle.chars().count() <= 3 && needle.is_ascii();
    let mut start = 0;
    while start <= text.len() {
        let found = text[start..].find(needle)? + start;
        let end = found + needle.len();
        if !whole_word {
            return Some(found..end);
        }
        let before = text[..found].chars().next_back();
        let after = text[end..].chars().next();
        if !is_word_char(before) && !is_word_char(after) {
            return Some(found..end);
        }
        start = found + text[found..].chars().next().map_or(1, char::len_utf8);
    }
    None
}

/// The haystack's text ±40 characters around the folded `needle`, matched
/// case- and accent-insensitively against the original text.
pub fn snippet(haystack: &str, needle: &str) -> Option<String> {
    let chars: Vec<char> = haystack.chars().collect();
    let mut folded = String::new();
    let mut origin: Vec<usize> = Vec::new();
    for (index, c) in chars.iter().enumerate() {
        let piece = if c.is_whitespace() {
            " ".to_string()
        } else {
            fold_char(*c)
        };
        for _ in 0..piece.len() {
            origin.push(index);
        }
        folded.push_str(&piece);
    }
    origin.push(chars.len());
    let range = word_range(needle, &folded)?;
    let first = origin[range.start];
    let last = origin[range.end.saturating_sub(1).max(range.start)] + 1;
    let start = first.saturating_sub(40);
    let end = (last + 40).min(chars.len());
    let mut text: String = chars[start..end].iter().collect();
    if start > 0 {
        text = format!("…{text}");
    }
    if end < chars.len() {
        text.push('…');
    }
    Some(text)
}

/// `LibrarySearch.hits`.
pub fn hits(
    session: &Session,
    query: &str,
    limit: usize,
    meetings: &[Meeting],
    transcript_hits_per_meeting: Option<usize>,
    require_all_words: bool,
) -> Vec<SearchHit> {
    let trimmed = query.trim();
    let quoted = trimmed.chars().count() > 2 && trimmed.starts_with('"') && trimmed.ends_with('"');
    let phrase = fold(if quoted {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    });
    if phrase.is_empty() {
        return Vec::new();
    }
    let terms: Vec<String> = if quoted {
        vec![phrase.clone()]
    } else {
        search_terms(&phrase)
    };

    let mut candidates: Vec<Candidate> = Vec::new();
    let mut coverage: HashMap<usize, HashSet<String>> = HashMap::new();
    let mut consider = |text: &str,
                        meeting: usize,
                        kind: u8,
                        position: usize,
                        hit: &dyn Fn(&str) -> Option<SearchHit>| {
        let haystack = fold(text);
        let matched: Vec<String> = terms
            .iter()
            .filter(|t| word_range(t, &haystack).is_some())
            .cloned()
            .collect();
        let Some(first) = matched.first().cloned() else {
            return;
        };
        let exact = haystack.contains(&phrase);
        let Some(value) = (if exact { hit(&phrase) } else { None }).or_else(|| hit(&first)) else {
            return;
        };
        coverage
            .entry(meeting)
            .or_default()
            .extend(matched.iter().cloned());
        candidates.push(Candidate {
            hit: value,
            meeting,
            kind,
            position,
            matched,
            exact,
        });
    };

    for (index, meeting) in meetings.iter().enumerate() {
        let short = short_id(meeting);
        let title = meeting.title.clone();
        let sample = meeting.is_sample().then_some(true);
        consider(&meeting.title, index, 0, 0, &|_| {
            Some(SearchHit {
                meeting_id: short.clone(),
                meeting_title: title.clone(),
                match_kind: "title".into(),
                snippet: title.clone(),
                timestamp: None,
                sample,
            })
        });
        if let Some(summary) = session.summary(meeting) {
            consider(&summary, index, 1, 0, &|needle| {
                snippet(&summary, needle).map(|text| SearchHit {
                    meeting_id: short.clone(),
                    meeting_title: title.clone(),
                    match_kind: "summary".into(),
                    snippet: text,
                    timestamp: None,
                    sample,
                })
            });
        }
        if let Some(transcript) = session.transcript(meeting) {
            for (position, segment) in transcript.segments.iter().enumerate() {
                consider(&segment.text, index, 2, position, &|_| {
                    Some(SearchHit {
                        meeting_id: short.clone(),
                        meeting_title: title.clone(),
                        match_kind: "transcript".into(),
                        snippet: segment.text.clone(),
                        timestamp: Some(lokalbot_core::time::stamp(segment.start)),
                        sample,
                    })
                });
            }
        }
    }

    // A word found in few meetings says more than one found in most.
    let mut meetings_with_term: HashMap<&String, usize> = HashMap::new();
    for words in coverage.values() {
        for word in words {
            *meetings_with_term.entry(word).or_default() += 1;
        }
    }
    let total = meetings.len().max(1) as f64;
    let weight = |words: &mut dyn Iterator<Item = &String>| -> f64 {
        words
            .map(|w| {
                (1.0 + total / meetings_with_term.get(w).copied().unwrap_or(1).max(1) as f64).ln()
            })
            .sum()
    };
    let meeting_weights: HashMap<usize, f64> = coverage
        .iter()
        .map(|(meeting, words)| (*meeting, weight(&mut words.iter())))
        .collect();
    let complete: HashSet<usize> = if require_all_words {
        coverage
            .iter()
            .filter(|(_, words)| words.len() == terms.len())
            .map(|(meeting, _)| *meeting)
            .collect()
    } else {
        HashSet::new()
    };
    let mut ranked: Vec<(Candidate, f64)> = candidates
        .into_iter()
        .filter(|c| complete.is_empty() || complete.contains(&c.meeting))
        .map(|c| {
            let score = weight(&mut c.matched.iter());
            (c, score)
        })
        .collect();
    ranked.sort_by(|(l, ls), (r, rs)| {
        r.exact
            .cmp(&l.exact)
            .then_with(|| {
                let left = meeting_weights.get(&l.meeting).copied().unwrap_or(0.0);
                let right = meeting_weights.get(&r.meeting).copied().unwrap_or(0.0);
                right
                    .partial_cmp(&left)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| rs.partial_cmp(ls).unwrap_or(std::cmp::Ordering::Equal))
            .then(l.meeting.cmp(&r.meeting))
            .then(l.kind.cmp(&r.kind))
            .then(l.position.cmp(&r.position))
    });

    let mut transcript_hits: HashMap<usize, usize> = HashMap::new();
    let mut out = Vec::new();
    for (candidate, _) in ranked {
        if out.len() >= limit {
            break;
        }
        if candidate.kind == 2
            && let Some(cap) = transcript_hits_per_meeting
        {
            let count = transcript_hits.entry(candidate.meeting).or_default();
            if *count >= cap {
                continue;
            }
            *count += 1;
        }
        out.push(candidate.hit);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terms_drop_single_letters() {
        assert_eq!(search_terms("don t panic"), ["don", "panic"]);
        assert_eq!(search_terms("q"), ["q"]);
        assert_eq!(search_terms("redis redis cache"), ["redis", "cache"]);
    }

    #[test]
    fn short_terms_match_whole_words_only() {
        assert!(word_range("api", "the api works").is_some());
        assert!(word_range("api", "rapid growth").is_none());
        assert!(word_range("q3", "q3 roadmap").is_some());
        assert!(word_range("road", "q3 roadmap").is_some());
    }

    #[test]
    fn snippets_fold_case_and_accents() {
        let text = format!(
            "{}Izveštaj o radu je spreman{}",
            "x".repeat(50),
            "y".repeat(50)
        );
        let cut = snippet(&text, "izvestaj").unwrap();
        assert!(cut.starts_with('…') && cut.ends_with('…'));
        assert!(cut.contains("Izveštaj"));
        assert_eq!(
            snippet("Short CAFÉ note", "cafe").as_deref(),
            Some("Short CAFÉ note")
        );
    }
}
