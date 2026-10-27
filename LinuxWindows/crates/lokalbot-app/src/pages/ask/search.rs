//! Keyword results for Ask and Quick Recall (`RecallSearch`): meeting hits
//! grouped by meeting, then screen moments. Runs on a background thread.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use lokalbot_core::search::{DocKind, SearchQuery};
use lokalbot_core::{Library, Meeting, ScreenMoment};
use uuid::Uuid;

/// One matching document in a meeting.
#[derive(Clone, Debug, PartialEq)]
pub struct Hit {
    pub kind: DocKind,
    /// Transcript time for segment hits.
    pub start: Option<f64>,
    pub speaker: Option<String>,
    /// Snippet with «matched» words.
    pub snippet: String,
}

impl Hit {
    /// "Title", "Summary", "Your notes", "Outcome" or "▶ 00:12:04 · Maya".
    pub fn kind_label(&self) -> String {
        match self.kind {
            DocKind::Title => lokalbot_i18n::tr("Title").into(),
            DocKind::Summary => lokalbot_i18n::tr("Summary").into(),
            DocKind::Notes => lokalbot_i18n::tr("Your notes").into(),
            DocKind::Outcome => lokalbot_i18n::tr("Outcome").into(),
            DocKind::Segment => {
                let stamp = lokalbot_core::time::stamp(self.start.unwrap_or(0.0));
                match self
                    .speaker
                    .as_deref()
                    .map(speaker_label)
                    .filter(|s| !s.is_empty())
                {
                    Some(speaker) => lokalbot_i18n::format(
                        "▶ {stamp} · {speaker}",
                        &[
                            ("stamp", stamp.to_string()),
                            ("speaker", speaker.to_string()),
                        ],
                    ),
                    None => format!("▶ {stamp}"),
                }
            }
        }
    }

    /// Quick Recall's kind word: "Transcript", "Your notes", "Summary".
    pub fn recall_kind(&self) -> &'static str {
        match self.kind {
            DocKind::Segment => lokalbot_i18n::tr("Transcript"),
            DocKind::Notes => lokalbot_i18n::tr("Your notes"),
            DocKind::Title => lokalbot_i18n::tr("Title"),
            DocKind::Summary => lokalbot_i18n::tr("Summary"),
            DocKind::Outcome => lokalbot_i18n::tr("Outcome"),
        }
    }

    /// Where opening this hit lands: a transcript moment, or `None` for the summary.
    pub fn moment(&self) -> Option<f64> {
        (self.kind == DocKind::Segment).then(|| self.start.unwrap_or(0.0))
    }
}

/// All matches in one meeting; `hits[0]` is the best one.
#[derive(Clone, Debug, PartialEq)]
pub struct MeetingGroup {
    pub meeting: Meeting,
    pub hits: Vec<Hit>,
}

/// A screen moment and how many similar captures it stands for.
#[derive(Clone, Debug, PartialEq)]
pub struct ScreenResult {
    pub moment: ScreenMoment,
    pub snippet: String,
    pub captures: usize,
}

/// Result-type filter (`AskFacet`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Facet {
    #[default]
    All,
    Transcripts,
    Summaries,
    Notes,
    Outcomes,
    Screen,
}

