use std::path::Path;

use chrono::{Duration, TimeZone as _, Utc};
use lokalbot_core::{LibraryPaths, Meeting, Segment, Transcript, ids::fold, library::write_json};

use super::prefilter::tests::{Random, json_string, tricky_text};
use super::*;

fn old_hits(
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
        .map(|(meeting, words)| {
            let mut matched = terms.iter().filter(|t| words.contains(*t));
            (*meeting, weight(&mut matched))
        })
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

const WORDS: &[&str] = &[
    "Izveštaj",
    "IZVESTAJ",
    "izvestaj",
    "café",
    "CAFE",
    "cafe\u{301}",
    "naïve",
    "API",
    "api",
    "rapid",
    "API-key",
    "q3",
    "Q3",
    "roadmap",
    "road",
    "東京会議",
    "会议",
    "会",
    "Σοφία",
    "ΟΔΟΣ",
    "οδός",
    "οδος",
    "Straße",
    "STRASSE",
    "İstanbul",
    "istanbul",
    "budžet",
    "budzet",
    "Đorđe",
    "djordje",
    "the",
    "then",
    "theme",
    "a",
    "I",
    "x",
    "ok",
    "OK",
    "o.k.",
    "e-mail",
    "email",
    "\"quoted\"",
    "back\\slash",
    "a/b",
    "😀",
    "한국",
    "한",
    "ｱｲｳ",
    "ア",
    "telescope",
    "checksum",
];
const GAPS: &[&str] = &[
    " ", " ", " ", "  ", "\n", ", ", ". ", "-", "", "\t", "/", "\u{a0}", " \u{301}",
];

fn sentence(random: &mut Random) -> String {
    let mut text = String::new();
    for index in 0..random.below(8) + 1 {
        if index > 0 {
            text.push_str(random.pick(GAPS));
        }
        if random.below(6) == 0 {
            text.push_str(&tricky_text(random, 3));
        } else {
            text.push_str(random.pick(WORDS));
        }
    }
    text
}

fn library(random: &mut Random, root: &Path) -> Vec<String> {
    let paths = LibraryPaths::new(root);
    let start = Utc.with_ymd_and_hms(2026, 11, 1, 9, 0, 0).unwrap();
    let mut texts = Vec::new();
    for index in 0..random.below(8) + 1 {
        let started = start - Duration::hours(6 * index as i64);
        let relative = format!("meetings/2026/11/{index:02}-meeting");
        let title = sentence(random);
        let mut meeting = Meeting::new(&title, "Zoom", started, &relative);
        meeting.ended_at = Some(started + Duration::minutes(30));
        if random.below(8) == 0 {
            meeting.sample_id = Some("sample".into());
        }
        texts.push(title);
        let folder = paths.meeting_dir(&relative);
        std::fs::create_dir_all(&folder).unwrap();
        write_json(&folder.join("meta.json"), &meeting).unwrap();
        if random.below(3) > 0 {
            let lines: Vec<String> = (0..random.below(4) + 1).map(|_| sentence(random)).collect();
            let summary = lines.join("\n");
            std::fs::write(folder.join("summary.md"), &summary).unwrap();
            texts.push(summary);
        }
        let segments: Vec<Segment> = (0..random.below(12))
            .map(|position| Segment {
                start: position as f64 * 7.5,
                end: position as f64 * 7.5 + 7.0,
                speaker: "them".into(),
                text: sentence(random),
                confidence: None,
                timing_precision: None,
                attribution: None,
            })
            .collect();
        texts.extend(segments.iter().map(|s| s.text.clone()));
        let transcript = Transcript {
            segments,
            ..Default::default()
        };
        let path = folder.join("transcript.json");
        match random.below(8) {
            0 => {}
            1 | 2 => {
                let segments: Vec<String> = transcript
                    .segments
                    .iter()
                    .map(|s| {
                        format!(
                            "{{\"end\":{},\"speaker\":\"them\",\"start\":{},\"text\":{}}}",
                            s.end,
                            s.start,
                            json_string(random, &s.text)
                        )
                    })
                    .collect();
                let json = format!("{{\"engine\":\"\",\"segments\":[{}]}}", segments.join(","));
                std::fs::write(&path, json).unwrap();
            }
            3 => std::fs::write(&path, "{\"segments\": [{\"text\": \"the api").unwrap(),
            4 => {
                write_json(&path, &transcript).unwrap();
                let json = std::fs::read_to_string(&path).unwrap();
                let bytes: Vec<u8> = if random.below(2) == 0 {
                    json.encode_utf16().flat_map(u16::to_le_bytes).collect()
                } else {
                    format!("\u{feff}{json}").into_bytes()
                };
                std::fs::write(&path, bytes).unwrap();
            }
            _ => write_json(&path, &transcript).unwrap(),
        }
    }
    texts
}

fn piece(random: &mut Random, texts: &[String]) -> String {
    let chars: Vec<char> = random.pick(texts).chars().collect();
    if chars.is_empty() {
        return "x".into();
    }
    let start = random.below(chars.len());
    let end = (start + 1 + random.below(12)).min(chars.len());
    chars[start..end].iter().collect()
}

fn query(random: &mut Random, texts: &[String]) -> String {
    match random.below(8) {
        0 => format!("\"{}\"", piece(random, texts)),
        1 => format!("\"{}\"", sentence(random)),
        2 => piece(random, texts),
        3 => tricky_text(random, 4),
        4 => random
            .pick(&[
                "a", "x", "ok", "i", "q", "...", "\"\"\"", "\"ab\"", "  the  ", "Q3 road",
            ])
            .to_string(),
        _ => (0..random.below(3) + 1)
            .map(|_| *random.pick(WORDS))
            .collect::<Vec<_>>()
            .join(" "),
    }
}

fn assert_same_hits(session: &Session, meetings: &[Meeting], query: &str) -> bool {
    let ask = crate::ask::search_terms(query).join(" ");
    let mut found = false;
    for (query, limit, cap, all) in [
        (
            query,
            MAXIMUM_SEARCH_HITS,
            Some(MAXIMUM_TRANSCRIPT_HITS_PER_MEETING),
            true,
        ),
        (query, 3, Some(1), true),
        (query, MAXIMUM_SEARCH_HITS, None, false),
        (ask.as_str(), MAXIMUM_SEARCH_HITS, None, false),
    ] {
        let expected = old_hits(session, query, limit, meetings, cap, all);
        let actual = hits(session, query, limit, meetings, cap, all);
        assert_eq!(
            actual, expected,
            "{query:?} limit {limit} cap {cap:?} all {all}"
        );
        found |= !expected.is_empty();
    }
    found
}

#[test]
fn hits_match_the_old_search_on_random_libraries() {
    let mut random = Random(7);
    let (mut queries, mut found) = (0, 0);
    for _ in 0..80 {
        let dir = tempfile::tempdir().unwrap();
        let texts = library(&mut random, dir.path());
        let session = Session::open(LibraryPaths::new(dir.path())).unwrap();
        let meetings = session.meetings().unwrap();
        for _ in 0..50 {
            let query = query(&mut random, &texts);
            queries += 1;
            found += usize::from(assert_same_hits(&session, &meetings, &query));
        }
    }
    assert!(found * 2 > queries, "{found} of {queries}");
}

#[test]
fn hits_match_the_old_search_on_the_macos_fixture() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../LokalBotTests/Fixtures/upgrade/0.10.9/library");
    if !fixture.is_dir() {
        return;
    }
    fn copy_dir(from: &Path, to: &Path) {
        std::fs::create_dir_all(to).unwrap();
        for entry in std::fs::read_dir(from).unwrap().flatten() {
            let target = to.join(entry.file_name());
            if entry.path().is_dir() {
                copy_dir(&entry.path(), &target);
            } else {
                std::fs::copy(entry.path(), target).unwrap();
            }
        }
    }
    let dir = tempfile::tempdir().unwrap();
    copy_dir(&fixture, dir.path());
    let session = Session::open(LibraryPaths::new(dir.path())).unwrap();
    let meetings = session.meetings().unwrap();
    let mut texts: Vec<String> = meetings.iter().map(|m| m.title.clone()).collect();
    for meeting in &meetings {
        texts.extend(session.summary(meeting));
        if let Some(transcript) = session.transcript(meeting) {
            texts.extend(transcript.segments.into_iter().map(|s| s.text));
        }
    }
    assert!(texts.len() > 20);
    let mut random = Random(8);
    let mut found = 0;
    for query in ["Redis", "redis cache", "\"the\"", "q3", "a"] {
        found += usize::from(assert_same_hits(&session, &meetings, query));
    }
    for _ in 0..300 {
        let query = match random.below(3) {
            0 => format!("\"{}\"", piece(&mut random, &texts)),
            1 => piece(&mut random, &texts),
            _ => fold(&piece(&mut random, &texts)),
        };
        found += usize::from(assert_same_hits(&session, &meetings, &query));
    }
    assert!(found > 150, "{found}");
}

#[test]
fn meetings_that_match_the_same_words_keep_recency_on_every_run() {
    let words = [
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
    ];
    let dir = tempfile::tempdir().unwrap();
    let paths = LibraryPaths::new(dir.path());
    let start = Utc.with_ymd_and_hms(2026, 11, 1, 9, 0, 0).unwrap();
    for index in 0..9 {
        let title = words[index.max(1) - 1..].join(" ");
        let relative = format!("meetings/2026/11/{index:02}-meeting");
        let started = start - Duration::hours(index as i64);
        let meeting = Meeting::new(&title, "Zoom", started, &relative);
        let folder = paths.meeting_dir(&relative);
        std::fs::create_dir_all(&folder).unwrap();
        write_json(&folder.join("meta.json"), &meeting).unwrap();
    }
    let session = Session::open(paths).unwrap();
    let meetings = session.meetings().unwrap();
    let query = words.join(" ");
    let first = hits(&session, &query, 500, &meetings, Some(5), true);
    assert_eq!(first.len(), 2);
    assert_eq!(first[0].meeting_id, short_id(&meetings[0]));
    for _ in 0..200 {
        assert_eq!(hits(&session, &query, 500, &meetings, Some(5), true), first);
    }
}
