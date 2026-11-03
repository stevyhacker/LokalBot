//! Which changes the file watcher reports can alter what a pass finds
//! (`FileChangeFilter`). Every pass walks the chosen folders again, so a change the
//! crawl would leave out never starts one: in a place it doesn't walk, of a type it
//! doesn't read, or inside a code project, where it keeps only screenshots.
//!
//! When in doubt it says yes: an extra pass costs seconds, a missed one leaves a new
//! file out of search until something else changes.

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

use super::rules::{self, Classification};
use super::{FileKind, IndexOptions};

/// What the watcher knows about one change.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ChangeFacts {
    /// The watcher lost track of what happened here: only a pass can tell.
    pub lost_track: bool,
    /// `None` when the watcher doesn't say and the path is gone. Unlike FSEvents,
    /// the watchers here often don't say.
    pub is_folder: Option<bool>,
    /// It appeared, went away, or moved.
    pub came_or_went: bool,
    /// It moved here whole: then this is all the watcher says about what it holds.
    pub arrived_whole: bool,
}

#[derive(Clone, Debug)]
pub struct ChangeFilter {
    /// Each chosen folder as chosen and as the file system resolves it.
    roots: Vec<PathBuf>,
    options: IndexOptions,
    home: Option<PathBuf>,
}

impl ChangeFilter {
    pub fn new(folders: &[String], options: IndexOptions, home: Option<PathBuf>) -> Self {
        let mut roots: Vec<PathBuf> = Vec::new();
        for folder in folders {
            let chosen = PathBuf::from(folder);
            let resolved = std::fs::canonicalize(&chosen).ok();
            for root in std::iter::once(chosen).chain(resolved) {
                if !roots.contains(&root) {
                    roots.push(root);
                }
            }
        }
        Self {
            roots,
            options,
            home,
        }
    }

    /// Whether this change can alter what a pass finds. Nested chosen folders answer
    /// differently: one's project can be the other's whole.
    pub fn matters(&self, path: &Path, facts: ChangeFacts, answers: &mut Answers) -> bool {
        if facts.lost_track {
            return true;
        }
        let mut placed = false;
        for root in &self.roots {
            if path.starts_with(root) {
                placed = true;
                if self.matters_under(path, facts, root, answers) {
                    return true;
                }
            }
        }
        // A spelling of the path that can't be placed in a chosen folder is no reason
        // to miss a change.
        !placed
    }

