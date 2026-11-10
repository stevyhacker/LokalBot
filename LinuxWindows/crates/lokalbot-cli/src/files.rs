//! `search_files` for MCP and `lokalbot-cli search-files` (`FilesSearchTool`): word
//! search over the Files index, which works while the app is closed. Search by
//! meaning needs LokalBot's embedding model, so it stays in Ask.

use std::collections::HashSet;
use std::path::Path;

use chrono::{DateTime, Local, NaiveDate, SecondsFormat, TimeZone as _, Utc};
use lokalbot_core::LibraryPaths;
use lokalbot_core::files::index::FileIndex;
use lokalbot_core::files::search::{SearchHit, Searcher};
use lokalbot_core::files::{self, FileKind, access, exif_date, is_inside, real_path};
use serde::Serialize;

use crate::search::MAXIMUM_QUERY_CHARACTERS;

pub const NAME: &str = "search_files";
pub const DEFAULT_LIMIT: i64 = 10;
pub const MAXIMUM_LIMIT: i64 = 50;
/// The most ranked matches one search looks through for ones inside the
/// chosen folders and dates.
const WIDEST_SEARCH: usize = 4_096;
/// A passage longer than this is cut, with an ellipsis.
const PASSAGE_CHARACTERS: usize = 1_500;

pub const KINDS: [&str; 6] = ["screenshot", "image", "pdf", "doc", "audio", "video"];

pub const DISABLED_MESSAGE: &str = "File access is off. The user can turn it on in LokalBot → Settings → Privacy & Data → \"Allow external agents to search your files\".";
pub const UNAVAILABLE_MESSAGE: &str = "File access is on, but Files is off in LokalBot or has no folder yet. The user can choose folders in LokalBot → Settings → Files.";
pub const NOTE: &str = "Found by their words: text LokalBot read from documents, PDF pages, screenshots and pictures, and file names. Recordings and video match only by name here. Paths point at the user's own files; LokalBot never changes them.";

#[derive(Debug, PartialEq, Eq)]
pub enum Failure {
    Disabled,
    Unavailable,
    Invalid(String),
}

