//! `install-skill` (`LokalBotCLIInstaller.swift`) for Linux and Windows.
//!
//! Linux: `~/.local/bin/lokalbot-cli` links to this binary; the skill is
//! written once under `~/.local/share/lokalbot-cli/skill` and linked from
//! `~/.agents/skills/lokalbot-cli` and `~/.claude/skills/lokalbot-cli`
//! (copied with `--copy`). Windows: the binary is copied to
//! `%LOCALAPPDATA%\Programs\LokalBot\bin` and the skill copied into the same
//! skill folders under `%USERPROFILE%`. When this binary already sits at the
//! command path (`packaging/linux/install.sh` copies it there and the app runs
//! it from there), or an identical copy does, it is left in place and only the
//! skill is written. Paths this installer does not own are never replaced.

use std::path::{Path, PathBuf};

use anyhow::{Context as _, Result, bail};

/// The bundled agent skill (the macOS app ships the same file).
pub const SKILL: &str = include_str!("../../../../.agents/skills/lokalbot-cli/SKILL.md");
pub const COPY_MARKER: &str = ".lokalbot-skill-copy";
const PATH_EXPORT_LINE: &str = "export PATH=\"$HOME/.local/bin:$PATH\"";

/// Where `install-skill` puts the command for `home`:
/// `~/.local/bin/lokalbot-cli` on Linux and
/// `%LOCALAPPDATA%\Programs\LokalBot\bin\lokalbot-cli.exe` on Windows, outside
/// the library folder.
pub fn command_path(home: &Path) -> PathBuf {
    if cfg!(windows) {
        std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join("AppData").join("Local"))
            .join("Programs")
            .join("LokalBot")
            .join("bin")
            .join("lokalbot-cli.exe")
    } else {
        home.join(".local").join("bin").join("lokalbot-cli")
    }
}

/// [`command_path`] for the current user, which the app shows in Settings and
/// in its MCP setup commands.
pub fn command_path_for_current_user() -> Option<PathBuf> {
    directories::BaseDirs::new().map(|d| command_path(d.home_dir()))
}

/// [`Installer::is_installed`] for the current user (the Agent CLI status in
/// Settings).
pub fn installed_for_current_user() -> bool {
    directories::BaseDirs::new()
        .is_some_and(|d| Installer::new(d.home_dir().to_path_buf(), PathBuf::new()).is_installed())
}

pub struct Installer {
    pub home: PathBuf,
    /// The binary to install (this executable).
    pub binary: PathBuf,
    /// Where the installed command lives.
    pub bin_link: PathBuf,
    /// The skill source folder owned by the installer (link mode).
    pub skill_source: PathBuf,
    pub skill_link: PathBuf,
    pub claude_skill_link: PathBuf,
}

impl Installer {
    pub fn for_current_user() -> Result<Self> {
        let home = directories::BaseDirs::new()
            .map(|d| d.home_dir().to_path_buf())
            .context("could not find the home folder")?;
        let binary = std::env::current_exe()
            .and_then(|p| p.canonicalize())
            .context("could not find this executable")?;
        Ok(Self::new(home, binary))
    }

    pub fn new(home: PathBuf, binary: PathBuf) -> Self {
        let bin_link = command_path(&home);
        Self {
            skill_source: home
                .join(".local")
                .join("share")
                .join("lokalbot-cli")
                .join("skill")
                .join("lokalbot-cli"),
            skill_link: home.join(".agents").join("skills").join("lokalbot-cli"),
            claude_skill_link: home.join(".claude").join("skills").join("lokalbot-cli"),
            bin_link,
            home,
            binary,
        }
    }

    /// The skill with this platform's paths in place of the macOS ones.
    pub fn skill_text(&self) -> String {
        SKILL
            .replace(
                "LokalBot is a private work-memory app for macOS.",
                "LokalBot is a private work-memory app for Linux and Windows.",
            )
            .replace(
                "/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli",
                &self.bin_link.to_string_lossy(),
            )
    }

    pub fn bin_dir_on_path(&self) -> bool {
        let Some(dir) = self.bin_link.parent() else {
            return false;
        };
        std::env::var_os("PATH").is_some_and(|path| std::env::split_paths(&path).any(|p| p == dir))
    }