    fn matters_under(
        &self,
        path: &Path,
        facts: ChangeFacts,
        root: &Path,
        answers: &mut Answers,
    ) -> bool {
        // Most of what a busy computer reports is in hidden folders: no need to ask
        // the file system.
        if is_hidden_below(path, root) {
            return false;
        }
        // The watcher doesn't say what it is, and it's gone: only a pass can tell.
        let Some(is_folder) = facts.is_folder else {
            return true;
        };
        let parent = path.parent().unwrap_or(root);
        let home = self.home.as_deref();
        let walked = if is_folder {
            rules::is_walked(path, root, home)
        } else {
            remembered(&mut answers.walked, key(root, parent), || {
                rules::is_walked(parent, root, home)
            })
        };
        if !walked {
            return false;
        }
        // A project's only marker appearing or going decides what the crawl keeps
        // around it, unless a project above it already does. Editing one changes
        // nothing.
        if facts.came_or_went
            && rules::decides_project(path)
            && !self.in_project(parent, root, answers)
        {
            return true;
        }
        // A folder's contents report themselves, unless it moved here.
        if is_folder && !facts.arrived_whole {
            return false;
        }
        let may_matter = if is_folder {
            rules::change_may_matter(path, true, &self.options)
        } else {
            let kind = path
                .extension()
                .map(|e| e.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            remembered(
                &mut answers.types,
                format!("{}\0{kind}", parent.display()),
                || rules::change_may_matter(path, false, &self.options),
            )
        };
        if !may_matter {
            return false;
        }
        if is_folder {
            return true;
        }
        // Only screenshots count in a code project. A file that's gone goes by its
        // name; if that's wrong, search still hides a missing file and the next pass
        // drops it.
        if !self.in_project(path, root, answers) {
            return true;
        }
        rules::classify(path, &self.options) == Classification::Index(FileKind::Screenshot)
    }

    fn in_project(&self, path: &Path, root: &Path, answers: &mut Answers) -> bool {
        let folder = path.parent().unwrap_or(root);
        remembered(&mut answers.projects, key(root, folder), || {
            rules::is_inside_project(path, root)
        })
    }
}

/// Answers kept while changes arrive in a burst: a build reports thousands at a time,
/// so what's learned about a folder or a type is asked of the file system once. Start
/// afresh every couple of seconds, because folders and markers do change.
#[derive(Debug, Default)]
pub struct Answers {
    walked: HashMap<String, bool>,
    types: HashMap<String, bool>,
    projects: HashMap<String, bool>,
}

fn key(root: &Path, folder: &Path) -> String {
    format!("{}\0{}", root.display(), folder.display())
}

fn remembered(
    answers: &mut HashMap<String, bool>,
    key: String,
    ask: impl FnOnce() -> bool,
) -> bool {
    *answers.entry(key).or_insert_with(ask)
}

fn is_hidden_below(path: &Path, root: &Path) -> bool {
    let Ok(rest) = path.strip_prefix(root) else {
        return false;
    };
    rest.components().any(|part| match part {
        Component::Normal(name) => name.to_string_lossy().starts_with('.'),
        _ => false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        _dir: tempfile::TempDir,
        chosen: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            let dir = tempfile::tempdir().unwrap();
            let chosen = dir.path().join("chosen");
            std::fs::create_dir_all(&chosen).unwrap();
            let fixture = Self { _dir: dir, chosen };
            fixture.folder("node_modules/left-pad");
            fixture.folder("Work/Site/.git");
            fixture.folder("Work/Site/assets");
            fixture.folder("Work/App");
            fixture.folder("Work/Notes");
            fixture.write("Work/App/package.json");
            fixture.write("Work/App/plain.png");
            fixture.write("Work/Site/assets/plain.png");
            fixture
        }

        fn folder(&self, name: &str) {
            std::fs::create_dir_all(self.chosen.join(name)).unwrap();
        }

        fn write(&self, name: &str) {
            std::fs::write(self.chosen.join(name), "x").unwrap();
        }

        fn filter(&self, includes_media: bool) -> ChangeFilter {
            ChangeFilter::new(
                &[self.chosen.display().to_string()],
                IndexOptions::for_settings(includes_media),
                None,
            )
        }

        fn counts(&self, name: &str, facts: ChangeFacts) -> bool {
            self.filter(true)
                .matters(&self.chosen.join(name), facts, &mut Answers::default())
        }
    }

    const FILE: ChangeFacts = ChangeFacts {
        lost_track: false,
        is_folder: Some(false),
        came_or_went: true,
        arrived_whole: false,
    };
    const EDITED: ChangeFacts = ChangeFacts {
        came_or_went: false,
        ..FILE
    };
    const NEW_FOLDER: ChangeFacts = ChangeFacts {
        is_folder: Some(true),
        ..FILE
    };
    const MOVED_FOLDER: ChangeFacts = ChangeFacts {
        arrived_whole: true,
        ..NEW_FOLDER
    };

    #[test]
    fn what_can_be_indexed_counts_here_or_gone() {
        let fixture = Fixture::new();
        for name in [
            "notes.md",
            "Work/Notes/gone.txt",
            "report.pdf",
            "photo.heic",
            "clip.mov",
        ] {
            assert!(fixture.counts(name, FILE), "{name}");
        }
        let mut answers = Answers::default();
        let without_media = fixture.filter(false);
        assert!(!without_media.matters(&fixture.chosen.join("clip.mov"), FILE, &mut answers));
        assert!(without_media.matters(&fixture.chosen.join("notes.md"), FILE, &mut answers));
    }

    #[test]
    fn where_the_crawl_does_not_go_and_what_it_never_reads_do_not_count() {
        let fixture = Fixture::new();
        fixture.folder("Cache.noindex");
        fixture.folder("tmp");
        fixture.folder("Work/Temp");
        for name in [
            ".DS_Store",
            ".hidden/notes.md",
            "node_modules/left-pad/readme.md",
            "Cache.noindex/notes.md",
            "tmp/notes.md",
            "Work/Temp/notes.md",
            "Work/Notes/server.log",
            "Work/Notes/data.json",
            "Work/Notes/no-extension",
        ] {
            assert!(!fixture.counts(name, FILE), "{name}");
        }
    }

    #[test]
    fn inside_a_code_project_only_screenshots_count() {
        let fixture = Fixture::new();
        for name in [
            "Work/Site/readme.md",
            "Work/Site/assets/plain.png",
            "Work/Site/assets/gone.png",
            "Work/App/plain.png",
            "Work/Site/report.pdf",
        ] {
            assert!(!fixture.counts(name, FILE), "{name}");
        }
        assert!(fixture.counts("Work/Site/Screenshot 2026-11-02 at 10.00.00.png", FILE));
        assert!(fixture.counts("Work/Site/Screenshots/2026-11-02.png", FILE));
    }

    #[test]
    fn a_folders_only_marker_decides_what_is_kept_around_it() {
        let fixture = Fixture::new();
        // Removed or added: the crawl now keeps something else.
        assert!(fixture.counts("Work/App/package.json", FILE));
        assert!(fixture.counts("Work/Notes/Cargo.toml", FILE));
        // Editing it, or another beside it, changes nothing.
        assert!(!fixture.counts("Work/App/package.json", EDITED));
        assert!(
            !fixture.counts("Work/Site/package.json", FILE),
            "it has .git"
        );
        fixture.folder("Work/App/sub");
        assert!(
            !fixture.counts("Work/App/sub/Cargo.toml", FILE),
            "a project above it already decides"
        );
    }

    #[test]
    fn a_new_folder_reports_itself_and_a_moved_one_says_only_this() {
        let fixture = Fixture::new();
        assert!(!fixture.counts("Work/Notes/New", NEW_FOLDER));
        assert!(!fixture.counts("Work/Site/dist", NEW_FOLDER));
        assert!(fixture.counts("Work/Notes/Trip", MOVED_FOLDER));
        assert!(
            fixture.counts("Work/Site/Trip", MOVED_FOLDER),
            "it could hold screenshots"
        );
        assert!(!fixture.counts("node_modules/left-pad/lib", MOVED_FOLDER));
    }

    #[test]
    fn when_only_a_pass_can_tell_it_counts() {
        let fixture = Fixture::new();
        let lost = ChangeFacts {
            lost_track: true,
            ..FILE
        };
        assert!(fixture.counts("node_modules/left-pad", lost));
        let unknown = ChangeFacts {
            is_folder: None,
            ..FILE
        };
        assert!(fixture.counts("Work/Notes/server.log", unknown));
        // Even so, nothing in a hidden folder is walked.
        assert!(!fixture.counts(".hidden/gone", unknown));
        assert!(fixture.filter(true).matters(
            Path::new("/somewhere/else/server.log"),
            FILE,
            &mut Answers::default()
        ));
    }

    #[test]
    fn a_chosen_folder_is_read_whole_whatever_holds_it() {
        let dir = tempfile::tempdir().unwrap();
        let tmp = dir.path().join("tmp");
        std::fs::create_dir_all(&tmp).unwrap();
        let filter = ChangeFilter::new(
            &[tmp.display().to_string()],
            IndexOptions::for_settings(true),
            None,
        );
        assert!(filter.matters(&tmp.join("notes.md"), FILE, &mut Answers::default()));
    }
}
