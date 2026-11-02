//! What gets indexed (`Rules`, with `Platform/Portable`'s extension sets, which
//! stand in for macOS's type system). Only metadata and the file's name decide,
//! except the 600-byte sniff that tells a real MPEG-TS video from TypeScript.

use std::collections::{HashMap, HashSet};
use std::io::Read as _;
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;

use super::{FileKind, IndexOptions};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Classification {
    Index(FileKind),
    /// A reason worth reporting.
    Skip(&'static str),
    /// A type that isn't handled at all.
    Ignore,
}

/// Folders never worth walking into. Hidden folders and bundles are skipped by
/// the walk itself.
const SKIPPED_FOLDER_NAMES: &[&str] = &[
    "node_modules",
    "bower_components",
    "venv",
    "site-packages",
    "__pycache__",
    "DerivedData",
    "Pods",
    "Carthage",
];

/// Any of these in a folder makes it a code project, where only screenshots are
/// indexed.
const PROJECT_MARKERS: &[&str] = &[
    ".git",
    "package.json",
    "Package.swift",
    "pyproject.toml",
    "setup.py",
    "requirements.txt",
    "Cargo.toml",
    "go.mod",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "Gemfile",
    "composer.json",
    "CMakeLists.txt",
];
const PROJECT_BUNDLE_EXTENSIONS: &[&str] = &["xcodeproj", "xcworkspace"];

const DOC_EXTENSIONS: &[&str] = &[
    "txt", "text", "md", "markdown", "typ", "rtf", "docx", "doc", "odt", "html", "htm", "xlsx",
    "pptx", "ods", "odp",
];
const PROTECTED_EXTENSIONS: &[&str] = &["m4p"];
/// Source code and data files: off, as on the Mac (`includeCode`): an editor and
/// ripgrep search them better, and they flood an index.
const CODE_EXTENSIONS: &[&str] = &[
    "py", "ipynb", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "swift", "tsx", "cts",
    "js", "jsx", "mjs", "cjs", "go", "rs", "java", "kt", "kts", "scala", "rb", "php", "cs", "fs",
    "sh", "bash", "zsh", "fish", "ps1", "lua", "pl", "r", "jl", "dart", "sql", "vue", "svelte",
    "css", "scss", "sass", "less", "json", "jsonl", "yaml", "yml", "toml", "xml", "plist",
    "gradle", "cmake", "mk", "lock", "log", "csv", "tsv", "ini", "cfg", "conf", "proto", "graphql",
    "tf", "nix", "zig", "hs", "ex", "exs", "erl", "clj", "elm", "ml", "vim", "el", "asm", "metal",
    "glsl", "hlsl", "wgsl", "cu", "pyi", "pyc",
];
const SOURCE_EXTENSIONS: &[&str] = &[
    "py", "pyi", "pyx", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm", "swift", "ts",
    "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs", "go", "rs", "java", "kt", "kts", "scala",
    "groovy", "rb", "php", "cs", "fs", "sh", "bash", "zsh", "fish", "ps1", "lua", "pl", "pm", "r",
    "jl", "dart", "sql", "vue", "svelte", "astro", "html", "htm", "css", "scss", "sass", "less",
    "gradle", "cmake", "mk", "proto", "graphql", "gql", "tf", "hcl", "nix", "zig", "hs", "ex",
    "exs", "erl", "clj", "cljs", "elm", "ml", "mli", "vim", "el", "lisp", "asm", "s", "metal",
    "glsl", "hlsl", "wgsl", "cu", "cuh", "ino", "v", "sv", "tex",
];
const SCREENSHOT_PREFIXES: &[&str] = &["Screenshot", "Screen Shot", "CleanShot", "SCR-"];
const IMAGE_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "jpe", "jfif", "png", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif",
    "avif", "psd", "tga", "pnm", "ppm", "pgm", "cr2", "nef", "arw", "dng", "raf", "orf", "rw2",
];
const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "m4a", "m4b", "aac", "wav", "wave", "flac", "ogg", "oga", "opus", "aiff", "aif", "wma",
    "amr", "caf", "mka",
];
const VIDEO_EXTENSIONS: &[&str] = &[
    "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp", "3g2", "mpg", "mpeg", "m2v",
    "ogv", "mxf",
];
/// Mac bundles that may sit on a shared or copied disk: skipped whole by name,
/// since nothing here knows them as one thing.
const PACKAGE_EXTENSIONS: &[&str] = &[
    "app",
    "framework",
    "bundle",
    "plugin",
    "appex",
    "xpc",
    "kext",
    "xcodeproj",
    "xcworkspace",
    "playground",
    "photoslibrary",
    "musiclibrary",
    "tvlibrary",
    "imovielibrary",
    "fcpbundle",
    "logicx",
    "band",
    "pkg",
    "dmg",
];

