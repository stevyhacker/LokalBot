//! Results for Ask and Quick Recall (`RecallSearch`): meeting hits grouped by
//! meeting, then screen moments. Words first; for Ask, meaning is then fused in at
//! the level of meetings. Runs on a background thread.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use lokalbot_core::agent_notes::{NoteHit, NotesIndex};
use lokalbot_core::embeddings::{MEETING_SIMILARITY_FLOOR, RRF_K};
use lokalbot_core::files::FileHit;
use lokalbot_core::files::search::{FileInterval, FileReader};
use lokalbot_core::screen_search::{self, ScreenFilter};
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
    /// Found by meaning, without the query's words.
    pub is_semantic: bool,
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

/// Meetings, or screen sources, that Ask lists for one search (`displayLimit`).
pub const DISPLAY_LIMIT: usize = 40;
/// Passages by meaning read for one search (`EmbeddingIndex.search`'s limit here).
const SEMANTIC_PASSAGES: usize = 200;
/// Keyword rows read for one search, before grouping.
const KEYWORD_ROWS: usize = 2_000;

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
    /// Found by meaning, without the query's words.
    pub is_semantic: bool,
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
    Files,
    AgentNotes,
}

impl Facet {
    pub const ALL: [Facet; 8] = [
        Facet::All,
        Facet::Transcripts,
        Facet::Summaries,
        Facet::Notes,
        Facet::Outcomes,
        Facet::Screen,
        Facet::Files,
        Facet::AgentNotes,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Facet::All => lokalbot_i18n::tr("All"),
            Facet::Transcripts => lokalbot_i18n::tr("Transcripts"),
            Facet::Summaries => lokalbot_i18n::tr("Summaries"),
            Facet::Notes => lokalbot_i18n::tr("Notes"),
            Facet::Outcomes => lokalbot_i18n::tr("Outcomes"),
            Facet::Screen => lokalbot_i18n::tr("Screen"),
            Facet::Files => lokalbot_i18n::tr("Files"),
            Facet::AgentNotes => lokalbot_i18n::tr("Agent notes"),
        }
    }

    fn kinds(self) -> Option<Vec<DocKind>> {
        match self {
            Facet::All | Facet::Screen | Facet::Files | Facet::AgentNotes => None,
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
    /// The folders chosen under Files; empty while Files is off.
    pub file_folders: Vec<String>,
    /// Saved coding-agent notes are searched: the source is chosen and Read
    /// coding agent notes is on.
    pub agent_notes: bool,
    /// Limit screen results to one app.
    pub screen_app: Option<String>,
    pub screen_ids: Option<Vec<i64>>,
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
    pub files: Vec<FileHit>,
    /// Notes the person's coding agents saved, matched by their words.
    pub notes: Vec<NoteHit>,
    /// More meetings or notes matched than `limit`.
    pub truncated: bool,
}

impl Query {
    fn searches_screens(&self) -> bool {
        self.screen
            && matches!(self.facet, Facet::All | Facet::Screen)
            && (self.meeting_ids.is_none() || self.screen_ids.is_some())
    }

    fn searches_files(&self) -> bool {
        !self.file_folders.is_empty() && matches!(self.facet, Facet::All | Facet::Files)
    }

    fn searches_notes(&self) -> bool {
        self.agent_notes && matches!(self.facet, Facet::All | Facet::AgentNotes)
    }

    fn screen_filter(&self) -> ScreenFilter {
        ScreenFilter {
            since: self.since,
            until: self.until,
            app: self.screen_app.clone(),
            snapshot_ids: self
                .screen_ids
                .as_ref()
                .map(|ids| ids.iter().copied().collect()),
        }
    }

    fn file_interval(&self) -> FileInterval {
        FileInterval {
            since: self.since,
            until: self.until,
        }
    }

    /// Keyword hits for every kind of document can be fused with meaning. A facet
    /// asks for one kind, and a meaning match can't say it's of that kind.
    fn searches_meeting_meaning(&self) -> bool {
        self.meetings && self.facet == Facet::All
    }

    /// Meaning adds something where meetings, screens or files are searched.
    pub fn wants_meaning(&self) -> bool {
        self.searches_meeting_meaning() || self.searches_screens() || self.searches_files()
    }

    /// The meetings this search may read: an evidence boundary and a date scope.
    fn meeting_scope(&self, meetings: &[Meeting]) -> Option<HashSet<Uuid>> {
        let dated = self.since.is_some() || self.until.is_some();
        if self.meeting_ids.is_none() && !dated {
            return None;
        }
        Some(
            meetings
                .iter()
                .filter(|meeting| {
                    self.meeting_ids
                        .as_ref()
                        .is_none_or(|ids| ids.contains(&meeting.id))
                        && self.since.is_none_or(|since| meeting.started_at >= since)
                        && self.until.is_none_or(|until| meeting.started_at < until)
                })
                .map(|meeting| meeting.id)
                .collect(),
        )
    }
}

/// The apps the listed screens came from, for the screen-app filter.
pub fn screen_apps(screens: &[ScreenResult], selected: Option<&str>) -> Vec<String> {
    let mut apps: Vec<String> = screens
        .iter()
        .map(|screen| screen.moment.app.clone())
        .chain(selected.map(str::to_string))
        .collect();
    apps.sort();
    apps.dedup();
    apps
}

fn screen_result(hit: lokalbot_core::search::ScreenHit, is_semantic: bool) -> ScreenResult {
    ScreenResult {
        moment: hit.moment,
        snippet: hit.snippet,
        captures: hit.capture_count,
        is_semantic,
    }
}

/// Saved moments whose note or window title holds the query, among the hits as
/// their own results (`keywordScreens`): a note is searched even with no text.
fn saved_matches(
    saved: &[ScreenMoment],
    found: &[lokalbot_core::search::ScreenHit],
    filter: &lokalbot_core::screen_search::ScreenFilter,
    query: &str,
) -> Vec<lokalbot_core::search::ScreenHit> {
    let wanted = query.to_lowercase();
    saved
        .iter()
        .filter(|moment| !found.iter().any(|hit| hit.moment.id == moment.id))
        .filter(|moment| filter.contains(moment.id, moment.ts, &moment.app))
        .filter(|moment| {
            let note = moment.saved_note.as_deref().unwrap_or_default();
            note.to_lowercase().contains(&wanted)
                || moment.window_title.to_lowercase().contains(&wanted)
        })
        .map(|moment| lokalbot_core::search::ScreenHit {
            moment: moment.clone(),
            snippet: moment.saved_note.clone().unwrap_or_default(),
            rank: 0.0,
            capture_count: 1,
        })
        .collect()
}

/// `QuickRecallRowModel.screens` with a query: saved moments lead, in the order
/// they were saved, then the other hits. A match by meaning alone isn't a saved
/// match, and a saved moment keeps its place in the rest. Without a query the
/// list is just the latest saved moments.
pub fn screens_with_saved_first(
    screens: &[ScreenResult],
    saved: &[ScreenMoment],
) -> Vec<ScreenResult> {
    let mut rows: Vec<ScreenResult> = saved
        .iter()
        .filter_map(|moment| {
            screens
                .iter()
                .find(|screen| screen.moment.id == moment.id && !screen.is_semantic)
                .map(|screen| ScreenResult {
                    moment: moment.clone(),
                    ..screen.clone()
                })
        })
        .collect();
    let leading: HashSet<i64> = rows.iter().map(|row| row.moment.id).collect();
    rows.extend(
        screens
            .iter()
            .filter(|screen| !leading.contains(&screen.moment.id))
            .cloned(),
    );
    rows
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
    if query.meetings
        && !matches!(
            query.facet,
            Facet::Screen | Facet::Files | Facet::AgentNotes
        )
    {
        ensure_indexed(library);
        let search = SearchQuery {
            text: text.to_string(),
            kinds: query.facet.kinds(),
            meeting_ids: query.meeting_ids.clone(),
            since: query.since,
            until: query.until,
            limit: KEYWORD_ROWS,
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
                        is_semantic: false,
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
    if query.searches_screens() {
        match library.keyword_screen_hits(text, &query.screen_filter(), query.limit.max(1)) {
            Ok((mut hits, _)) => {
                let saved = library.saved_moments().unwrap_or_default();
                hits.extend(saved_matches(&saved, &hits, &query.screen_filter(), text));
                results.screens = hits
                    .into_iter()
                    .map(|hit| screen_result(hit, false))
                    .collect();
            }
            Err(err) => log::warn!("screen search failed: {err:#}"),
        }
    }
    // Files match words first; the query vector adds meaning in `refine`.
    if query.searches_files() {
        results.files = FileReader::shared(library.paths().root()).search(
            text,
            None,
            &query.file_folders,
            query.file_interval(),
            query.limit.max(1),
        );
    }
    if query.searches_notes() {
        let (notes, truncated) = note_hits(library, query, text);
        results.notes = notes;
        results.truncated |= truncated;
    }
    results
}

/// Saved coding-agent notes matching the query's words, and whether more
/// matched than are listed. A date scope keeps the notes last changed inside
/// it. Notes have no vectors, so meaning never changes this list.
fn note_hits(library: &Library, query: &Query, text: &str) -> (Vec<NoteHit>, bool) {
    let limit = query.limit.max(1);
    let dated = query.since.is_some() || query.until.is_some();
    let found = NotesIndex::new(library.paths().root())
        .search(text, None, if dated { 400 } else { limit + 1 })
        .unwrap_or_else(|err| {
            log::warn!("agent notes search failed: {err:#}");
            Vec::new()
        });
    let mut notes: Vec<NoteHit> = found
        .into_iter()
        .filter(|hit| {
            query.since.is_none_or(|since| hit.modified >= since)
                && query.until.is_none_or(|until| hit.modified < until)
        })
        .collect();
    let truncated = notes.len() > limit;
    notes.truncate(limit);
    (notes, truncated)
}

/// What a note row shows under its title: the matched words, or the agent's
/// own description, or where the note is.
pub fn note_snippet(hit: &NoteHit) -> String {
    if !hit.snippet.trim().is_empty() {
        return hit.snippet.clone();
    }
    hit.summary.clone().unwrap_or_else(|| hit.path.clone())
}

/// Opens the agent's own file for a note in its default app. LokalBot keeps a
/// copy for search only and never edits the file.
pub fn open_note(hit: &NoteHit) {
    let path = std::path::Path::new(&hit.path);
    if !path.exists() {
        log::info!("the agent's note is no longer on disk");
        return;
    }
    if let Err(err) = lokalbot_platform::opener::open_path(path) {
        log::warn!("could not open the agent's note: {err:#}");
    }
}

/// Screens and files again, with the query's vector: text and picture vectors on
/// one scale, ranked with the keyword hits. With no vectors yet the keyword results
/// stay. The first search by meaning is what starts their backfill.
pub fn refine(library: &Library, query: &Query, vector: &[f32], results: &mut Results) {
    let text = query.text.trim();
    if query.searches_screens() {
        screen_search::note_searched_by_meaning(library.paths().root());
        let filter = query.screen_filter();
        let meanings = library
            .screen_meanings(
                vector,
                &lokalbot_ai::media_embedder::picture_model_id(),
                &filter,
            )
            .unwrap_or_else(|err| {
                log::warn!("screen meaning search failed: {err:#}");
                Default::default()
            });
        if !meanings.is_empty()
            && let Ok((keyword, matched_all)) =
                library.keyword_screen_hits(text, &filter, query.limit.max(1))
        {
            let shares = library.screen_coverage(text, &keyword, matched_all);
            results.screens = library
                .ranked_screen_hits(text, keyword, &shares, &meanings, query.limit.max(1))
                .into_iter()
                .map(|(hit, is_semantic)| screen_result(hit, is_semantic))
                .collect();
        }
    }
    if query.searches_files() {
        results.files = FileReader::shared(library.paths().root()).search(
            text,
            Some(vector),
            &query.file_folders,
            query.file_interval(),
            query.limit.max(1),
        );
    }
}

/// Ask's meetings again, with passages found by meaning fused in (`fusedMeetings`).
/// With no vectors yet the keyword results stay.
pub fn fuse_meetings(
    library: &Library,
    meetings: &[Meeting],
    query: &Query,
    vector: &[f32],
    results: &mut Results,
) {
    if !query.searches_meeting_meaning() {
        return;
    }
    let text = query.text.trim();
    let scope = query.meeting_scope(meetings);
    let found = library
        .semantic_search_in(
            vector,
            SEMANTIC_PASSAGES,
            MEETING_SIMILARITY_FLOOR,
            scope.as_ref(),
        )
        .unwrap_or_else(|err| {
            log::warn!("meeting meaning search failed: {err:#}");
            Vec::new()
        });
    let mut semantic: Vec<(Uuid, Hit)> = Vec::new();
    for (meeting_id, start, passage, _) in found {
        match library.semantic_passage(meeting_id, start, &passage, text) {
            Ok(Some(hit)) => semantic.push((
                meeting_id,
                Hit {
                    kind: hit.kind,
                    start: hit.start,
                    speaker: hit.speaker,
                    snippet: hit.snippet,
                    is_semantic: true,
                },
            )),
            Ok(None) => {}
            Err(err) => log::warn!("reading a passage failed: {err:#}"),
        }
    }
    if semantic.is_empty() {
        return;
    }
    let limit = if query.limit > 0 {
        query.limit
    } else {
        usize::MAX
    };
    let keyword = std::mem::take(&mut results.meetings);
    let (fused, truncated) = fused_meetings(keyword, semantic, meetings, limit);
    results.meetings = fused;
    results.truncated |= truncated;
}

/// The order of one ranked list: each meeting once, at its first appearance.
fn first_appearances(ids: impl Iterator<Item = Uuid>) -> Vec<Uuid> {
    let mut seen = HashSet::new();
    ids.filter(|id| seen.insert(*id)).collect()
}

/// Fuses at the level of meetings, so a meeting with many keyword rows can't bury
/// a relevant one found by meaning alone. Keyword snippets stay, and one passage
/// found both ways is listed once. Says whether more meetings matched than `limit`.
fn fused_meetings(
    keyword: Vec<MeetingGroup>,
    semantic: Vec<(Uuid, Hit)>,
    meetings: &[Meeting],
    limit: usize,
) -> (Vec<MeetingGroup>, bool) {
    let known: HashMap<Uuid, &Meeting> = meetings.iter().map(|m| (m.id, m)).collect();
    let semantic: Vec<(Uuid, Hit)> = semantic
        .into_iter()
        .filter(|(id, _)| known.contains_key(id))
        .collect();
    let lexical: Vec<Uuid> = keyword.iter().map(|group| group.meeting.id).collect();
    let conceptual = first_appearances(semantic.iter().map(|(id, _)| *id));
    let mut scores: HashMap<Uuid, f64> = HashMap::new();
    let mut first_ranks: HashMap<Uuid, usize> = HashMap::new();
    for list in [&lexical, &conceptual] {
        for (rank, id) in list.iter().enumerate() {
            *scores.entry(*id).or_default() += 1.0 / (RRF_K + (rank + 1) as f64);
            let first = first_ranks.entry(*id).or_insert(rank);
            *first = (*first).min(rank);
        }
    }
    let is_lexical: HashSet<Uuid> = lexical.iter().copied().collect();
    let mut order: Vec<Uuid> = scores.keys().copied().collect();
    order.sort_by(|a, b| {
        scores[b]
            .total_cmp(&scores[a])
            // Keyword evidence goes first only for equal relevance, never ahead
            // of a higher-ranked meeting found by meaning alone.
            .then_with(|| is_lexical.contains(b).cmp(&is_lexical.contains(a)))
            .then_with(|| first_ranks[a].cmp(&first_ranks[b]))
            .then_with(|| a.cmp(b))
    });
    let truncated = order.len() > limit;
    let mut groups: HashMap<Uuid, MeetingGroup> = keyword
        .into_iter()
        .map(|group| (group.meeting.id, group))
        .collect();
    let mut found: HashMap<Uuid, Vec<Hit>> = HashMap::new();
    for (id, hit) in semantic {
        found.entry(id).or_default().push(hit);
    }
    let fused = order
        .into_iter()
        .take(limit)
        .filter_map(|id| {
            let (meeting, mut hits) = match groups.remove(&id) {
                Some(group) => (group.meeting, group.hits),
                None => ((*known.get(&id)?).clone(), Vec::new()),
            };
            hits.extend(found.remove(&id).unwrap_or_default());
            let mut seen = HashSet::new();
            hits.retain(|hit| seen.insert((hit.kind, hit.start.unwrap_or(0.0).to_bits())));
            let best = primary(&hits);
            hits[..=best].rotate_right(1);
            Some(MeetingGroup { meeting, hits })
        })
        .collect();
    (fused, truncated)
}

/// `MeetingRecallGroup.primary`: a transcript passage matched by its words, else
/// any passage matched by its words, else the first one.
fn primary(hits: &[Hit]) -> usize {
    hits.iter()
        .position(|hit| !hit.is_semantic && hit.kind == DocKind::Segment)
        .or_else(|| hits.iter().position(|hit| !hit.is_semantic))
        .unwrap_or(0)
}

/// What kind of file a result is, at a glance. The Mac shows the file's own icon
/// from the system, which has no equivalent across Linux desktops and Windows here.
pub fn file_icon(kind: lokalbot_core::files::FileKind) -> crate::ui::Ico {
    use crate::ui::Ico;
    use lokalbot_core::files::FileKind;
    match kind {
        FileKind::Screenshot | FileKind::Image => Ico::FileImage,
        FileKind::Pdf | FileKind::Doc => Ico::FileText,
        FileKind::Audio => Ico::FileHeadphone,
        FileKind::Video => Ico::FileVideoCamera,
        FileKind::Code => Ico::FileCode,
    }
}

/// "PDF · page 3", "Recording · 00:01:15" in the interface's language.
pub fn file_kind_label(hit: &FileHit) -> String {
    use lokalbot_core::files::FileKind;
    let stamp = |seconds: f64| lokalbot_core::time::stamp(seconds).to_string();
    match hit.kind {
        FileKind::Screenshot => lokalbot_i18n::tr("Screenshot").into(),
        FileKind::Image => lokalbot_i18n::tr("Picture").into(),
        FileKind::Pdf => match hit.page {
            Some(page) => lokalbot_i18n::format("PDF · page {0}", &[("0", page.to_string())]),
            None => lokalbot_i18n::tr("PDF").into(),
        },
        FileKind::Doc => lokalbot_i18n::tr("Document").into(),
        FileKind::Audio => match hit.seconds {
            Some(at) => lokalbot_i18n::format("Recording · {0}", &[("0", stamp(at))]),
            None => lokalbot_i18n::tr("Recording").into(),
        },
        FileKind::Video => match hit.seconds {
            Some(at) => lokalbot_i18n::format("Video · {0}", &[("0", stamp(at))]),
            None => lokalbot_i18n::tr("Video").into(),
        },
        FileKind::Code => lokalbot_i18n::tr("Code").into(),
    }
}

/// Opens a file found by search in its default app. The Mac's own PDF window and
/// player, which open at the matched page or moment, aren't here.
pub fn open_file(hit: &FileHit) {
    if !std::path::Path::new(&hit.path).exists() {
        return;
    }
    if let Err(err) = lokalbot_platform::opener::open_path(std::path::Path::new(&hit.path)) {
        log::warn!("could not open a file: {err:#}");
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn moment(id: i64, note: Option<&str>, title: &str) -> ScreenMoment {
        ScreenMoment {
            id,
            ts: Utc::now(),
            app: "Mail".into(),
            window_title: title.into(),
            capture_trigger: String::new(),
            path: String::new(),
            source_url: String::new(),
            document_name: String::new(),
            meeting_id: None,
            privacy_redactions: 0,
            text: None,
            saved_note: note.map(str::to_string),
            is_saved: note.is_some(),
            similarity_group: 0,
        }
    }

    fn screen(id: i64, is_semantic: bool) -> ScreenResult {
        ScreenResult {
            moment: moment(id, None, "Inbox"),
            snippet: format!("snippet {id}"),
            captures: 1,
            is_semantic,
        }
    }

    #[test]
    fn saved_matches_lead_screens() {
        let saved = [
            moment(9, Some("Invoice"), "Billing"),
            moment(3, Some("Keynote"), "Slides"),
            moment(5, Some("Not found"), "Other"),
        ];
        let rows = screens_with_saved_first(
            &[
                screen(1, false),
                screen(3, false),
                screen(9, false),
                screen(7, true),
            ],
            &saved,
        );
        let ids: Vec<i64> = rows.iter().map(|row| row.moment.id).collect();
        assert_eq!(ids, [9, 3, 1, 7]);
        // It shows as saved, with what the search found in it.
        assert_eq!(rows[0].moment.saved_note.as_deref(), Some("Invoice"));
        assert_eq!(rows[0].snippet, "snippet 9");
        // Found only by meaning, a saved moment doesn't jump the queue.
        let rows = screens_with_saved_first(&[screen(1, false), screen(9, true)], &saved);
        let ids: Vec<i64> = rows.iter().map(|row| row.moment.id).collect();
        assert_eq!(ids, [1, 9]);
    }

    #[test]
    fn a_saved_note_or_title_matches_within_the_filter() {
        let saved = [
            moment(1, Some("Quarterly Invoice"), "Billing"),
            moment(2, Some("Keynote"), "Invoice draft"),
            moment(3, Some("Keynote"), "Slides"),
            moment(4, Some("Invoice"), "Already found"),
        ];
        let found = [lokalbot_core::search::ScreenHit {
            moment: moment(4, None, "Already found"),
            snippet: String::new(),
            rank: 0.0,
            capture_count: 1,
        }];
        let any = lokalbot_core::screen_search::ScreenFilter::default();
        let ids: Vec<i64> = saved_matches(&saved, &found, &any, "invoice")
            .iter()
            .map(|hit| hit.moment.id)
            .collect();
        assert_eq!(ids, [1, 2]);
        let bound = lokalbot_core::screen_search::ScreenFilter {
            snapshot_ids: Some([2].into_iter().collect()),
            ..Default::default()
        };
        let ids: Vec<i64> = saved_matches(&saved, &found, &bound, "invoice")
            .iter()
            .map(|hit| hit.moment.id)
            .collect();
        assert_eq!(ids, [2], "a boundary still applies");
    }

    #[test]
    fn speaker_labels() {
        assert_eq!(speaker_label("Them"), "Other speaker");
        assert_eq!(speaker_label("them 2"), "Speaker 2");
        assert_eq!(speaker_label("Maya"), "Maya");
    }

    fn meeting(number: u128) -> Meeting {
        let mut meeting = Meeting::new("Meeting", "Test", Utc::now(), "meeting");
        meeting.id = Uuid::from_u128(number);
        meeting
    }

    fn hit(kind: DocKind, start: Option<f64>, is_semantic: bool) -> Hit {
        Hit {
            kind,
            start,
            speaker: None,
            snippet: "passage".into(),
            is_semantic,
        }
    }

    fn group(meeting: &Meeting, hits: Vec<Hit>) -> MeetingGroup {
        MeetingGroup {
            meeting: meeting.clone(),
            hits,
        }
    }

    #[test]
    fn many_keyword_rows_cannot_bury_a_meeting_found_by_meaning() {
        let meetings: Vec<Meeting> = (1..=4).map(meeting).collect();
        let keyword = vec![
            group(
                &meetings[0],
                (0..50)
                    .map(|i| hit(DocKind::Segment, Some(f64::from(i)), false))
                    .collect(),
            ),
            group(&meetings[1], vec![hit(DocKind::Summary, None, false)]),
            group(&meetings[2], vec![hit(DocKind::Summary, None, false)]),
        ];
        // The fourth is first by meaning and has no words in common.
        let semantic = vec![(meetings[3].id, hit(DocKind::Segment, Some(10.0), true))];
        let (fused, truncated) = fused_meetings(keyword, semantic, &meetings, 40);
        let order: Vec<Uuid> = fused.iter().map(|g| g.meeting.id).collect();
        // Equal fused scores go to keyword evidence, then to the earlier rank.
        assert_eq!(
            order,
            [
                meetings[0].id,
                meetings[3].id,
                meetings[1].id,
                meetings[2].id
            ]
        );
        assert!(!truncated);
        assert!(fused[1].hits[0].is_semantic);
    }

    #[test]
    fn a_meeting_found_both_ways_leads_and_shows_its_words_first() {
        let meetings: Vec<Meeting> = (1..=2).map(meeting).collect();
        let keyword = vec![
            group(&meetings[0], vec![hit(DocKind::Summary, None, false)]),
            group(
                &meetings[1],
                vec![
                    hit(DocKind::Summary, None, false),
                    hit(DocKind::Segment, Some(5.0), false),
                ],
            ),
        ];
        let semantic = vec![
            (meetings[1].id, hit(DocKind::Segment, Some(5.0), true)),
            (meetings[1].id, hit(DocKind::Segment, Some(90.0), true)),
        ];
        let (fused, _) = fused_meetings(keyword, semantic, &meetings, 40);
        assert_eq!(fused[0].meeting.id, meetings[1].id);
        let hits = &fused[0].hits;
        // The transcript hit by words leads; the same passage isn't listed twice.
        assert_eq!(hits.len(), 3);
        assert_eq!(
            (hits[0].kind, hits[0].is_semantic),
            (DocKind::Segment, false)
        );
        assert_eq!(hits[1].kind, DocKind::Summary);
        assert_eq!(hits[2].start, Some(90.0));
    }

    #[test]
    fn fusion_says_when_it_hit_the_limit_and_drops_unknown_meetings() {
        let meetings: Vec<Meeting> = (1..=3).map(meeting).collect();
        let semantic = vec![
            (meetings[0].id, hit(DocKind::Summary, None, true)),
            (meetings[1].id, hit(DocKind::Summary, None, true)),
            (meetings[2].id, hit(DocKind::Summary, None, true)),
            (Uuid::from_u128(99), hit(DocKind::Summary, None, true)),
        ];
        let (fused, truncated) = fused_meetings(Vec::new(), semantic.clone(), &meetings, 2);
        assert_eq!(fused.len(), 2);
        assert!(truncated);
        let (fused, truncated) = fused_meetings(Vec::new(), semantic, &meetings, 3);
        assert_eq!(fused.len(), 3);
        assert!(!truncated);
    }

    #[test]
    fn meaning_is_fused_only_for_all_results_within_the_scope() {
        let now = Utc::now();
        let mut query = Query {
            text: "x".into(),
            meetings: true,
            ..Default::default()
        };
        assert!(query.wants_meaning());
        query.facet = Facet::Summaries;
        assert!(!query.searches_meeting_meaning());
        query.facet = Facet::All;
        let meetings: Vec<Meeting> = (1..=2).map(meeting).collect();
        assert!(query.meeting_scope(&meetings).is_none());
        query.meeting_ids = Some(vec![meetings[0].id]);
        assert_eq!(query.meeting_scope(&meetings).unwrap().len(), 1);
        query.since = Some(now + chrono::Duration::days(1));
        assert!(query.meeting_scope(&meetings).unwrap().is_empty());
    }

    #[test]
    fn a_meeting_found_only_by_meaning_joins_the_list_within_its_scope() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(lokalbot_core::LibraryPaths::new(dir.path())).unwrap();
        let found = library
            .create_meeting("Design review", "Zoom", lokalbot_core::time::now_seconds())
            .unwrap();
        let other = library
            .create_meeting("Standup", "Zoom", lokalbot_core::time::now_seconds())
            .unwrap();
        let passage = "We agreed to keep the launch small.";
        library.save_summary(&found, passage).unwrap();
        library.reindex_meeting(&found).unwrap();
        library
            .store_meeting_embeddings(
                found.id,
                library.embedding_source_mtime(&found),
                lokalbot_core::embeddings::MODEL_ID,
                &[(0.0, passage.to_string(), vec![1.0, 0.0])],
            )
            .unwrap();
        let meetings = library.list_meetings().unwrap();
        let query = Query {
            text: "roadmap".into(),
            meetings: true,
            limit: DISPLAY_LIMIT,
            ..Default::default()
        };
        let vector = [1.0, 0.0];
        let mut results = run(&library, &meetings, &query);
        assert!(results.meetings.is_empty(), "no keyword matches");
        fuse_meetings(&library, &meetings, &query, &vector, &mut results);
        assert_eq!(results.meetings.len(), 1);
        assert_eq!(results.meetings[0].meeting.id, found.id);
        let hit = &results.meetings[0].hits[0];
        assert!(hit.is_semantic);
        assert_eq!(hit.kind, DocKind::Summary);
        assert_eq!(hit.snippet, passage);

        // A boundary around another meeting keeps this one out.
        let bounded = Query {
            meeting_ids: Some(vec![other.id]),
            ..query.clone()
        };
        let mut results = run(&library, &meetings, &bounded);
        fuse_meetings(&library, &meetings, &bounded, &vector, &mut results);
        assert!(results.meetings.is_empty());

        // A facet asks for one kind of document, and stays keyword-only.
        let summaries = Query {
            facet: Facet::Summaries,
            ..query
        };
        let mut results = run(&library, &meetings, &summaries);
        fuse_meetings(&library, &meetings, &summaries, &vector, &mut results);
        assert!(results.meetings.is_empty());
        drop(library);
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
