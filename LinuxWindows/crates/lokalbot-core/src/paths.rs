use std::path::{Path, PathBuf};

pub const STORAGE_ROOT_ENV: &str = "LOKALBOT_STORAGE_ROOT";
pub const STORAGE_ROOT_FLAG: &str = "--lokalbot-storage-root";

const LIBRARY_FOLDER: &str = "LokalBot";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LibraryPaths {
    root: PathBuf,
}

impl LibraryPaths {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn resolve(explicit: Option<&Path>) -> Self {
        if let Some(path) = explicit {
            return Self::new(path);
        }
        if let Some(path) = std::env::var_os(STORAGE_ROOT_ENV).filter(|v| !v.is_empty()) {
            return Self::new(PathBuf::from(path));
        }
        Self::new(Self::default_root())
    }

    pub fn root_from_args<I, S>(args: I) -> Option<PathBuf>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            let arg = arg.as_ref();
            if arg == STORAGE_ROOT_FLAG {
                return args.next().map(|v| PathBuf::from(v.as_ref()));
            }
            if let Some(value) = arg
                .strip_prefix(STORAGE_ROOT_FLAG)
                .and_then(|r| r.strip_prefix('='))
            {
                return Some(PathBuf::from(value));
            }
        }
        None
    }

    pub fn default_root() -> PathBuf {
        directories::BaseDirs::new()
            .map(|dirs| dirs.data_local_dir().join(LIBRARY_FOLDER))
            .unwrap_or_else(|| PathBuf::from(LIBRARY_FOLDER))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn meetings_dir(&self) -> PathBuf {
        self.root.join("meetings")
    }

    pub fn database(&self) -> PathBuf {
        self.root.join("lokalbotv3.sqlite")
    }

    pub fn settings_file(&self) -> PathBuf {
        self.root.join("settings.json")
    }

    pub fn journal_dir(&self) -> PathBuf {
        self.root.join("journal")
    }

    pub fn models_dir(&self) -> PathBuf {
        self.root.join("models")
    }

    pub fn runtimes_dir(&self) -> PathBuf {
        self.root.join("runtimes")
    }

    pub fn chats_dir(&self) -> PathBuf {
        self.root.join("chats")
    }

    pub fn people_dir(&self) -> PathBuf {
        self.root.join("people")
    }

    pub fn projects_dir(&self) -> PathBuf {
        self.root.join("projects")
    }

    pub fn control_dir(&self) -> PathBuf {
        self.root.join("control")
    }

    pub fn logs_dir(&self) -> PathBuf {
        self.root.join("logs")
    }

    pub fn instance_lock(&self) -> PathBuf {
        self.root.join(".instance.lock")
    }

    pub fn meeting_dir(&self, relative_path: &str) -> PathBuf {
        let mut path = self.root.clone();
        for part in relative_path.split(['/', '\\']).filter(|p| !p.is_empty()) {
            path.push(part);
        }
        path
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flag_forms_are_recognised() {
        assert_eq!(
            LibraryPaths::root_from_args(["app", "--lokalbot-storage-root", "/tmp/a"]),
            Some(PathBuf::from("/tmp/a"))
        );
        assert_eq!(
            LibraryPaths::root_from_args(["app", "--lokalbot-storage-root=/tmp/b"]),
            Some(PathBuf::from("/tmp/b"))
        );
        assert_eq!(LibraryPaths::root_from_args(["app"]), None);
    }

    #[test]
    fn meeting_dir_accepts_both_separators() {
        let paths = LibraryPaths::new("/lib");
        assert_eq!(
            paths.meeting_dir("meetings/2026/10/15-call"),
            PathBuf::from("/lib/meetings/2026/10/15-call")
        );
        assert_eq!(
            paths.meeting_dir("meetings\\2026\\10\\15-call"),
            PathBuf::from("/lib/meetings/2026/10/15-call")
        );
    }
}
