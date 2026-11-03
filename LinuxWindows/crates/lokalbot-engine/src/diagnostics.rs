//! Export Diagnostics (`DiagnosticsExporter.swift`,
//! `DiagnosticsSettingsSanitizer.swift`): recent logs, health reports, settings
//! without secrets, library row counts and capture traces in one zip the person
//! saves themselves. It never reads the meetings folder, screenshots or screen
//! text, so meeting audio, transcripts, notes and screen content can't end up in
//! the archive.

use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use anyhow::{Context as _, Result, bail};
use chrono::{DateTime, Utc};
use lokalbot_core::health::{capture_traces_dir, reports_dir};
use lokalbot_core::time::iso_seconds;
use lokalbot_core::{Library, Settings};
use serde_json::Value;
use zip::write::SimpleFileOptions;

const SECRET_KEY_FRAGMENTS: &[&str] = &[
    "apikey",
    "token",
    "secret",
    "password",
    "credential",
    "authorization",
];
const MAXIMUM_HEALTH_REPORT_DAYS: usize = 14;
const COUNTED_TABLES: &[&str] = &[
    "activity_blocks",
    "screenshots",
    "pipeline_jobs",
    "indexed_meetings",
    "deleted_meetings",
];
const TOP_FOLDER: &str = "LokalBot Diagnostics";

pub fn is_secret_key(key: &str) -> bool {
    let normalized: String = key
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect();
    SECRET_KEY_FRAGMENTS
        .iter()
        .any(|fragment| normalized.contains(fragment))
}

pub use lokalbot_core::control::redact_url;

fn sanitize_value(value: Value, key: Option<&str>) -> Value {
    if key.is_some_and(is_secret_key) {
        return Value::String("<removed>".into());
    }
    match value {
        Value::Object(entries) => Value::Object(
            entries
                .into_iter()
                .map(|(key, value)| {
                    let clean = sanitize_value(value, Some(&key));
                    (key, clean)
                })
                .collect(),
        ),
        Value::Array(items) => Value::Array(
            items
                .into_iter()
                .map(|item| sanitize_value(item, None))
                .collect(),
        ),
        Value::String(text) => Value::String(redact_url(&text)),
        other => other,
    }
}

/// Sorted keys at every depth, as the Mac's `.sortedKeys` writes them.
fn sorted(value: Value) -> Value {
    match value {
        Value::Object(entries) => {
            let ordered: BTreeMap<String, Value> = entries
                .into_iter()
                .map(|(key, value)| (key, sorted(value)))
                .collect();
            Value::Object(ordered.into_iter().collect())
        }
        Value::Array(items) => Value::Array(items.into_iter().map(sorted).collect()),
        other => other,
    }
}

/// Settings without any key that names a credential, and with URLs reduced to
/// their host and path. A deny-list, as on the Mac.
pub fn sanitized_settings(settings: &Settings) -> Result<Vec<u8>> {
    let value = serde_json::to_value(settings)?;
    Ok(serde_json::to_vec_pretty(&sorted(sanitize_value(
        value, None,
    )))?)
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub app_version: String,
    pub build: String,
    #[serde(with = "iso_seconds")]
    pub created_at: DateTime<Utc>,
    pub missing: Vec<String>,
}

/// Row counts only; never row contents.
fn library_counts(library: &Library) -> Option<BTreeMap<String, i64>> {
    let counts = library
        .with_db(|db| {
            let mut counts = BTreeMap::new();
            for table in COUNTED_TABLES {
                // A table this library doesn't have just isn't counted.
                let count = db.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                    row.get::<_, i64>(0)
                });
                if let Ok(count) = count {
                    counts.insert((*table).to_string(), count);
                }
            }
            Ok(counts)
        })
        .ok()?;
    (!counts.is_empty()).then_some(counts)
}

fn files_with_extensions(directory: &Path, extensions: &[&str]) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .filter(|path| {
            path.extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| extensions.contains(&extension))
        })
        .collect();
    files.sort();
    files
}

/// The current log and its rotations.
fn log_files(library: &Library) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(library.paths().logs_dir()) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_file()
                && path
                    .file_name()
                    .is_some_and(|name| name.to_string_lossy().contains(".log"))
        })
        .collect();
    files.sort();
    files
}