fn extension_of(path: &Path) -> String {
    path.extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

/// `classify` by extension. RAW pictures, which nothing here decodes yet, are
/// still images: they fail with a note that says so, rather than vanish.
pub fn classify(path: &Path, options: &IndexOptions) -> Classification {
    let ext = extension_of(path);
    let is = |set: &[&str]| set.contains(&ext.as_str());
    if options.excluded_extensions.iter().any(|e| e == &ext) {
        return Classification::Skip("excluded type");
    }
    if is(PROTECTED_EXTENSIONS) {
        return Classification::Skip("copy-protected");
    }
    if matches!(ext.as_str(), "ts" | "mts" | "m2ts") {
        return if is_mpeg_transport_stream(path) {
            Classification::Index(FileKind::Video)
        } else {
            Classification::Skip("code or data file")
        };
    }
    if is(DOC_EXTENSIONS) {
        return Classification::Index(FileKind::Doc);
    }
    if is(CODE_EXTENSIONS) || is(SOURCE_EXTENSIONS) {
        return Classification::Skip("code or data file");
    }
    if ext == "pdf" {
        return Classification::Index(FileKind::Pdf);
    }
    if is(IMAGE_EXTENSIONS) {
        return Classification::Index(if is_screenshot(path) {
            FileKind::Screenshot
        } else {
            FileKind::Image
        });
    }
    if is(VIDEO_EXTENSIONS) {
        return Classification::Index(FileKind::Video);
    }
    if is(AUDIO_EXTENSIONS) {
        return Classification::Index(FileKind::Audio);
    }
    Classification::Ignore
}

/// MPEG-TS packets start with 0x47 every 188 bytes (or every 192 with a 4-byte
/// timecode, as in .m2ts).
pub fn is_mpeg_transport_stream(path: &Path) -> bool {
    let Ok(file) = std::fs::File::open(path) else {
        return false;
    };
    let mut bytes = Vec::with_capacity(600);
    if file.take(600).read_to_end(&mut bytes).is_err() || bytes.len() < 400 {
        return false;
    }
    (bytes[0] == 0x47 && bytes[188] == 0x47 && bytes[376] == 0x47)
        || (bytes[4] == 0x47 && bytes[196] == 0x47 && bytes[388] == 0x47)
}

/// By name: GNOME, KDE and Windows save into a "Screenshots" folder, and a
/// picture there is a screenshot whatever it's called.
pub fn is_screenshot(path: &Path) -> bool {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy())
        .unwrap_or_default();
    if SCREENSHOT_PREFIXES.iter().any(|p| name.starts_with(p)) {
        return true;
    }
    path.parent()
        .and_then(Path::file_name)
        .is_some_and(|f| f.to_string_lossy().eq_ignore_ascii_case("Screenshots"))
}

pub fn is_package(path: &Path) -> bool {
    PACKAGE_EXTENSIONS.contains(&extension_of(path).as_str())
}

/// Photos and other library bundles have their own reason.
pub fn is_photos_library(path: &Path) -> bool {
    matches!(
        extension_of(path).as_str(),
        "photoslibrary" | "photolibrary"
    )
}

pub fn skip_reason_for_folder(path: &Path, home: Option<&Path>) -> Option<&'static str> {
    let name = path.file_name()?.to_string_lossy();
    if SKIPPED_FOLDER_NAMES.contains(&name.as_ref()) {
        return Some("developer folder");
    }
    if name.ends_with(".noindex") {
        return Some(".noindex folder");
    }
    if is_cache_directory(path) {
        return Some("cache folder");
    }
    if home.is_some_and(|home| path == home.join("Library")) {
        return Some("~/Library");
    }
    None
}

/// The Cache Directory Tagging specification requires this exact header.
pub fn is_cache_directory(path: &Path) -> bool {
    const SIGNATURE: &[u8] = b"Signature: 8a477f597d28d172789f06886806bc55";
    let tag = path.join("CACHEDIR.TAG");
    let Some(info) = super::crawler::file_info(&tag) else {
        return false;
    };
    if !info.is_regular || info.dataless {
        return false;
    }
    let Ok(file) = std::fs::File::open(&tag) else {
        return false;
    };
    let mut head = Vec::with_capacity(SIGNATURE.len());
    file.take(SIGNATURE.len() as u64)
        .read_to_end(&mut head)
        .is_ok()
        && head == SIGNATURE
}

pub fn is_project_root(folder: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(folder) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        PROJECT_MARKERS.contains(&name.as_ref())
            || PROJECT_BUNDLE_EXTENSIONS.contains(&extension_of(Path::new(name.as_ref())).as_str())
    })
}

const CAMERA_PREFIXES: &[&str] = &[
    "img",
    "dsc",
    "pxl",
    "mvimg",
    "vid",
    "gopr",
    "dji",
    "photo",
    "whatsapp",
    "screenshot",
];

static HEX_NAME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[0-9a-f]{8,}([-_][0-9a-f]{4,})*$").expect("a valid pattern"));
static NUMBERED_NAME: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^[a-z]{0,16}[-_. ]?\d{3,}([-_.]\d+)*$").expect("a valid pattern")
});
static DATED_NAME: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(19|20)\d{2}[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])([-_. (]|$)")
        .expect("a valid pattern")
});