impl Failure {
    pub fn message(&self) -> String {
        match self {
            Failure::Disabled => DISABLED_MESSAGE.into(),
            Failure::Unavailable => UNAVAILABLE_MESSAGE.into(),
            Failure::Invalid(message) => message.clone(),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct Item {
    /// The matched passage's id in the index.
    pub id: i64,
    pub path: String,
    pub name: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub page: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seconds: Option<f64>,
    pub modified: String,
    /// When a photo was taken, if it says.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub taken: Option<String>,
    pub size: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub excerpt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub passage: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Report {
    pub matched_by: &'static str,
    pub note: &'static str,
    pub query: String,
    pub results: Vec<Item>,
}

fn stamp(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn local_day_start(raw: &str, field: &str) -> Result<DateTime<Utc>, Failure> {
    let invalid = || Failure::Invalid(format!("\"{field}\" must be a day as YYYY-MM-DD."));
    let day = NaiveDate::parse_from_str(raw, "%Y-%m-%d").map_err(|_| invalid())?;
    let midnight = day.and_hms_opt(0, 0, 0).ok_or_else(invalid)?;
    Local
        .from_local_datetime(&midnight)
        .earliest()
        .map(|at| at.with_timezone(&Utc))
        .ok_or_else(invalid)
}

fn clipped(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() <= PASSAGE_CHARACTERS {
        return trimmed.to_string();
    }
    let mut out: String = trimmed.chars().take(PASSAGE_CHARACTERS).collect();
    out.push('…');
    out
}

/// Arguments first, so a bad call says so with or without the grant; then the
/// grant, the folder list and the index.
pub fn report(
    paths: &LibraryPaths,
    query: &str,
    kinds: Option<&[String]>,
    after: Option<&str>,
    before: Option<&str>,
    limit: Option<i64>,
) -> Result<Report, Failure> {
    let query = query.trim();
    if query.is_empty() || query.chars().count() > MAXIMUM_QUERY_CHARACTERS {
        return Err(Failure::Invalid(format!(
            "\"query\" must be a non-empty string of at most {MAXIMUM_QUERY_CHARACTERS} characters."
        )));
    }
    let count = limit.unwrap_or(DEFAULT_LIMIT);
    if !(1..=MAXIMUM_LIMIT).contains(&count) {
        return Err(Failure::Invalid(format!(
            "\"limit\" must be an integer between 1 and {MAXIMUM_LIMIT}."
        )));
    }
    let count = count as usize;
    let mut wanted: Option<HashSet<FileKind>> = None;
    if let Some(raw) = kinds.filter(|raw| !raw.is_empty()) {
        let mut parsed = HashSet::new();
        for kind in raw {
            let lower = kind.to_lowercase();
            match FileKind::parse(&lower).filter(|_| KINDS.contains(&lower.as_str())) {
                Some(kind) => {
                    parsed.insert(kind);
                }
                None => {
                    return Err(Failure::Invalid(format!(
                        "\"kinds\" may contain only {}.",
                        KINDS.join(", ")
                    )));
                }
            }
        }
        wanted = Some(parsed);
    }
    let from = after.map(|raw| local_day_start(raw, "after")).transpose()?;
    let until = before
        .map(|raw| local_day_start(raw, "before"))
        .transpose()?;

    if !access::is_enabled(paths) {
        return Err(Failure::Disabled);
    }
    let Some(projection) = access::read_projection(paths) else {
        return Err(Failure::Unavailable);
    };
    let directory = files::index_dir(paths.root());
    let mut searcher = FileIndex::open_read_only(&directory)
        .and_then(Searcher::new)
        .map_err(|_| Failure::Unavailable)?;
    // A walk reports a folder by its real path.
    let roots: Vec<String> = projection
        .folders
        .iter()
        .flat_map(|folder| [folder.clone(), real_path(folder)])
        .collect();
    // The hits inside the chosen folders and dates, best first, up to `count`.
    let kept = |found: Vec<SearchHit>| {
        let mut kept = Vec::new();
        for hit in found {
            if kept.len() >= count {
                break;
            }
            if !roots.iter().any(|root| is_inside(&hit.path, root))
                || !Path::new(&hit.path).exists()
            {
                continue;
            }
            let modified = lokalbot_core::time::from_epoch(hit.modified);
            let taken = hit.info.get("taken").and_then(|text| exif_date(text));
            let date = taken.unwrap_or(modified);
            if from.is_some_and(|from| date < from) || until.is_some_and(|until| date >= until) {
                continue;
            }
            kept.push((hit, modified, taken));
        }
        kept
    };
    // The folders and dates are applied after ranking, so the best few
    // matches can all fall outside them: forty older invoices hid the one
    // from this month. Look further down the ranking until enough are
    // inside, or there is nothing more to look at.
    let mut window = count * 4;
    let matches = loop {
        let found = searcher
            .search_through(query, None, wanted.as_ref(), window)
            .map_err(|_| Failure::Unavailable)?;
        let full = found.len() >= window;
        let matches = kept(found);
        if matches.len() >= count || !full || window >= WIDEST_SEARCH {
            break matches;
        }
        window = (window * 4).min(WIDEST_SEARCH);
    };
    let mut results = Vec::new();
    for (hit, modified, taken) in matches {
        let is_media = matches!(hit.kind, FileKind::Audio | FileKind::Video);
        let passage = if is_media {
            None
        } else {
            searcher.text_of_segment(hit.segment_id).ok().flatten()
        };
        results.push(Item {
            id: hit.segment_id,
            name: Path::new(&hit.path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
            kind: hit.kind.as_str().to_string(),
            page: (hit.kind == FileKind::Pdf)
                .then_some(hit.loc.map(|l| l as i64))
                .flatten(),
            seconds: is_media.then_some(hit.loc).flatten(),
            modified: stamp(modified),
            taken: taken.map(stamp),
            size: hit.size,
            excerpt: hit.excerpt,
            passage: passage.as_deref().map(clipped),
            path: hit.path,
        });
    }
    Ok(Report {
        matched_by: "words",
        note: NOTE,
        query: query.to_string(),
        results,
    })
}

/// A plain-text table for `search-files --table`.
pub fn table(report: &Report) -> String {
    if report.results.is_empty() {
        return format!("No files matched \"{}\".", report.query);
    }
    report
        .results
        .iter()
        .map(|item| {
            let place = item
                .page
                .map(|page| format!(" · page {page}"))
                .unwrap_or_default();
            let excerpt = item.excerpt.as_deref().unwrap_or("").replace('\n', " ");
            format!(
                "{}\t{}\t{}{place}\n\t{excerpt}",
                item.kind,
                &item.modified[..item.modified.len().min(10)],
                item.path
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::files::{Candidate, Modality, SegmentKind};
    use std::collections::BTreeMap;

    struct Fixture {
        _dir: tempfile::TempDir,
        paths: LibraryPaths,
        folder: String,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path().join("lib"));
        let docs = dir.path().join("docs");
        std::fs::create_dir_all(&docs).unwrap();
        let file = docs.join("plan.md");
        std::fs::write(&file, "x").unwrap();
        let index = FileIndex::open(&files::index_dir(paths.root())).unwrap();
        let id = index
            .insert(&Candidate {
                path: file.to_string_lossy().into_owned(),
                kind: FileKind::Doc,
                size: 1,
                mtime: 1_700_000_000.0,
                inode: 1,
                device: 1,
            })
            .unwrap();
        index
            .add_segment(
                id,
                SegmentKind::Chunk,
                Modality::Text,
                Some(1.0),
                None,
                Some("The roadmap for next year"),
                Some("The roadmap for next year"),
                None,
            )
            .unwrap();
        index.finish(id, "done", None, &BTreeMap::new()).unwrap();
        let outside = index
            .insert(&Candidate {
                path: "/somewhere/else/roadmap.md".into(),
                kind: FileKind::Doc,
                size: 1,
                mtime: 1.0,
                inode: 2,
                device: 1,
            })
            .unwrap();
        index
            .finish(outside, "done", None, &BTreeMap::new())
            .unwrap();
        Fixture {
            _dir: dir,
            paths,
            folder: docs.to_string_lossy().into_owned(),
        }
    }

    #[test]
    fn nothing_is_read_without_the_grant_and_the_folder_list() {
        let fixture = fixture();
        let search = || report(&fixture.paths, "roadmap", None, None, None, None);
        assert_eq!(search().unwrap_err(), Failure::Disabled);
        access::set_enabled(&fixture.paths, true).unwrap();
        assert_eq!(
            search().unwrap_err(),
            Failure::Unavailable,
            "no folder list"
        );
        access::refresh(&fixture.paths, Some(std::slice::from_ref(&fixture.folder))).unwrap();
        let found = search().unwrap();
        assert_eq!(found.matched_by, "words");
        assert_eq!(found.results.len(), 1, "only the chosen folder: {found:?}");
        let item = &found.results[0];
        assert_eq!(item.name, "plan.md");
        assert_eq!(item.kind, "doc");
        assert_eq!(item.passage.as_deref(), Some("The roadmap for next year"));
        assert!(item.excerpt.as_deref().unwrap().contains("«roadmap»"));
        access::set_enabled(&fixture.paths, false).unwrap();
        assert_eq!(search().unwrap_err(), Failure::Disabled);
    }

    #[test]
    fn arguments_are_checked_first() {
        let fixture = fixture();
        let invalid = |result: Result<Report, Failure>| {
            assert!(matches!(result, Err(Failure::Invalid(_))), "{result:?}");
        };
        invalid(report(&fixture.paths, "  ", None, None, None, None));
        invalid(report(&fixture.paths, "x", None, None, None, Some(0)));
        invalid(report(&fixture.paths, "x", None, None, None, Some(51)));
        invalid(report(
            &fixture.paths,
            "x",
            Some(&["code".to_string()]),
            None,
            None,
            None,
        ));
        invalid(report(&fixture.paths, "x", None, Some("May"), None, None));
    }

    #[test]
    fn kinds_and_dates_narrow_the_results() {
        let fixture = fixture();
        access::set_enabled(&fixture.paths, true).unwrap();
        access::refresh(&fixture.paths, Some(std::slice::from_ref(&fixture.folder))).unwrap();
        let only_pdf = report(
            &fixture.paths,
            "roadmap",
            Some(&["pdf".to_string()]),
            None,
            None,
            None,
        )
        .unwrap();
        assert!(only_pdf.results.is_empty());
        let later = report(
            &fixture.paths,
            "roadmap",
            None,
            Some("2030-01-01"),
            None,
            None,
        )
        .unwrap();
        assert!(later.results.is_empty());
        let earlier = report(
            &fixture.paths,
            "roadmap",
            None,
            None,
            Some("2030-01-01"),
            None,
        )
        .unwrap();
        assert_eq!(earlier.results.len(), 1);
        assert!(table(&earlier).contains("plan.md"));
        assert_eq!(table(&later), "No files matched \"roadmap\".");
    }

    #[test]
    fn a_match_ranked_below_ones_outside_the_chosen_folders_is_still_found() {
        let fixture = fixture();
        access::set_enabled(&fixture.paths, true).unwrap();
        access::refresh(&fixture.paths, Some(std::slice::from_ref(&fixture.folder))).unwrap();
        // Files with both words rank above the one in the chosen folder,
        // which has one. All are outside it, and there are more of them than
        // a search for one result looks at first, or used to look at in all.
        let index = FileIndex::open(&files::index_dir(fixture.paths.root())).unwrap();
        for number in 0..120 {
            let id = index
                .insert(&Candidate {
                    path: format!("/somewhere/else/roadmap-{number}.md"),
                    kind: FileKind::Doc,
                    size: 1,
                    mtime: 1.0,
                    inode: 100 + number,
                    device: 1,
                })
                .unwrap();
            index
                .add_segment(
                    id,
                    SegmentKind::Chunk,
                    Modality::Text,
                    Some(1.0),
                    None,
                    Some("The roadmap and the budget"),
                    Some("The roadmap and the budget"),
                    None,
                )
                .unwrap();
            index.finish(id, "done", None, &BTreeMap::new()).unwrap();
        }
        drop(index);
        let found = report(&fixture.paths, "roadmap budget", None, None, None, Some(1)).unwrap();
        assert_eq!(found.results.len(), 1, "{found:?}");
        assert_eq!(found.results[0].name, "plan.md");
    }

    /// A few long documents outside the chosen folder hold more matching
    /// passages than a search used to read at all.
    #[test]
    fn a_match_below_a_thousand_passages_outside_the_chosen_folders_is_still_found() {
        let fixture = fixture();
        access::set_enabled(&fixture.paths, true).unwrap();
        access::refresh(&fixture.paths, Some(std::slice::from_ref(&fixture.folder))).unwrap();
        let index = FileIndex::open(&files::index_dir(fixture.paths.root())).unwrap();
        for number in 0..11 {
            let id = index
                .insert(&Candidate {
                    path: format!("/somewhere/else/handbook-{number}.md"),
                    kind: FileKind::Doc,
                    size: 1,
                    mtime: 1.0,
                    inode: 100 + number,
                    device: 1,
                })
                .unwrap();
            for place in 0..100 {
                index
                    .add_segment(
                        id,
                        SegmentKind::Chunk,
                        Modality::Text,
                        Some(f64::from(place)),
                        None,
                        Some("The roadmap and the budget"),
                        Some("The roadmap and the budget"),
                        None,
                    )
                    .unwrap();
            }
            index.finish(id, "done", None, &BTreeMap::new()).unwrap();
        }
        drop(index);
        let found = report(&fixture.paths, "roadmap budget", None, None, None, Some(1)).unwrap();
        assert_eq!(found.results.len(), 1, "{found:?}");
        assert_eq!(found.results[0].name, "plan.md");
    }

    #[test]
    fn long_passages_are_cut() {
        let long = "word ".repeat(1000);
        let cut = clipped(&long);
        assert!(cut.ends_with('…'));
        assert_eq!(cut.chars().count(), PASSAGE_CHARACTERS + 1);
    }
}
