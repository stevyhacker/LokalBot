//! The Files grant for external agents (`FilesAccessGate`, `FilesAccessManager`):
//! a marker the app sets from Settings → AI agents or Settings → Files,
//! plus a list of the chosen folders, so the CLI and its MCP server can search
//! the index with the app closed and without reading the app's settings. Separate
//! from every other grant; no Agent Mode capability satisfies it.

use std::path::{Path, PathBuf};

use anyhow::{Result, bail};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

use crate::access::ensure_private_dir;
use crate::paths::LibraryPaths;

pub const MARKER: &str = "files-access-enabled";
pub const PROJECTION: &str = "files-access.json";
const CURRENT_VERSION: u32 = 1;

/// What Files lets agents search, as the app last wrote it. Keys sort the way
/// the Mac writes them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FilesProjection {
    pub folders: Vec<String>,
    #[serde(serialize_with = "iso8601_seconds", deserialize_with = "from_iso8601")]
    pub generated_at: DateTime<Utc>,
    pub version: u32,
}

fn iso8601_seconds<S: serde::Serializer>(at: &DateTime<Utc>, out: S) -> Result<S::Ok, S::Error> {
    out.serialize_str(&at.to_rfc3339_opts(SecondsFormat::Secs, true))
}

fn from_iso8601<'de, D: serde::Deserializer<'de>>(input: D) -> Result<DateTime<Utc>, D::Error> {
    let text = String::deserialize(input)?;
    DateTime::parse_from_rfc3339(&text)
        .map(|at| at.with_timezone(&Utc))
        .map_err(serde::de::Error::custom)
}

fn marker_path(paths: &LibraryPaths) -> PathBuf {
    paths.control_dir().join(MARKER)
}

fn projection_path(paths: &LibraryPaths) -> PathBuf {
    paths.control_dir().join(PROJECTION)
}

pub fn is_enabled(paths: &LibraryPaths) -> bool {
    marker_path(paths).is_file()
}

fn restrict(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    let _ = path;
}

/// Turns the grant on or off. Revoking removes the folder list too.
pub fn set_enabled(paths: &LibraryPaths, enabled: bool) -> Result<()> {
    let marker = marker_path(paths);
    if enabled {
        ensure_private_dir(&paths.control_dir())?;
        crate::library::write_atomic(&marker, uuid::Uuid::new_v4().to_string().as_bytes())?;
        restrict(&marker);
    } else {
        remove_projection(paths);
        match std::fs::remove_file(&marker) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
                bail!("LokalBot couldn't turn off file access: {err}")
            }
            _ => {}
        }
    }
    Ok(())
}

pub fn remove_projection(paths: &LibraryPaths) {
    let _ = std::fs::remove_file(projection_path(paths));
}

/// The chosen folders, or `None` when the grant is off, Files is off, or the app
/// hasn't written them.
pub fn read_projection(paths: &LibraryPaths) -> Option<FilesProjection> {
    if !is_enabled(paths) {
        return None;
    }
    let bytes = std::fs::read(projection_path(paths)).ok()?;
    let projection: FilesProjection = serde_json::from_slice(&bytes).ok()?;
    (projection.version <= CURRENT_VERSION && !projection.folders.is_empty()).then_some(projection)
}

fn write_projection(paths: &LibraryPaths, projection: &FilesProjection) -> Result<()> {
    ensure_private_dir(&paths.control_dir())?;
    let path = projection_path(paths);
    let json = serde_json::to_vec_pretty(projection)?;
    crate::library::write_atomic(&path, &json)?;
    restrict(&path);
    Ok(())
}

/// Files' settings changed: rewrite the folder list, or remove it
/// (`FilesAccessManager.refresh`). `folders` is `None` while Files is off.
pub fn refresh(paths: &LibraryPaths, folders: Option<&[String]>) -> Result<()> {
    let chosen = match folders {
        Some(chosen) if is_enabled(paths) && !chosen.is_empty() => chosen,
        _ => {
            remove_projection(paths);
            return Ok(());
        }
    };
    if read_projection(paths).is_some_and(|known| known.folders == chosen) {
        return Ok(());
    }
    let result = write_projection(
        paths,
        &FilesProjection {
            folders: chosen.to_vec(),
            generated_at: Utc::now(),
            version: CURRENT_VERSION,
        },
    );
    if result.is_err() {
        remove_projection(paths);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths() -> (tempfile::TempDir, LibraryPaths) {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        (dir, paths)
    }

    #[test]
    fn the_list_exists_only_while_the_grant_and_files_are_on() {
        let (_dir, paths) = paths();
        let folders = vec!["/home/me/Documents".to_string()];
        refresh(&paths, Some(&folders)).unwrap();
        assert!(!projection_path(&paths).exists(), "no grant, no list");

        set_enabled(&paths, true).unwrap();
        assert!(
            read_projection(&paths).is_none(),
            "granted, list not written"
        );
        refresh(&paths, Some(&folders)).unwrap();
        assert_eq!(read_projection(&paths).unwrap().folders, folders);

        refresh(&paths, None).unwrap();
        assert!(read_projection(&paths).is_none(), "Files off removes it");
        refresh(&paths, Some(&[])).unwrap();
        assert!(read_projection(&paths).is_none(), "no folders removes it");

        refresh(&paths, Some(&folders)).unwrap();
        set_enabled(&paths, false).unwrap();
        assert!(!marker_path(&paths).exists());
        assert!(
            !projection_path(&paths).exists(),
            "revoking removes the list"
        );
    }

    #[test]
    fn reads_and_writes_the_macs_json() {
        let (_dir, paths) = paths();
        set_enabled(&paths, true).unwrap();
        ensure_private_dir(&paths.control_dir()).unwrap();
        // `JSONEncoder` with sorted keys, ISO 8601 dates and unescaped slashes.
        let mac = r#"{
  "folders" : [
    "/Users/me/Documents"
  ],
  "generatedAt" : "2026-10-31T09:15:00Z",
  "version" : 1
}"#;
        std::fs::write(projection_path(&paths), mac).unwrap();
        let read = read_projection(&paths).unwrap();
        assert_eq!(read.folders, ["/Users/me/Documents"]);
        assert_eq!(
            read.generated_at.to_rfc3339_opts(SecondsFormat::Secs, true),
            "2026-10-31T09:15:00Z"
        );
        let written = serde_json::to_string(&read).unwrap();
        assert_eq!(
            written,
            r#"{"folders":["/Users/me/Documents"],"generatedAt":"2026-10-31T09:15:00Z","version":1}"#
        );
        // A newer version isn't trusted.
        std::fs::write(
            projection_path(&paths),
            r#"{"folders":["/x"],"generatedAt":"2026-10-31T09:15:00Z","version":2}"#,
        )
        .unwrap();
        assert!(read_projection(&paths).is_none());
    }
}