    fn is_owned(&self, path: &Path) -> bool {
        if let Ok(target) = std::fs::read_link(path) {
            let name = target.file_name().and_then(|n| n.to_str()).unwrap_or("");
            return if path == self.bin_link {
                name == "lokalbot-cli" || name == "lokalbot-cli.exe"
            } else {
                target == self.skill_source
            };
        }
        if path == self.bin_link {
            // Windows installs a copy into a folder only this installer uses.
            return cfg!(windows) && path.is_file();
        }
        path.is_dir() && path.join(COPY_MARKER).is_file()
    }

    fn exists(path: &Path) -> bool {
        path.exists() || std::fs::symlink_metadata(path).is_ok()
    }

    /// Whether `install-skill` has run: the command is there and so is a skill
    /// this installer wrote. install.sh puts the command in place without the
    /// skill, so the command alone does not count.
    pub fn is_installed(&self) -> bool {
        self.bin_link.is_file()
            && [&self.skill_link, &self.claude_skill_link]
                .into_iter()
                .any(|skill| self.is_owned(skill) && skill.join("SKILL.md").is_file())
    }

    /// Whether the command path already runs this binary: it is the same file
    /// (install.sh's copy that the app runs, or an earlier link to it), or a
    /// regular file with the same contents. Either way it is left as it is.
    fn binary_in_place(&self) -> bool {
        let Ok(installed) = std::fs::canonicalize(&self.bin_link) else {
            return false;
        };
        if std::fs::canonicalize(&self.binary).is_ok_and(|binary| binary == installed) {
            return true;
        }
        std::fs::symlink_metadata(&self.bin_link).is_ok_and(|m| m.file_type().is_file())
            && same_contents(&self.binary, &self.bin_link).unwrap_or(false)
    }

    fn require_owned_or_missing(&self, path: &Path) -> Result<()> {
        if Self::exists(path) && !self.is_owned(path) {
            let hint = if path == self.bin_link && cfg!(unix) {
                " If an older LokalBot install.sh put it there, run install.sh from this version instead."
            } else {
                ""
            };
            bail!(
                "LokalBot did not replace {} because it is not owned by this installer. Move it to another location before installing.{hint}",
                path.display()
            );
        }
        Ok(())
    }

    fn remove(path: &Path) -> std::io::Result<()> {
        let metadata = std::fs::symlink_metadata(path)?;
        if metadata.is_dir() {
            std::fs::remove_dir_all(path)
        } else {
            std::fs::remove_file(path)
        }
    }

    fn write_skill_copy(&self, folder: &Path) -> Result<()> {
        std::fs::create_dir_all(folder)?;
        std::fs::write(folder.join("SKILL.md"), self.skill_text())?;
        std::fs::write(folder.join(COPY_MARKER), b"")?;
        Ok(())
    }

    pub fn install(&self, copy: bool) -> Result<()> {
        let keep_binary = self.binary_in_place();
        let mut destinations = vec![&self.skill_link, &self.claude_skill_link];
        if !keep_binary {
            destinations.insert(0, &self.bin_link);
        }
        for destination in &destinations {
            self.require_owned_or_missing(destination)?;
        }
        for destination in destinations {
            if let Some(parent) = destination.parent() {
                std::fs::create_dir_all(parent)
                    .with_context(|| format!("Could not create {}", parent.display()))?;
            }
            if Self::exists(destination) {
                Self::remove(destination)
                    .with_context(|| format!("Could not replace {}", destination.display()))?;
            }
        }
        let link_mode = !copy && cfg!(unix);
        if !keep_binary {
            if cfg!(windows) {
                std::fs::copy(&self.binary, &self.bin_link)
                    .with_context(|| format!("Could not install at {}", self.bin_link.display()))?;
            } else {
                symlink(&self.binary, &self.bin_link)?;
            }
        }
        if link_mode {
            std::fs::create_dir_all(&self.skill_source)?;
            std::fs::write(self.skill_source.join("SKILL.md"), self.skill_text())?;
            symlink(&self.skill_source, &self.skill_link)?;
            symlink(&self.skill_source, &self.claude_skill_link)?;
        } else {
            self.write_skill_copy(&self.skill_link)?;
            self.write_skill_copy(&self.claude_skill_link)?;
        }
        Ok(())
    }

    /// Removes only what this installer created.
    pub fn uninstall(&self) -> Result<()> {
        for path in [&self.bin_link, &self.skill_link, &self.claude_skill_link] {
            if self.is_owned(path) {
                Self::remove(path)
                    .with_context(|| format!("Could not remove {}", path.display()))?;
            }
        }
        if self.skill_source.is_dir() {
            let _ = std::fs::remove_dir_all(&self.skill_source);
        }
        Ok(())
    }