impl Facet {
    pub const ALL: [Facet; 6] = [
        Facet::All,
        Facet::Transcripts,
        Facet::Summaries,
        Facet::Notes,
        Facet::Outcomes,
        Facet::Screen,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Facet::All => lokalbot_i18n::tr("All"),
            Facet::Transcripts => lokalbot_i18n::tr("Transcripts"),
            Facet::Summaries => lokalbot_i18n::tr("Summaries"),
            Facet::Notes => lokalbot_i18n::tr("Notes"),
            Facet::Outcomes => lokalbot_i18n::tr("Outcomes"),
            Facet::Screen => lokalbot_i18n::tr("Screen"),
        }
    }

    fn kinds(self) -> Option<Vec<DocKind>> {
        match self {
            Facet::All | Facet::Screen => None,
            Facet::Transcripts => Some(vec![DocKind::Segment]),
            Facet::Summaries => Some(vec![DocKind::Summary]),
            Facet::Notes => Some(vec![DocKind::Notes]),
            Facet::Outcomes => Some(vec![DocKind::Outcome]),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Query {
    pub text: String,
    pub facet: Facet,
    pub meetings: bool,
    pub screen: bool,
    pub meeting_ids: Option<Vec<Uuid>>,
    pub since: Option<DateTime<Utc>>,
    pub until: Option<DateTime<Utc>>,
    /// Maximum meeting groups and screen moments.
    pub limit: usize,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Results {
    pub meetings: Vec<MeetingGroup>,
    pub screens: Vec<ScreenResult>,
    /// More meetings matched than `limit`.
    pub truncated: bool,
}

/// Libraries whose stale search documents were brought up to date this run.
static INDEXED: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

/// Indexes meetings whose files changed since they were last indexed, once
/// per library and run, so a fresh or imported library is searchable.
fn ensure_indexed(library: &Library) {
    let root = library.paths().root().to_path_buf();
    let Ok(mut indexed) = INDEXED.lock() else {
        return;
    };
    if indexed.contains(&root) || library.is_read_only() {
        return;
    }
    match library.reindex_stale() {
        Ok(count) if count > 0 => log::info!("search: indexed {count} meetings"),
        Ok(_) => {}
        Err(err) => log::warn!("search: reindexing failed: {err:#}"),
    }
    indexed.push(root);
}

pub fn run(library: &Library, meetings: &[Meeting], query: &Query) -> Results {
    let text = query.text.trim();
    let mut results = Results::default();
    if text.is_empty() {
        return results;
    }
    if query.meetings && query.facet != Facet::Screen {
        ensure_indexed(library);
        let search = SearchQuery {
            text: text.to_string(),
            kinds: query.facet.kinds(),
            meeting_ids: query.meeting_ids.clone(),
            since: query.since,
            until: query.until,
            limit: 300,
        };
        match library.search(&search) {
            Ok(hits) => {
                let mut order: Vec<Uuid> = Vec::new();
                let mut seen: HashSet<Uuid> = HashSet::new();
                let mut grouped: HashMap<Uuid, Vec<Hit>> = HashMap::new();
                for hit in hits {
                    if seen.insert(hit.meeting_id) {
                        order.push(hit.meeting_id);
                    }
                    grouped.entry(hit.meeting_id).or_default().push(Hit {
                        kind: hit.kind,
                        start: hit.start,
                        speaker: hit.speaker,
                        snippet: hit.snippet,
                    });
                }
                for id in order {
                    let Some(meeting) = meetings.iter().find(|m| m.id == id) else {
                        continue;
                    };
                    let hits = grouped.remove(&id).unwrap_or_default();
                    results.meetings.push(MeetingGroup {
                        meeting: meeting.clone(),
                        hits,
                    });
                }
            }
            Err(err) => log::warn!("search failed: {err:#}"),
        }
        if query.limit > 0 && results.meetings.len() > query.limit {
            results.meetings.truncate(query.limit);
            results.truncated = true;
        }
    }
    let screen_facet = matches!(query.facet, Facet::All | Facet::Screen);
    if query.screen && screen_facet && query.meeting_ids.is_none() {
        match library.search_screen_hits(text, None, None, query.limit.max(1)) {
            Ok(hits) => {
                results.screens = hits
                    .into_iter()
                    .filter(|hit| query.since.is_none_or(|since| hit.moment.ts >= since))
                    .filter(|hit| query.until.is_none_or(|until| hit.moment.ts < until))
                    .map(|hit| ScreenResult {
                        moment: hit.moment,
                        snippet: hit.snippet,
                        captures: hit.capture_count,
                    })
                    .collect();
            }
            Err(err) => log::warn!("screen search failed: {err:#}"),
        }
    }
    results
}

/// `SpeakerDisplayName.label`: "Them" reads as "Other speaker", "Them 2" as "Speaker 2".
pub fn speaker_label(name: &str) -> String {
    let trimmed = name.trim();
    let lower = trimmed.to_lowercase();
    if lower == "them" {
        return lokalbot_i18n::tr("Other speaker").into();
    }
    if let Some(number) = lower.strip_prefix("them ")
        && !number.is_empty()
        && number.bytes().all(|b| b.is_ascii_digit())
    {
        return lokalbot_i18n::format("Speaker {number}", &[("number", number.to_string())]);
    }
    trimmed.to_string()
}

/// Questions go to the assistant on Return (`AskIntent.isQuestion`).
pub fn is_question(query: &str) -> bool {
    const STARTS: &[&str] = &[
        "what",
        "why",
        "how",
        "when",
        "where",
        "who",
        "whom",
        "whose",
        "which",
        "did",
        "do",
        "does",
        "is",
        "are",
        "was",
        "were",
        "can",
        "could",
        "should",
        "would",
        "will",
        "has",
        "have",
        "had",
        "summarize",
        "summarise",
        "explain",
        "list",
        "tell",
        "compare",
        "remind",
        "draft",
    ];
    let words: Vec<&str> = query.split_whitespace().collect();
    let Some(first) = words.first() else {
        return false;
    };
    if query.trim().ends_with('?') {
        return words.len() >= 2;
    }
    let lead = first
        .trim_matches(|c: char| c.is_ascii_punctuation())
        .to_lowercase();
    words.len() >= 3 && STARTS.contains(&lead.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn question_detection_matches_the_mac() {
        assert!(is_question("What did we decide about Redis?"));
        assert!(is_question("redis status?"));
        assert!(is_question("list my recent meetings"));
        assert!(!is_question("redis cluster"));
        assert!(!is_question("what?"));
    }

    #[test]
    fn speaker_labels() {
        assert_eq!(speaker_label("Them"), "Other speaker");
        assert_eq!(speaker_label("them 2"), "Speaker 2");
        assert_eq!(speaker_label("Maya"), "Maya");
    }

    #[test]
    fn searches_the_demo_library() {
        let dir =
            std::env::temp_dir().join(format!("lokalbot-ui-b-search-{}", Uuid::new_v4().simple()));
        let paths = lokalbot_core::LibraryPaths::new(&dir);
        lokalbot_core::demo::seed(&paths, Utc::now()).unwrap();
        let library = Library::open(paths).unwrap();
        let meetings = library.list_meetings().unwrap();
        let query = Query {
            text: "captions".into(),
            meetings: true,
            screen: true,
            limit: 50,
            ..Default::default()
        };
        let results = run(&library, &meetings, &query);
        // Windows can't delete the database while the library holds it open.
        drop(library);
        let _ = std::fs::remove_dir_all(&dir);
        assert!(!results.meetings.is_empty(), "meeting hits for captions");
        assert!(results.meetings[0].hits[0].snippet.contains('«'));
    }
}