/// Writes the archive beside `destination`, then swaps it in: an earlier archive
/// is replaced only once the new one exists. A folder is an error.
pub fn export(library: &Library, settings: &Settings, destination: &Path) -> Result<Manifest> {
    export_at(library, settings, destination, Utc::now())
}

pub fn export_at(
    library: &Library,
    settings: &Settings,
    destination: &Path,
    now: DateTime<Utc>,
) -> Result<Manifest> {
    if destination.is_dir() {
        bail!(
            "{} is a folder. Choose a file name for the diagnostics archive.",
            destination.display()
        );
    }
    let parent = destination
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".lokalbot-diagnostics-{}.zip",
        uuid::Uuid::new_v4().simple()
    ));
    let result = write_archive(library, settings, &temporary, now).and_then(|manifest| {
        std::fs::rename(&temporary, destination)
            .with_context(|| format!("could not save {}", destination.display()))?;
        Ok(manifest)
    });
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

fn write_archive(
    library: &Library,
    settings: &Settings,
    path: &Path,
    now: DateTime<Utc>,
) -> Result<Manifest> {
    let mut archive = zip::ZipWriter::new(std::fs::File::create(path)?);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    let root = library.paths().root();
    let mut missing: Vec<String> = Vec::new();

    let mut copy = |folder: &str, files: Vec<PathBuf>| -> Result<usize> {
        let mut copied = 0;
        for file in files {
            let Ok(bytes) = std::fs::read(&file) else {
                continue;
            };
            let name = file
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
            archive.start_file(format!("{TOP_FOLDER}/{folder}/{name}"), options)?;
            archive.write_all(&bytes)?;
            copied += 1;
        }
        Ok(copied)
    };
    if copy("logs", log_files(library))? == 0 {
        missing.push("logs".into());
    }
    let mut reports = files_with_extensions(&reports_dir(root), &["json", "md"]);
    reports.sort_by(|a, b| b.file_name().cmp(&a.file_name()));
    reports.truncate(MAXIMUM_HEALTH_REPORT_DAYS * 2);
    if copy("health", reports)? == 0 {
        missing.push("health reports".into());
    }
    let traces = files_with_extensions(&capture_traces_dir(root), &["json"]);
    if copy("capture-traces", traces)? == 0 {
        missing.push("capture traces".into());
    }

    let mut add = |name: &str, bytes: &[u8]| -> Result<()> {
        archive.start_file(format!("{TOP_FOLDER}/{name}"), options)?;
        archive.write_all(bytes)?;
        Ok(())
    };
    match sanitized_settings(settings) {
        Ok(bytes) => add("settings.json", &bytes)?,
        Err(_) => missing.push("settings".into()),
    }
    match library_counts(library) {
        Some(counts) => add("counts.json", &serde_json::to_vec_pretty(&counts)?)?,
        None => missing.push("library counts".into()),
    }
    let manifest = Manifest {
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        build: if cfg!(debug_assertions) {
            "debug".into()
        } else {
            "release".into()
        },
        created_at: now,
        missing,
    };
    add("manifest.json", &serde_json::to_vec_pretty(&manifest)?)?;
    archive.finish()?;
    Ok(manifest)
}

#[cfg(test)]
mod tests {
    use std::io::Read as _;

    use super::*;

    #[test]
    fn secret_keys_go_at_any_depth_and_urls_lose_their_credentials() {
        assert!(is_secret_key("openAIAPIKey"));
        assert!(is_secret_key("chatgpt_refresh-token"));
        assert!(is_secret_key("ClientSecret"));
        assert!(is_secret_key("dbPassword"));
        assert!(is_secret_key("someCredentials"));
        assert!(is_secret_key("Authorization"));
        assert!(!is_secret_key("retentionDays"));
        let cleaned = sanitize_value(
            serde_json::json!({
                "retentionDays": 14,
                "apiKey": "sk-abc",
                "nested": {"authToken": {"value": "x"}, "items": [{"password": "y", "ok": "z"}]},
                "server": "https://user:hunter2@example.com:8443/v1/path?key=abc#frag",
                "plain": "not a :// url with spaces",
            }),
            None,
        );
        assert_eq!(cleaned["retentionDays"], 14);
        assert_eq!(cleaned["apiKey"], "<removed>");
        assert_eq!(cleaned["nested"]["authToken"], "<removed>");
        assert_eq!(cleaned["nested"]["items"][0]["password"], "<removed>");
        assert_eq!(cleaned["nested"]["items"][0]["ok"], "z");
        assert_eq!(cleaned["server"], "https://example.com:8443/v1/path");
        assert_eq!(cleaned["plain"], "not a :// url with spaces");
        assert_eq!(redact_url("hello"), "hello");
        assert_eq!(redact_url("://nohost"), "://nohost");
        assert_eq!(redact_url("file:///tmp/x"), "file:///tmp/x");
        assert_eq!(redact_url("http://host"), "http://host");
    }