    /// The text `install-skill` prints.
    pub fn installed_message(&self) -> String {
        let mut text = format!(
            "Installed:\n  {}\n  {}\n  {}\n\nClaude Code picks the skill up automatically; point other agents\nat one of the skill directories above.\n\nMCP clients (Claude Desktop, ...) can add the same library with:\n  claude mcp add lokalbot -- {} mcp",
            self.bin_link.display(),
            self.skill_link.display(),
            self.claude_skill_link.display(),
            self.bin_link.display()
        );
        if !self.bin_dir_on_path() {
            if cfg!(windows) {
                let dir = self
                    .bin_link
                    .parent()
                    .map(|p| p.display().to_string())
                    .unwrap_or_default();
                text.push_str(&format!(
                    "\n\nNote: {dir} isn't on your PATH. Add it in PowerShell with:\n  [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ';{dir}', 'User')"
                ));
            } else {
                let rc = if std::env::var("SHELL").is_ok_and(|s| s.ends_with("zsh")) {
                    "~/.zshrc"
                } else {
                    "~/.bashrc"
                };
                text.push_str(&format!(
                    "\n\nNote: ~/.local/bin isn't on your PATH. Add it with:\n  echo '{PATH_EXPORT_LINE}' >> {rc}"
                ));
            }
        }
        text
    }
}

/// Compares two files byte for byte without reading either one whole.
fn same_contents(a: &Path, b: &Path) -> std::io::Result<bool> {
    use std::io::Read as _;
    let (mut a, mut b) = (std::fs::File::open(a)?, std::fs::File::open(b)?);
    if a.metadata()?.len() != b.metadata()?.len() {
        return Ok(false);
    }
    let (mut left, mut right) = (vec![0u8; 64 * 1024], vec![0u8; 64 * 1024]);
    loop {
        let read = a.read(&mut left)?;
        if read == 0 {
            return Ok(true);
        }
        b.read_exact(&mut right[..read])?;
        if left[..read] != right[..read] {
            return Ok(false);
        }
    }
}

#[cfg(unix)]
fn symlink(target: &Path, link: &Path) -> Result<()> {
    std::os::unix::fs::symlink(target, link)
        .with_context(|| format!("Could not link {}", link.display()))
}

