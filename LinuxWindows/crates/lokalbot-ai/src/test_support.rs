//! Shared test fixtures.

use std::path::{Path, PathBuf};

use lokalbot_core::{Library, LibraryPaths};

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).expect("create fixture copy");
    for entry in std::fs::read_dir(from).expect("read fixture").flatten() {
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            copy_dir(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), target).expect("copy fixture file");
        }
    }
}

pub fn fixture_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../LokalBotTests/Fixtures/upgrade/0.10.9/library")
}

/// The macOS upgrade fixture, copied so tests never write into it. `None`
/// when the fixture is not checked out next to the workspace.
pub fn fixture_library() -> Option<(tempfile::TempDir, Library)> {
    let source = fixture_root();
    if !source.is_dir() {
        eprintln!("fixture missing at {}", source.display());
        return None;
    }
    let dir = tempfile::tempdir().expect("temp dir");
    copy_dir(&source, dir.path());
    let library = Library::open(LibraryPaths::new(dir.path())).expect("open fixture copy");
    Some((dir, library))
}