    #[test]
    fn settings_leave_without_keys_or_url_credentials_and_with_sorted_keys() {
        let settings = Settings {
            openai_base_url: "https://me:pw@api.example.com/v1?token=abc".into(),
            ..Settings::default()
        };
        let text = String::from_utf8(sanitized_settings(&settings).unwrap()).unwrap();
        assert!(!text.contains("pw@") && !text.contains("token=abc"));
        assert!(text.contains("https://api.example.com/v1"));
        assert!(text.find("\"appLanguage\"").unwrap() < text.find("\"retentionDays\"").unwrap());
    }

    fn entries(path: &Path) -> BTreeMap<String, String> {
        let mut archive = zip::ZipArchive::new(std::fs::File::open(path).unwrap()).unwrap();
        (0..archive.len())
            .map(|index| {
                let mut file = archive.by_index(index).unwrap();
                let mut text = String::new();
                file.read_to_string(&mut text).unwrap();
                (file.name().unwrap().to_string(), text)
            })
            .collect()
    }

    #[test]
    fn the_archive_holds_the_macs_layout_and_no_library_content() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let library = Library::open(lokalbot_core::LibraryPaths::new(&root)).unwrap();
        let meeting = library
            .create_meeting("Secret plans", "Zoom", Utc::now())
            .unwrap();
        std::fs::write(
            library.meeting_dir(&meeting).join("summary.md"),
            "PRIVATE SUMMARY",
        )
        .unwrap();
        std::fs::create_dir_all(library.paths().logs_dir()).unwrap();
        std::fs::write(
            library.paths().logs_dir().join("lokalbot.log"),
            "a log line",
        )
        .unwrap();
        std::fs::write(library.paths().logs_dir().join("lokalbot.log.1"), "older").unwrap();
        let health = reports_dir(&root);
        std::fs::create_dir_all(&health).unwrap();
        for index in 0..40 {
            std::fs::write(health.join(format!("2026-01-{index:02}.json")), "{}").unwrap();
        }
        let destination = dir.path().join("out/diag.zip");
        let manifest = export(&library, &Settings::default(), &destination).unwrap();
        assert_eq!(manifest.missing, vec!["capture traces".to_string()]);
        let files = entries(&destination);
        assert!(files.contains_key("LokalBot Diagnostics/logs/lokalbot.log"));
        assert!(files.contains_key("LokalBot Diagnostics/logs/lokalbot.log.1"));
        assert!(files.contains_key("LokalBot Diagnostics/settings.json"));
        assert!(files.contains_key("LokalBot Diagnostics/counts.json"));
        // The newest 28 reports.
        let reports = files
            .keys()
            .filter(|name| name.contains("/health/"))
            .count();
        assert_eq!(reports, 28);
        assert!(files.contains_key("LokalBot Diagnostics/health/2026-01-39.json"));
        assert!(!files.contains_key("LokalBot Diagnostics/health/2026-01-11.json"));
        let manifest: Value =
            serde_json::from_str(&files["LokalBot Diagnostics/manifest.json"]).unwrap();
        assert!(manifest["createdAt"].as_str().unwrap().ends_with('Z'));
        assert_eq!(manifest["appVersion"], env!("CARGO_PKG_VERSION"));
        let counts: Value =
            serde_json::from_str(&files["LokalBot Diagnostics/counts.json"]).unwrap();
        assert_eq!(counts["activity_blocks"], 0);
        for (name, contents) in &files {
            assert!(!contents.contains("PRIVATE SUMMARY"), "{name} leaked");
            assert!(!contents.contains("Secret plans"), "{name} leaked");
        }
        // A second export replaces the first; nothing else is left beside it.
        export(&library, &Settings::default(), &destination).unwrap();
        assert_eq!(
            std::fs::read_dir(dir.path().join("out")).unwrap().count(),
            1
        );
        // A folder is refused and left alone.
        assert!(export(&library, &Settings::default(), dir.path()).is_err());
    }
}