#[cfg(not(unix))]
fn symlink(target: &Path, link: &Path) -> Result<()> {
    std::fs::copy(target, link)
        .with_context(|| format!("Could not install at {}", link.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An installer with every path inside `dir`, so a test never touches the
    /// real home folder or `%LOCALAPPDATA%`.
    fn installer_in(dir: &Path, binary: PathBuf) -> Installer {
        let home = dir.join("home");
        let mut installer = Installer::new(home.clone(), binary);
        installer.bin_link = home.join("bin").join(if cfg!(windows) {
            "lokalbot-cli.exe"
        } else {
            "lokalbot-cli"
        });
        installer
    }

    fn write(path: &Path, contents: &[u8]) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, contents).unwrap();
    }

    #[test]
    fn command_path_is_the_one_install_uses() {
        let home = PathBuf::from("home");
        let path = command_path(&home);
        assert_eq!(Installer::new(home.clone(), PathBuf::new()).bin_link, path);
        if cfg!(windows) {
            let tail: PathBuf = ["Programs", "LokalBot", "bin", "lokalbot-cli.exe"]
                .iter()
                .collect();
            assert!(path.ends_with(tail), "{}", path.display());
        } else {
            assert_eq!(path, home.join(".local").join("bin").join("lokalbot-cli"));
        }
    }

    #[test]
    fn keeps_the_binary_that_already_sits_at_the_command_path() {
        // install.sh copies lokalbot-cli to the command path and the app runs
        // that copy with `install-skill`.
        let dir = tempfile::tempdir().unwrap();
        let mut installer = installer_in(dir.path(), PathBuf::new());
        write(&installer.bin_link, b"bin");
        installer.binary = installer.bin_link.clone();
        installer.install(false).unwrap();
        installer.install(false).unwrap();
        let metadata = std::fs::symlink_metadata(&installer.bin_link).unwrap();
        assert!(metadata.file_type().is_file());
        assert_eq!(std::fs::read(&installer.bin_link).unwrap(), b"bin");
        assert!(installer.skill_link.join("SKILL.md").is_file());
        assert!(installer.claude_skill_link.join("SKILL.md").is_file());
        installer.uninstall().unwrap();
        assert!(!Installer::exists(&installer.skill_link));
        if cfg!(unix) {
            // install.sh's copy is left for `install.sh --uninstall`.
            assert_eq!(std::fs::read(&installer.bin_link).unwrap(), b"bin");
        }
    }

    #[test]
    fn keeps_an_identical_copy_at_the_command_path() {
        // install.sh's copy while the app runs from the extracted archive.
        let dir = tempfile::tempdir().unwrap();
        let binary = dir.path().join("archive").join("lokalbot-cli");
        write(&binary, b"bin");
        let installer = installer_in(dir.path(), binary);
        write(&installer.bin_link, b"bin");
        installer.install(false).unwrap();
        let metadata = std::fs::symlink_metadata(&installer.bin_link).unwrap();
        assert!(metadata.file_type().is_file());
        assert!(installer.claude_skill_link.join("SKILL.md").is_file());
    }

    #[test]
    fn installed_needs_the_command_and_this_installers_skill() {
        let dir = tempfile::tempdir().unwrap();
        let mut installer = installer_in(dir.path(), PathBuf::new());
        assert!(!installer.is_installed());
        // install.sh's copy alone is not an installed Agent CLI.
        write(&installer.bin_link, b"bin");
        assert!(!installer.is_installed());
        installer.binary = installer.bin_link.clone();
        installer.install(false).unwrap();
        assert!(installer.is_installed());
        installer.uninstall().unwrap();
        assert!(!installer.is_installed());
        // Someone else's skill folder does not count either.
        write(&installer.bin_link, b"bin");
        write(&installer.claude_skill_link.join("SKILL.md"), b"mine");
        assert!(!installer.is_installed());
    }

    #[cfg(unix)]
    #[test]
    fn refuses_a_different_file_at_the_command_path() {
        let dir = tempfile::tempdir().unwrap();
        let binary = dir.path().join("archive").join("lokalbot-cli");
        write(&binary, b"bin");
        let installer = installer_in(dir.path(), binary);
        write(&installer.bin_link, b"mine");
        let err = installer.install(false).unwrap_err();
        assert!(
            err.to_string().contains("not owned by this installer"),
            "{err}"
        );
        assert_eq!(std::fs::read(&installer.bin_link).unwrap(), b"mine");
        assert!(!Installer::exists(&installer.skill_link));
        assert!(!Installer::exists(&installer.claude_skill_link));
    }

    #[test]
    fn refuses_a_foreign_skill_folder_when_the_binary_is_kept() {
        let dir = tempfile::tempdir().unwrap();
        let mut installer = installer_in(dir.path(), PathBuf::new());
        write(&installer.bin_link, b"bin");
        installer.binary = installer.bin_link.clone();
        write(&installer.claude_skill_link.join("SKILL.md"), b"mine");
        let err = installer.install(false).unwrap_err();
        assert!(
            err.to_string().contains("not owned by this installer"),
            "{err}"
        );
        assert_eq!(
            std::fs::read(installer.claude_skill_link.join("SKILL.md")).unwrap(),
            b"mine"
        );
        assert!(!Installer::exists(&installer.skill_link));
    }

    #[cfg(unix)]
    #[test]
    fn installs_links_and_refuses_foreign_paths() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let binary = dir.path().join("lokalbot-cli");
        std::fs::write(&binary, b"bin").unwrap();
        let installer = Installer::new(home.clone(), binary.clone());
        installer.install(false).unwrap();
        assert_eq!(std::fs::read_link(&installer.bin_link).unwrap(), binary);
        let skill = std::fs::read_to_string(installer.claude_skill_link.join("SKILL.md")).unwrap();
        assert!(skill.contains("Linux and Windows"));
        assert!(!skill.contains("/Applications/"));
        installer.install(true).unwrap();
        assert!(installer.skill_link.join(COPY_MARKER).is_file());
        installer.uninstall().unwrap();
        assert!(!Installer::exists(&installer.bin_link));
        assert!(!Installer::exists(&installer.skill_link));

        std::fs::create_dir_all(&installer.skill_link).unwrap();
        std::fs::write(installer.skill_link.join("SKILL.md"), "mine").unwrap();
        let err = installer.install(false).unwrap_err();
        assert!(
            err.to_string().contains("not owned by this installer"),
            "{err}"
        );
        assert!(
            installer
                .installed_message()
                .contains("claude mcp add lokalbot --")
        );
    }
}
