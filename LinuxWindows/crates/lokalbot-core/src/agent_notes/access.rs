//! The Agent notes grant for external agents (`AgentNotesAccessGate`): a marker
//! the app sets from Settings → Privacy & Data. `lokalbot-cli` and its MCP
//! server search the saved notes themselves, without the app running, and find
//! none while Read coding agent notes is off, because turning that off deletes
//! them. Separate from every other grant; no Agent Mode capability satisfies it.

use std::path::PathBuf;

use anyhow::{Result, bail};

use crate::access::{ensure_private_dir, restrict_file};
use crate::paths::LibraryPaths;

pub const MARKER: &str = "agent-notes-access-enabled";

fn marker_path(paths: &LibraryPaths) -> PathBuf {
    paths.control_dir().join(MARKER)
}

pub fn is_enabled(paths: &LibraryPaths) -> bool {
    marker_path(paths).is_file()
}

pub fn set_enabled(paths: &LibraryPaths, enabled: bool) -> Result<()> {
    let marker = marker_path(paths);
    if enabled {
        ensure_private_dir(&paths.control_dir())?;
        crate::library::write_atomic(&marker, uuid::Uuid::new_v4().to_string().as_bytes())?;
        restrict_file(&marker);
    } else {
        match std::fs::remove_file(&marker) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
                bail!("LokalBot couldn't turn off agent-notes access: {err}")
            }
            _ => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_grant_is_its_own_marker() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        assert!(!is_enabled(&paths));

        // No other grant turns it on.
        crate::access::set_meetings_access(&paths, true).unwrap();
        crate::files::access::set_enabled(&paths, true).unwrap();
        assert!(!is_enabled(&paths));

        set_enabled(&paths, true).unwrap();
        assert!(is_enabled(&paths));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(marker_path(&paths))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        assert!(
            !crate::agent_notes::NotesIndex::new(dir.path()).exists(),
            "granting never creates the saved copy"
        );

        set_enabled(&paths, false).unwrap();
        assert!(!is_enabled(&paths));
        set_enabled(&paths, false).unwrap();
        assert!(crate::access::meetings_access_enabled(&paths));
    }
}