/// Machine-made names like "clip_000123" or "3f9a1c0e-…", but not camera names
/// like "IMG_1234" or the dates phones write.
pub fn looks_machine_named(stem: &str) -> bool {
    let name = stem.to_lowercase();
    if CAMERA_PREFIXES.iter().any(|p| name.starts_with(p)) || DATED_NAME.is_match(&name) {
        return false;
    }
    HEX_NAME.is_match(&name) || NUMBERED_NAME.is_match(&name)
}

/// Folders with hundreds of same-kind, machine-named media files: training data,
/// not the person's own. Folders they picked themselves are never datasets.
pub fn dataset_folders(
    files: &[(String, String, FileKind)],
    roots: &HashSet<String>,
    minimum: usize,
) -> HashMap<String, usize> {
    let mut groups: HashMap<(&str, FileKind), Vec<&str>> = HashMap::new();
    for (folder, stem, kind) in files {
        if matches!(kind, FileKind::Image | FileKind::Audio | FileKind::Video)
            && !roots.contains(folder)
        {
            groups.entry((folder, *kind)).or_default().push(stem);
        }
    }
    let mut datasets = HashMap::new();
    for ((folder, _), stems) in groups {
        if stems.len() < minimum {
            continue;
        }
        let machine = stems.iter().filter(|s| looks_machine_named(s)).count();
        if machine as f64 / stems.len() as f64 >= 0.7 {
            *datasets.entry(folder.to_string()).or_insert(0) += stems.len();
        }
    }
    datasets
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn kind(name: &str) -> Classification {
        classify(&PathBuf::from(name), &IndexOptions::default())
    }

    #[test]
    fn classifies_like_the_portable_rules() {
        assert_eq!(kind("notes.txt"), Classification::Index(FileKind::Doc));
        assert_eq!(kind("a.DOCX"), Classification::Index(FileKind::Doc));
        assert_eq!(kind("a.pdf"), Classification::Index(FileKind::Pdf));
        assert_eq!(kind("a.png"), Classification::Index(FileKind::Image));
        assert_eq!(
            kind("Screenshot from 2026-11-02.png"),
            Classification::Index(FileKind::Screenshot)
        );
        assert_eq!(
            kind("Screenshots/2026-02-10_10-10.png"),
            Classification::Index(FileKind::Screenshot)
        );
        assert_eq!(kind("a.mp3"), Classification::Index(FileKind::Audio));
        assert_eq!(kind("a.mkv"), Classification::Index(FileKind::Video));
        assert_eq!(kind("a.rs"), Classification::Skip("code or data file"));
        assert_eq!(kind("a.json"), Classification::Skip("code or data file"));
        assert_eq!(kind("a.m4p"), Classification::Skip("copy-protected"));
        assert_eq!(kind("a.bin"), Classification::Ignore);
        assert_eq!(kind("a.ts"), Classification::Skip("code or data file"));
    }

    #[test]
    fn media_off_excludes_recordings_and_video() {
        let options = IndexOptions::for_settings(false);
        assert_eq!(
            classify(&PathBuf::from("a.mp3"), &options),
            Classification::Skip("excluded type")
        );
        assert_eq!(
            classify(&PathBuf::from("a.txt"), &options),
            Classification::Index(FileKind::Doc)
        );
    }

    #[test]
    fn machine_names() {
        for name in ["clip_000123", "frame-0042", "3f9a1c0e", "000123"] {
            assert!(looks_machine_named(name), "{name}");
        }
        for name in [
            "IMG_1234",
            "20261021_143022",
            "2026-10-21 14.30.22",
            "holiday",
        ] {
            assert!(!looks_machine_named(name), "{name}");
        }
    }

    #[test]
    fn datasets_need_many_machine_named_files_outside_chosen_folders() {
        let files: Vec<(String, String, FileKind)> = (0..300)
            .map(|i| {
                (
                    "/d/set".to_string(),
                    format!("clip_{i:06}"),
                    FileKind::Image,
                )
            })
            .collect();
        let roots = HashSet::new();
        assert_eq!(
            dataset_folders(&files, &roots, 300).get("/d/set"),
            Some(&300)
        );
        let chosen: HashSet<String> = ["/d/set".to_string()].into();
        assert!(dataset_folders(&files, &chosen, 300).is_empty());
        assert!(dataset_folders(&files[..299], &roots, 300).is_empty());
    }

    #[test]
    fn a_cache_tag_needs_its_signature() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("CACHEDIR.TAG"), "nothing").unwrap();
        assert!(!is_cache_directory(dir.path()));
        std::fs::write(
            dir.path().join("CACHEDIR.TAG"),
            "Signature: 8a477f597d28d172789f06886806bc55\n",
        )
        .unwrap();
        assert!(is_cache_directory(dir.path()));
    }
}
