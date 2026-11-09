//! Walks the chosen folders and applies the rules (`Crawler`). Reads metadata
//! only, never file contents (except the sniff in `rules`).

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::rules::{self, Classification};
use super::{Candidate, FileKind, IndexOptions, home_dir};

/// A file's own facts, not following a link (`FileSystem.info`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FileInfo {
    /// Not a link, device or socket.
    pub is_regular: bool,
    pub size: i64,
    pub mtime: f64,
    pub inode: u64,
    pub device: u64,
    /// A cloud placeholder whose contents would be downloaded on read: never read.
    pub dataless: bool,
}

#[cfg(unix)]
pub fn file_info(path: &Path) -> Option<FileInfo> {
    use std::os::unix::fs::MetadataExt as _;
    let meta = std::fs::symlink_metadata(path).ok()?;
    Some(FileInfo {
        is_regular: meta.file_type().is_file(),
        size: meta.len() as i64,
        mtime: meta.mtime() as f64 + meta.mtime_nsec() as f64 / 1e9,
        inode: meta.ino(),
        device: meta.dev(),
        dataless: false,
    })
}

#[cfg(windows)]
pub fn file_info(path: &Path) -> Option<FileInfo> {
    use std::os::windows::fs::MetadataExt as _;
    // RECALL_ON_DATA_ACCESS, RECALL_ON_OPEN, OFFLINE: OneDrive's placeholders.
    const CLOUD: u32 = 0x0040_0000 | 0x0004_0000 | 0x0000_1000;
    let meta = std::fs::symlink_metadata(path).ok()?;
    let dataless = meta.file_attributes() & CLOUD != 0;
    let is_regular = meta.file_type().is_file();
    let (inode, device) = if is_regular && !dataless {
        windows_file_id(path).unwrap_or((0, 0))
    } else {
        (0, 0)
    };
    let mtime = meta
        .modified()
        .ok()
        .and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0.0, |d| d.as_secs_f64());
    Some(FileInfo {
        is_regular,
        size: meta.len() as i64,
        mtime,
        inode,
        device,
        dataless,
    })
}

/// The file's id on its volume stands in for the inode: it's what lets a moved
/// file keep its vectors.
#[cfg(windows)]
fn windows_file_id(path: &Path) -> Option<(u64, u64)> {
    use std::os::windows::ffi::OsStrExt as _;
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{
        BY_HANDLE_FILE_INFORMATION, CreateFileW, FILE_FLAG_BACKUP_SEMANTICS,
        FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
        GetFileInformationByHandle, OPEN_EXISTING,
    };
    let wide: Vec<u16> = path.as_os_str().encode_wide().chain([0]).collect();
    // SAFETY: `wide` is a NUL-terminated path that outlives the call; the handle
    // is checked and closed, and `info` is a plain struct filled by the call.
    unsafe {
        let handle = CreateFileW(
            wide.as_ptr(),
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            std::ptr::null_mut(),
        );
        if handle == INVALID_HANDLE_VALUE {
            return None;
        }
        let mut info: BY_HANDLE_FILE_INFORMATION = std::mem::zeroed();
        let ok = GetFileInformationByHandle(handle, &mut info) != 0;
        CloseHandle(handle);
        ok.then(|| {
            (
                ((info.nFileIndexHigh as u64) << 32) | info.nFileIndexLow as u64,
                info.dwVolumeSerialNumber as u64,
            )
        })
    }
}

/// The folder exists and opens for listing (`isReadableFolder`): an unplugged
/// drive or a refused folder says no.
pub fn is_readable_folder(path: &Path) -> bool {
    path.is_dir() && std::fs::read_dir(path).is_ok()
}

#[cfg(windows)]
fn is_hidden(entry: &std::fs::DirEntry) -> bool {
    use std::os::windows::fs::MetadataExt as _;
    const HIDDEN: u32 = 0x2;
    entry.file_name().to_string_lossy().starts_with('.')
        || entry
            .metadata()
            .is_ok_and(|m| m.file_attributes() & HIDDEN != 0)
}

