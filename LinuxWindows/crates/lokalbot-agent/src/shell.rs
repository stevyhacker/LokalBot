use std::path::{Path, PathBuf};

use anyhow::Result;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ShellChoice {
    Default,
    Bash(PathBuf),
    PowerShell,
}

pub const POWERSHELL_TOOLS: [&str; 4] = ["read", "powershell", "edit", "write"];

impl ShellChoice {
    pub fn detect() -> ShellChoice {
        #[cfg(windows)]
        {
            windows_bash().map_or(ShellChoice::PowerShell, ShellChoice::Bash)
        }
        #[cfg(not(windows))]
        {
            ShellChoice::Default
        }
    }

    pub fn tools(&self) -> Option<&'static [&'static str]> {
        match self {
            ShellChoice::PowerShell => Some(&POWERSHELL_TOOLS),
            _ => None,
        }
    }

    pub fn description(&self) -> String {
        match self {
            ShellChoice::Default => "Commands run in Bash.".into(),
            ShellChoice::Bash(path) => format!("Commands run in Bash ({}).", path.display()),
            ShellChoice::PowerShell => "Git for Windows isn't installed, so commands run in PowerShell. Install Git for Windows to give the agent Bash, then start a new task.".into(),
        }
    }

    pub fn apply(&self, pi_config: &Path) -> Result<()> {
        let file = pi_config.join("settings.json");
        let mut settings: serde_json::Map<String, serde_json::Value> = std::fs::read(&file)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        let before = settings.clone();
        match self {
            ShellChoice::Bash(path) => {
                settings.insert(
                    "shellPath".into(),
                    serde_json::Value::String(path.to_string_lossy().into_owned()),
                );
            }
            ShellChoice::Default | ShellChoice::PowerShell => {
                settings.remove("shellPath");
            }
        }
        if settings == before && file.exists() {
            return Ok(());
        }
        if settings.is_empty() && !file.exists() {
            return Ok(());
        }
        crate::fsutil::create_private_dir(pi_config)?;
        lokalbot_core::library::write_atomic(&file, &serde_json::to_vec_pretty(&settings)?)?;
        Ok(())
    }
}

#[cfg(windows)]
fn windows_bash() -> Option<PathBuf> {
    let program_files = ["ProgramFiles", "ProgramFiles(x86)"]
        .into_iter()
        .filter_map(std::env::var_os)
        .map(|dir| PathBuf::from(dir).join("Git").join("bin").join("bash.exe"));
    let on_path = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .unwrap_or_default()
        .into_iter()
        .map(|dir| dir.join("bash.exe"))
        .filter(|candidate| !is_wsl_launcher(candidate));
    program_files
        .chain(on_path)
        .find(|candidate| candidate.is_file())
}

#[cfg_attr(not(windows), allow(dead_code))]
fn is_wsl_launcher(candidate: &Path) -> bool {
    let lower = candidate
        .to_string_lossy()
        .to_lowercase()
        .replace('/', "\\");
    lower.contains("\\windows\\system32\\")
        || lower.contains("\\windows\\sysnative\\")
        || lower.contains("\\windowsapps\\")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wsl_launchers_are_never_chosen() {
        assert!(is_wsl_launcher(Path::new(r"C:\WINDOWS\system32\bash.exe")));
        assert!(is_wsl_launcher(Path::new(
            r"C:\Users\x\AppData\Local\Microsoft\WindowsApps\bash.exe"
        )));
        assert!(!is_wsl_launcher(Path::new(
            r"C:\Program Files\Git\bin\bash.exe"
        )));
        assert!(!is_wsl_launcher(Path::new(r"C:\msys64\usr\bin\bash.exe")));
    }

    #[test]
    fn powershell_replaces_the_bash_tool() {
        assert_eq!(
            ShellChoice::PowerShell.tools(),
            Some(&["read", "powershell", "edit", "write"][..])
        );
        assert_eq!(ShellChoice::Default.tools(), None);
        assert_eq!(ShellChoice::Bash(PathBuf::from("/bin/bash")).tools(), None);
    }

    #[test]
    fn shell_path_is_pinned_and_cleared_in_pi_settings() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("settings.json");
        std::fs::write(&file, r#"{"keep": 1}"#).unwrap();
        ShellChoice::Bash(PathBuf::from("/opt/bash"))
            .apply(dir.path())
            .unwrap();
        let written: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(written["shellPath"], "/opt/bash");
        assert_eq!(written["keep"], 1);
        ShellChoice::PowerShell.apply(dir.path()).unwrap();
        let written: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert!(written.get("shellPath").is_none());
        let empty = tempfile::tempdir().unwrap();
        ShellChoice::Default.apply(empty.path()).unwrap();
        assert!(!empty.path().join("settings.json").exists());
    }
}