#[cfg(not(windows))]
fn is_hidden(entry: &std::fs::DirEntry) -> bool {
    entry.file_name().to_string_lossy().starts_with('.')
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct CrawlReport {
    pub candidates: Vec<Candidate>,
    /// Reason → files.
    pub skipped: BTreeMap<String, usize>,
    /// Reason → folders not walked into.
    pub skipped_folders: BTreeMap<String, usize>,
    /// Folder → files skipped as a dataset.
    pub datasets: HashMap<String, usize>,
}

impl CrawlReport {
    fn skip(&mut self, reason: &str) {
        *self.skipped.entry(reason.into()).or_default() += 1;
    }

    fn skip_folder(&mut self, reason: &str) {
        *self.skipped_folders.entry(reason.into()).or_default() += 1;
    }
}

/// Walks `roots`, calling `progress` with the entries checked so far, at most
/// four times a second.
pub fn crawl(
    roots: &[PathBuf],
    options: &IndexOptions,
    progress: &mut dyn FnMut(usize),
) -> CrawlReport {
    const MINIMUM_DATASET_FILES: usize = 300;
    let home = home_dir();
    let mut report = CrawlReport::default();
    let mut project_roots: HashSet<PathBuf> = HashSet::new();
    let mut found: Vec<Candidate> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let root_paths: HashSet<String> = roots
        .iter()
        .map(|r| r.to_string_lossy().into_owned())
        .collect();
    let mut checked = 0usize;
    let mut last_update = Instant::now();

    for root in roots {
        progress(checked);
        if rules::is_cache_directory(root) {
            report.skip_folder("cache folder");
            continue;
        }
        // A folder chosen on purpose is read whole, whatever markers it holds;
        // the code-project rule applies to project folders found inside it.
        let mut stack = vec![root.clone()];
        while let Some(folder) = stack.pop() {
            let Ok(entries) = std::fs::read_dir(&folder) else {
                continue;
            };
            for entry in entries.flatten() {
                checked += 1;
                if last_update.elapsed() >= Duration::from_millis(250) {
                    progress(checked);
                    last_update = Instant::now();
                }
                if is_hidden(&entry) {
                    continue;
                }
                let path = entry.path();
                let Ok(file_type) = entry.file_type() else {
                    continue;
                };
                if file_type.is_dir() {
                    if rules::is_package(&path) {
                        report.skip(if rules::is_photos_library(&path) {
                            "Photos library"
                        } else {
                            "app or bundle"
                        });
                    } else if let Some(reason) =
                        rules::skip_reason_for_folder(&path, home.as_deref())
                    {
                        report.skip_folder(reason);
                    } else {
                        if rules::is_project_root(&path) {
                            project_roots.insert(path.clone());
                        }
                        stack.push(path);
                    }
                    continue;
                }
                match rules::classify(&path, options) {
                    Classification::Ignore => report.skip("other type"),
                    Classification::Skip(reason) => report.skip(reason),
                    Classification::Index(kind) => {
                        let Some(info) = file_info(&path).filter(|i| i.is_regular) else {
                            report.skip("link or special file");
                            continue;
                        };
                        if info.dataless {
                            report.skip("in the cloud, not downloaded");
                            continue;
                        }
                        let text = super::plain_path(&path);
                        if seen.insert(text.clone()) {
                            found.push(Candidate {
                                path: text,
                                kind,
                                size: info.size,
                                mtime: info.mtime,
                                inode: info.inode,
                                device: info.device,
                            });
                        }
                    }
                }
            }
        }
    }

    // Inside a code project only screenshots count.
    let mut in_project: HashMap<PathBuf, bool> = HashMap::new();
    let mut kept = Vec::with_capacity(found.len());
    for file in found {
        let folder = Path::new(&file.path)
            .parent()
            .unwrap_or(Path::new(""))
            .to_path_buf();
        if file.kind != FileKind::Screenshot
            && is_in_project(&folder, &project_roots, &mut in_project)
        {
            report.skip("inside a code project");
        } else {
            kept.push(file);
        }
    }

    if !options.include_datasets {
        let described: Vec<(String, String, FileKind)> = kept
            .iter()
            .map(|file| {
                let path = Path::new(&file.path);
                (
                    path.parent()
                        .map(|p| p.to_string_lossy().into_owned())
                        .unwrap_or_default(),
                    path.file_stem()
                        .map(|s| s.to_string_lossy().into_owned())
                        .unwrap_or_default(),
                    file.kind,
                )
            })
            .collect();
        let datasets = rules::dataset_folders(&described, &root_paths, MINIMUM_DATASET_FILES);
        if !datasets.is_empty() {
            let mut left = Vec::with_capacity(kept.len());
            for file in kept {
                let folder = Path::new(&file.path)
                    .parent()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_default();
                if datasets.contains_key(&folder)
                    && matches!(
                        file.kind,
                        FileKind::Image | FileKind::Audio | FileKind::Video
                    )
                {
                    report.skip("dataset");
                } else {
                    left.push(file);
                }
            }
            kept = left;
            report.datasets = datasets;
        }
    }
    report.candidates = kept;
    progress(checked);
    report
}

fn is_in_project(
    folder: &Path,
    project_roots: &HashSet<PathBuf>,
    known: &mut HashMap<PathBuf, bool>,
) -> bool {
    if let Some(answer) = known.get(folder) {
        return *answer;
    }
    let answer = project_roots.contains(folder)
        || folder
            .parent()
            .is_some_and(|parent| is_in_project(parent, project_roots, known));
    known.insert(folder.to_path_buf(), answer);
    answer
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn write(path: PathBuf) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "x").unwrap();
    }

    fn names(report: &CrawlReport, root: &Path) -> Vec<String> {
        let mut names: Vec<String> = report
            .candidates
            .iter()
            .map(|c| {
                Path::new(&c.path)
                    .strip_prefix(root)
                    .unwrap()
                    .to_string_lossy()
                    .replace('\\', "/")
            })
            .collect();
        names.sort();
        names
    }

    #[test]
    fn walks_what_the_rules_allow() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("Docs");
        write(root.join("plan.md"));
        write(root.join("deck.pdf"));
        write(root.join("main.rs"));
        write(root.join(".hidden/secret.txt"));
        write(root.join(".dotfile.txt"));
        write(root.join("node_modules/readme.md"));
        write(root.join("archive.noindex/old.txt"));
        write(root.join("App.app/inner.txt"));
        write(root.join("project/Cargo.toml"));
        write(root.join("project/README.md"));
        write(root.join("project/assets/photo.png"));
        write(root.join("project/Screenshots/shot.png"));
        let report = crawl(
            std::slice::from_ref(&root),
            &IndexOptions::default(),
            &mut |_| {},
        );
        assert_eq!(
            names(&report, &root),
            ["deck.pdf", "plan.md", "project/Screenshots/shot.png"]
        );
        assert_eq!(report.skipped.get("code or data file"), Some(&2));
        assert_eq!(report.skipped.get("inside a code project"), Some(&2));
        assert_eq!(report.skipped.get("app or bundle"), Some(&1));
        assert_eq!(report.skipped_folders.get("developer folder"), Some(&1));
        assert_eq!(report.skipped_folders.get(".noindex folder"), Some(&1));
    }

    #[test]
    fn a_chosen_project_is_read_whole() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("notes");
        write(root.join("Cargo.toml"));
        write(root.join("readme.md"));
        let report = crawl(
            std::slice::from_ref(&root),
            &IndexOptions::default(),
            &mut |_| {},
        );
        assert_eq!(names(&report, &root), ["readme.md"]);
    }

    #[cfg(unix)]
    #[test]
    fn links_are_not_followed() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("root");
        write(root.join("real.txt"));
        let outside = dir.path().join("outside");
        write(outside.join("secret.txt"));
        std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
        std::os::unix::fs::symlink(outside.join("secret.txt"), root.join("alias.txt")).unwrap();
        let report = crawl(
            std::slice::from_ref(&root),
            &IndexOptions::default(),
            &mut |_| {},
        );
        assert_eq!(names(&report, &root), ["real.txt"]);
        assert_eq!(report.skipped.get("link or special file"), Some(&1));
    }

    #[test]
    fn a_dataset_folder_is_left_out_but_not_a_chosen_one() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("root");
        for i in 0..300 {
            write(root.join(format!("frames/frame_{i:06}.png")));
        }
        write(root.join("frames/notes.txt"));
        let report = crawl(
            std::slice::from_ref(&root),
            &IndexOptions::default(),
            &mut |_| {},
        );
        assert_eq!(names(&report, &root), ["frames/notes.txt"]);
        let chosen = crawl(
            &[root.join("frames")],
            &IndexOptions::default(),
            &mut |_| {},
        );
        assert_eq!(chosen.candidates.len(), 301);
    }
}
