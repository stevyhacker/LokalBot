//! Putting a verified, unpacked update in place of the running copy.
//!
//! Every new file is first copied next to the file it replaces, so the final
//! step is a rename within one folder. Linux renames over the old file; the
//! running processes keep the old inode. Windows cannot replace a running
//! executable but can rename it, so `lokalbot.exe` and `lokalbot-cli.exe`
//! (which a coding agent may hold open as its MCP server) become `.old`
//! files that the next start deletes. A failure part-way restores every file
//! already replaced.

use std::ffi::OsString;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The relaunched copy waits for the old one to release the library.
pub const AFTER_UPDATE_ARG: &str = "--after-update";
/// install.sh's desktop entry and icon name.
pub const APP_ID: &str = "com.lokalbot.LokalBot";
const ICON_SIZES: [u32; 8] = [16, 24, 32, 48, 64, 128, 256, 512];
/// The archive's folder of license texts.
const LICENSES_DIR: &str = "LICENSES";
/// The Windows archive's Visual C++ runtime, which lokalbot-ai's runtime.rs
/// (`VC_RUNTIME_DIR`) copies beside llama-server.exe.
const VC_RUNTIME_DIR: &str = "vc-runtime";

pub const APP_BINARY: &str = if cfg!(windows) {
    "lokalbot.exe"
} else {
    "lokalbot"
};
pub const CLI_BINARY: &str = if cfg!(windows) {
    "lokalbot-cli.exe"
} else {
    "lokalbot-cli"
};

/// How the files are swapped. Both are tested on every platform; the running
/// build uses [`SwapStyle::NATIVE`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SwapStyle {
    /// Keep a hard link to the old file, then rename the new one over it.
    Unix,
    /// Rename the old file aside, then rename the new one into its place.
    Windows,
}

impl SwapStyle {
    pub const NATIVE: Self = if cfg!(windows) {
        Self::Windows
    } else {
        Self::Unix
    };
}

/// Whether this copy may replace itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Placement {
    Replaceable,
    /// A package manager, a system folder (`/usr`, `/opt`, Program Files),
    /// a sandbox or a source build owns the files: say how to update
    /// instead ([`crate::package`] tells package installs apart).
    Managed,
    /// The folder cannot be written by this user.
    NotWritable,
}

/// Where the running copy lives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Installation {
    pub dir: PathBuf,
    pub placement: Placement,
}

impl Installation {
    /// The folder of the running executable.
    pub fn current() -> io::Result<Self> {
        let exe = std::env::current_exe()?;
        let exe = fs::canonicalize(&exe).unwrap_or(exe);
        let dir = exe
            .parent()
            .ok_or_else(|| io::Error::other("the executable has no folder"))?;
        Ok(Self::at(dunce(dir), &|name| std::env::var_os(name)))
    }

    pub fn at(dir: PathBuf, env: &dyn Fn(&str) -> Option<OsString>) -> Self {
        let placement = if is_managed(&dir, env) {
            Placement::Managed
        } else if is_writable(&dir) {
            Placement::Replaceable
        } else {
            Placement::NotWritable
        };
        Self { dir, placement }
    }

    pub fn can_replace(&self) -> bool {
        self.placement == Placement::Replaceable
    }

    /// What an update replaces for this installation.
    pub fn targets(&self) -> Targets {
        Targets::for_dir(self.dir.clone(), &|name| std::env::var_os(name))
    }
}

/// Windows' canonical paths start with `\\?\`; show and compare them as typed.
fn dunce(path: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        let text = path.to_string_lossy();
        if let Some(rest) = text.strip_prefix(r"\\?\")
            && !rest.starts_with("UNC\\")
        {
            return PathBuf::from(rest);
        }
    }
    path.to_path_buf()
}

fn is_managed(dir: &Path, env: &dyn Fn(&str) -> Option<OsString>) -> bool {
    // A cargo target folder: a developer's release build.
    let in_target = |dir: &Path| {
        dir.parent()
            .and_then(Path::file_name)
            .is_some_and(|n| n == "target")
            || dir
                .parent()
                .and_then(Path::parent)
                .and_then(Path::file_name)
                .is_some_and(|n| n == "target")
    };
    if dir
        .file_name()
        .is_some_and(|n| n == "release" || n == "debug")
        && in_target(dir)
    {
        return true;
    }
    let under = |root: &Path| !root.as_os_str().is_empty() && dir.starts_with(root);
    if cfg!(windows) {
        [
            "ProgramFiles",
            "ProgramFiles(x86)",
            "ProgramW6432",
            "SystemRoot",
        ]
        .iter()
        .filter_map(|name| env(name))
        .any(|root| under(Path::new(&root)))
    } else {
        // AppImage, Snap and Flatpak run from read-only images.
        ["APPIMAGE", "SNAP", "FLATPAK_ID"]
            .iter()
            .any(|name| env(name).is_some_and(|v| !v.is_empty()))
            || ["/usr", "/opt", "/snap", "/nix", "/app", "/var/lib/flatpak"]
                .iter()
                .any(|root| under(Path::new(root)))
    }
}

fn is_writable(dir: &Path) -> bool {
    let probe = dir.join(format!(".lokalbot-update-probe-{}", std::process::id()));
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
    {
        Ok(file) => {
            drop(file);
            let _ = fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

/// The files an update writes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Targets {
    /// The folder holding `lokalbot` and `lokalbot-cli`.
    pub dir: PathBuf,
    /// `lokalbot-cli install-skill`'s copy on Windows,
    /// `%LOCALAPPDATA%\Programs\LokalBot\bin\lokalbot-cli.exe`, which coding
    /// agents run as their MCP server. Replaced when it exists.
    pub cli_copy: Option<PathBuf>,
    /// The XDG data folder holding install.sh's desktop entry and icons.
    /// They are refreshed when the entry starts this installation.
    pub data_dir: Option<PathBuf>,
}

impl Targets {
    pub fn for_dir(dir: PathBuf, env: &dyn Fn(&str) -> Option<OsString>) -> Self {
        let home = || env(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from);
        let cli_copy = if cfg!(windows) {
            env("LOCALAPPDATA")
                .map(PathBuf::from)
                .or_else(|| home().map(|h| h.join("AppData").join("Local")))
                .map(|local| {
                    local
                        .join("Programs")
                        .join("LokalBot")
                        .join("bin")
                        .join(CLI_BINARY)
                })
        } else {
            None
        };
        let data_dir = if cfg!(windows) {
            None
        } else {
            env("XDG_DATA_HOME")
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
                .or_else(|| home().map(|h| h.join(".local").join("share")))
        };
        Self {
            dir,
            cli_copy,
            data_dir,
        }
    }

    fn binary(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }
}

#[derive(Debug, thiserror::Error)]
pub enum InstallError {
    #[error("the update is missing {0}")]
    Incomplete(String),
    #[error("could not replace {path}: {source}")]
    Replace {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

/// What was replaced.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Installed {
    /// The new `lokalbot` to relaunch.
    pub executable: PathBuf,
    pub replaced: Vec<PathBuf>,
}

struct Replacement {
    source: PathBuf,
    target: PathBuf,
    /// The new file, copied next to `target`.
    staged: PathBuf,
    /// The old file, kept until every replacement succeeded.
    backup: Option<PathBuf>,
}

/// Replaces the installed files with the unpacked update in `staged` (the
/// archive's `LokalBot-<version>-<platform>` folder): both binaries, the
/// Windows CLI copy, files the archive folder also holds (licenses, notices,
/// when LokalBot runs from an extracted archive or the installer's folder),
/// license texts the update adds to that folder's `LICENSES`, the Visual C++
/// runtime, then install.sh's desktop entry and icons. Nothing is replaced
/// unless every file could be staged.
pub fn install(
    staged: &Path,
    targets: &Targets,
    style: SwapStyle,
) -> Result<Installed, InstallError> {
    let mut replacements = plan(staged, targets)?;
    for replacement in &replacements {
        if let Err(source) = stage(replacement) {
            discard_staged(&replacements);
            return Err(InstallError::Replace {
                path: replacement.target.clone(),
                source,
            });
        }
    }
    for index in 0..replacements.len() {
        if let Err(source) = swap(&mut replacements[index], style) {
            roll_back(&mut replacements[..index], style);
            discard_staged(&replacements);
            return Err(InstallError::Replace {
                path: replacements[index].target.clone(),
                source,
            });
        }
    }
    // Running executables keep their old file on Windows; the next start
    // deletes it (`remove_leftovers`).
    for replacement in &replacements {
        if let Some(backup) = &replacement.backup {
            let _ = fs::remove_file(backup);
        }
    }
    if let Some(data_dir) = &targets.data_dir {
        refresh_desktop_entry(staged, &targets.dir, data_dir);
    }
    Ok(Installed {
        executable: targets.binary(APP_BINARY),
        replaced: replacements.into_iter().map(|r| r.target).collect(),
    })
}

fn plan(staged: &Path, targets: &Targets) -> Result<Vec<Replacement>, InstallError> {
    let mut pairs = Vec::new();
    for name in [APP_BINARY, CLI_BINARY] {
        let source = staged.join(name);
        if !source.is_file() {
            return Err(InstallError::Incomplete(name.into()));
        }
        let target = targets.binary(name);
        // install-skill may have linked the CLI from elsewhere; a link is
        // not this installation's file.
        if fs::symlink_metadata(&target).is_ok_and(|m| m.file_type().is_symlink()) {
            continue;
        }
        pairs.push((source, target));
    }
    if let Some(copy) = &targets.cli_copy
        && copy.is_file()
        && *copy != targets.binary(CLI_BINARY)
    {
        pairs.push((staged.join(CLI_BINARY), copy.clone()));
    }
    for relative in files_under(staged).map_err(|e| InstallError::Replace {
        path: staged.to_path_buf(),
        source: e,
    })? {
        if relative == Path::new(APP_BINARY) || relative == Path::new(CLI_BINARY) {
            continue;
        }
        let target = targets.dir.join(&relative);
        let present = fs::symlink_metadata(&target).is_ok_and(|m| m.is_file());
        // A LICENSES folder already in place also gets the license texts the
        // update adds, so the notices it ships stay complete.
        let new_license = !present
            && relative.parent() == Some(Path::new(LICENSES_DIR))
            && fs::symlink_metadata(targets.dir.join(LICENSES_DIR)).is_ok_and(|m| m.is_dir());
        // Installations from before the Windows archive carried the Visual
        // C++ runtime get it too; their llama.cpp runtimes need it.
        let vc_runtime = relative.parent() == Some(Path::new(VC_RUNTIME_DIR));
        if present || new_license || vc_runtime {
            pairs.push((staged.join(&relative), target));
        }
    }
    Ok(pairs
        .into_iter()
        .map(|(source, target)| Replacement {
            staged: sibling(&target, "new"),
            source,
            target,
            backup: None,
        })
        .collect())
}

/// Relative paths of the regular files under `root`.
fn files_under(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    let mut pending = vec![PathBuf::new()];
    while let Some(relative) = pending.pop() {
        for entry in fs::read_dir(root.join(&relative))? {
            let entry = entry?;
            let path = relative.join(entry.file_name());
            let kind = entry.file_type()?;
            if kind.is_dir() {
                pending.push(path);
            } else if kind.is_file() {
                out.push(path);
            }
        }
    }
    out.sort();
    Ok(out)
}

/// `lokalbot` → `lokalbot.new` / `lokalbot.old`, in the same folder.
fn sibling(target: &Path, suffix: &str) -> PathBuf {
    let mut name = target.file_name().unwrap_or_default().to_os_string();
    name.push(".");
    name.push(suffix);
    target.with_file_name(name)
}

fn stage(replacement: &Replacement) -> io::Result<()> {
    let _ = fs::remove_file(&replacement.staged);
    // The Visual C++ runtime can be new to an installation, folder and all.
    if let Some(folder) = replacement.staged.parent() {
        fs::create_dir_all(folder)?;
    }
    fs::copy(&replacement.source, &replacement.staged)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let name = replacement.target.file_name().unwrap_or_default();
        if name == APP_BINARY || name == CLI_BINARY {
            fs::set_permissions(&replacement.staged, fs::Permissions::from_mode(0o755))?;
        }
    }
    // Windows flushes only through a handle that may write.
    fs::OpenOptions::new()
        .write(true)
        .open(&replacement.staged)?
        .sync_all()
}

/// A free `<name>.old` (or `<name>.<n>.old` while an older one is still in use).
fn backup_path(target: &Path) -> PathBuf {
    let first = sibling(target, "old");
    if fs::symlink_metadata(&first).is_err() || fs::remove_file(&first).is_ok() {
        return first;
    }
    (1..1000)
        .map(|n| sibling(target, &format!("{n}.old")))
        .find(|path| fs::symlink_metadata(path).is_err() || fs::remove_file(path).is_ok())
        .unwrap_or(first)
}

fn swap(replacement: &mut Replacement, style: SwapStyle) -> io::Result<()> {
    let exists = fs::symlink_metadata(&replacement.target).is_ok();
    if exists {
        let backup = backup_path(&replacement.target);
        match style {
            SwapStyle::Unix => {
                if fs::hard_link(&replacement.target, &backup).is_err() {
                    fs::copy(&replacement.target, &backup)?;
                }
            }
            SwapStyle::Windows => fs::rename(&replacement.target, &backup)?,
        }
        replacement.backup = Some(backup);
    }
    if let Err(err) = fs::rename(&replacement.staged, &replacement.target) {
        // The target was not replaced. On Unix it is still the old file (and
        // renaming a hard link onto its twin would do nothing).
        if let Some(backup) = replacement.backup.take() {
            match style {
                SwapStyle::Unix => {
                    let _ = fs::remove_file(&backup);
                }
                SwapStyle::Windows => put_back(&backup, &replacement.target),
            }
        }
        return Err(err);
    }
    Ok(())
}

/// Undoes a completed swap.
fn restore(replacement: &mut Replacement, style: SwapStyle) {
    let Some(backup) = replacement.backup.take() else {
        // The file was new.
        let _ = fs::remove_file(&replacement.target);
        return;
    };
    if style == SwapStyle::Windows {
        // The new file is not running yet, so it can be removed.
        let _ = fs::remove_file(&replacement.target);
    }
    put_back(&backup, &replacement.target);
}

fn put_back(backup: &Path, target: &Path) {
    if let Err(err) = fs::rename(backup, target) {
        let message = format!(
            "could not restore {} from {}: {err}",
            target.display(),
            backup.display()
        );
        #[cfg(feature = "client")]
        log::error!("{message}");
        #[cfg(not(feature = "client"))]
        eprintln!("{message}");
    }
}

fn roll_back(done: &mut [Replacement], style: SwapStyle) {
    for replacement in done.iter_mut().rev() {
        restore(replacement, style);
    }
}

fn discard_staged(replacements: &[Replacement]) {
    for replacement in replacements {
        let _ = fs::remove_file(&replacement.staged);
    }
}

/// Deletes `.old` and `.new` binaries an earlier update left in `dir` (and
/// next to the Windows CLI copy). Ones still running stay until next time.
pub fn remove_leftovers(targets: &Targets) {
    let mut dirs = vec![targets.dir.clone()];
    if let Some(parent) = targets.cli_copy.as_deref().and_then(Path::parent) {
        dirs.push(parent.to_path_buf());
    }
    for dir in dirs {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            if is_leftover(&name.to_string_lossy()) {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
}

fn is_leftover(name: &str) -> bool {
    [APP_BINARY, CLI_BINARY].iter().any(|binary| {
        let Some(rest) = name.strip_prefix(binary).and_then(|r| r.strip_prefix('.')) else {
            return false;
        };
        rest == "new"
            || rest == "old"
            || rest
                .strip_suffix(".old")
                .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
    })
}

/// Rewrites install.sh's desktop entry and icons from the update when the
/// entry starts this installation. Failures only log: the binaries are
/// already in place.
fn refresh_desktop_entry(staged: &Path, dir: &Path, data_dir: &Path) {
    let entry_path = data_dir
        .join("applications")
        .join(format!("{APP_ID}.desktop"));
    let source = staged.join(format!("{APP_ID}.desktop"));
    let (Ok(installed), Ok(template)) =
        (fs::read_to_string(&entry_path), fs::read_to_string(&source))
    else {
        return;
    };
    let exec = dir.join(APP_BINARY);
    let resolved = fs::canonicalize(&exec).ok();
    let ours = installed.lines().any(|line| {
        line.strip_prefix("Exec=")
            .and_then(|command| command.split_whitespace().next())
            .is_some_and(|program| {
                Path::new(program) == exec
                    || resolved.is_some() && fs::canonicalize(program).ok() == resolved
            })
    });
    if !ours {
        return;
    }
    // install.sh: sed "s|^Exec=lokalbot|Exec=$BIN/lokalbot|"
    let entry: String = template
        .lines()
        .map(|line| match line.strip_prefix("Exec=lokalbot") {
            Some(rest) => format!("Exec={}{rest}\n", exec.display()),
            None => format!("{line}\n"),
        })
        .collect();
    let result = write_atomically(&entry_path, entry.as_bytes()).and_then(|()| {
        for size in ICON_SIZES {
            let icon = staged.join("icons").join(format!("lokalbot-{size}.png"));
            if icon.is_file() {
                let target = data_dir
                    .join("icons/hicolor")
                    .join(format!("{size}x{size}"))
                    .join("apps")
                    .join(format!("{APP_ID}.png"));
                if let Some(parent) = target.parent() {
                    fs::create_dir_all(parent)?;
                }
                write_atomically(&target, &fs::read(&icon)?)?;
            }
        }
        Ok(())
    });
    if let Err(err) = result {
        let message = format!("could not refresh the desktop entry: {err}");
        #[cfg(feature = "client")]
        log::warn!("{message}");
        #[cfg(not(feature = "client"))]
        eprintln!("{message}");
        return;
    }
    let _ = Command::new("update-desktop-database")
        .arg(data_dir.join("applications"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn write_atomically(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temp = sibling(path, "new");
    fs::write(&temp, bytes)?;
    fs::rename(&temp, path).inspect_err(|_| {
        let _ = fs::remove_file(&temp);
    })
}

/// Starts the updated LokalBot detached from this process, with `args`
/// after [`AFTER_UPDATE_ARG`] so it waits for this copy to exit and release
/// the library. `remove_env` names variables that describe only this process.
pub fn relaunch(executable: &Path, args: &[OsString], remove_env: &[&str]) -> io::Result<()> {
    let mut command = Command::new(executable);
    command
        .arg(AFTER_UPDATE_ARG)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if let Some(dir) = executable.parent() {
        command.current_dir(dir);
    }
    for name in remove_env {
        command.env_remove(name);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        command.process_group(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }
    command.spawn().map(drop)
}

#[cfg(test)]
mod tests {
    use super::*;

    const BOTH: [SwapStyle; 2] = [SwapStyle::Unix, SwapStyle::Windows];

    fn write(path: &Path, text: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    fn read(path: &Path) -> String {
        fs::read_to_string(path).unwrap()
    }

    /// An unpacked update archive.
    fn update(root: &Path) -> PathBuf {
        let staged = root.join("update/LokalBot-0.10.11-linux-x86_64");
        write(&staged.join(APP_BINARY), "new app");
        write(&staged.join(CLI_BINARY), "new cli");
        write(&staged.join("THIRD_PARTY_NOTICES.md"), "new notices");
        write(&staged.join("LICENSES/AGPL-3.0.txt"), "new license");
        write(&staged.join("LICENSES/MIT.txt"), "added license");
        write(
            &staged.join(format!("{APP_ID}.desktop")),
            "[Desktop Entry]\nName=LokalBot\nExec=lokalbot %U\nIcon=com.lokalbot.LokalBot\n",
        );
        for size in ICON_SIZES {
            write(
                &staged.join(format!("icons/lokalbot-{size}.png")),
                &format!("new icon {size}"),
            );
        }
        staged
    }

    fn targets(dir: &Path) -> Targets {
        Targets {
            dir: dir.to_path_buf(),
            cli_copy: None,
            data_dir: None,
        }
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    fn sorted(names: &[&str]) -> Vec<String> {
        let mut names: Vec<String> = names.iter().map(|n| n.to_string()).collect();
        names.sort();
        names
    }

    #[test]
    fn replaces_the_binaries_in_a_bin_folder_and_nothing_else() {
        for style in BOTH {
            let temp = tempfile::tempdir().unwrap();
            let staged = update(temp.path());
            let bin = temp.path().join("bin");
            write(&bin.join(APP_BINARY), "old app");
            write(&bin.join(CLI_BINARY), "old cli");
            write(&bin.join("other-tool"), "untouched");
            let installed = install(&staged, &targets(&bin), style).unwrap();
            assert_eq!(installed.executable, bin.join(APP_BINARY));
            assert_eq!(read(&bin.join(APP_BINARY)), "new app");
            assert_eq!(read(&bin.join(CLI_BINARY)), "new cli");
            // Licenses only replace copies that are already there.
            assert_eq!(names(&bin), sorted(&[APP_BINARY, CLI_BINARY, "other-tool"]));
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt as _;
                let mode = fs::metadata(bin.join(APP_BINARY))
                    .unwrap()
                    .permissions()
                    .mode();
                assert_eq!(mode & 0o777, 0o755, "{style:?}");
            }
        }
    }

    #[test]
    fn refreshes_an_extracted_archive_folder() {
        for style in BOTH {
            let temp = tempfile::tempdir().unwrap();
            let staged = update(temp.path());
            let folder = temp.path().join("LokalBot");
            write(&folder.join(APP_BINARY), "old app");
            write(&folder.join(CLI_BINARY), "old cli");
            write(&folder.join("THIRD_PARTY_NOTICES.md"), "old notices");
            write(&folder.join("LICENSES/AGPL-3.0.txt"), "old license");
            write(&folder.join("settings-of-the-user.txt"), "kept");
            install(&staged, &targets(&folder), style).unwrap();
            assert_eq!(read(&folder.join("THIRD_PARTY_NOTICES.md")), "new notices");
            assert_eq!(read(&folder.join("LICENSES/AGPL-3.0.txt")), "new license");
            // A license text new in this release is added beside the others.
            assert_eq!(read(&folder.join("LICENSES/MIT.txt")), "added license");
            assert_eq!(read(&folder.join("settings-of-the-user.txt")), "kept");
            assert!(!folder.join("icons").exists());
        }
    }

    #[test]
    fn adds_the_visual_cpp_runtime_to_older_installations() {
        for style in BOTH {
            let temp = tempfile::tempdir().unwrap();
            let staged = update(temp.path());
            write(&staged.join("vc-runtime/msvcp140.dll"), "new runtime");
            write(&staged.join("vc-runtime/vcruntime140.dll"), "new runtime");
            let older = temp.path().join("older");
            write(&older.join(APP_BINARY), "old app");
            write(&older.join(CLI_BINARY), "old cli");
            let current = temp.path().join("current");
            write(&current.join(APP_BINARY), "old app");
            write(&current.join(CLI_BINARY), "old cli");
            write(&current.join("vc-runtime/msvcp140.dll"), "old runtime");
            for folder in [&older, &current] {
                install(&staged, &targets(folder), style).unwrap();
                assert_eq!(
                    names(&folder.join("vc-runtime")),
                    sorted(&["msvcp140.dll", "vcruntime140.dll"]),
                    "{style:?}"
                );
                assert_eq!(read(&folder.join("vc-runtime/msvcp140.dll")), "new runtime");
            }
        }
    }

    #[test]
    fn a_missing_binary_in_the_update_changes_nothing() {
        let temp = tempfile::tempdir().unwrap();
        let staged = update(temp.path());
        fs::remove_file(staged.join(CLI_BINARY)).unwrap();
        let bin = temp.path().join("bin");
        write(&bin.join(APP_BINARY), "old app");
        let error = install(&staged, &targets(&bin), SwapStyle::NATIVE).unwrap_err();
        assert!(matches!(error, InstallError::Incomplete(name) if name == CLI_BINARY));
        assert_eq!(read(&bin.join(APP_BINARY)), "old app");
        assert_eq!(names(&bin), sorted(&[APP_BINARY]));
    }

    #[test]
    fn a_failure_part_way_restores_every_replaced_file() {
        for style in BOTH {
            let temp = tempfile::tempdir().unwrap();
            let staged = update(temp.path());
            let folder = temp.path().join("LokalBot");
            write(&folder.join(APP_BINARY), "old app");
            write(&folder.join(CLI_BINARY), "old cli");
            write(&folder.join("THIRD_PARTY_NOTICES.md"), "old notices");
            let mut replacements = plan(&staged, &targets(&folder)).unwrap();
            for replacement in &replacements {
                stage(replacement).unwrap();
            }
            // The last swap fails: its staged file vanished.
            let last = replacements.len() - 1;
            fs::remove_file(&replacements[last].staged).unwrap();
            for index in 0..replacements.len() {
                if swap(&mut replacements[index], style).is_err() {
                    assert_eq!(index, last);
                    roll_back(&mut replacements[..index], style);
                    discard_staged(&replacements);
                    break;
                }
            }
            assert_eq!(read(&folder.join(APP_BINARY)), "old app", "{style:?}");
            assert_eq!(read(&folder.join(CLI_BINARY)), "old cli", "{style:?}");
            assert_eq!(read(&folder.join("THIRD_PARTY_NOTICES.md")), "old notices");
            assert_eq!(
                names(&folder),
                sorted(&[APP_BINARY, CLI_BINARY, "THIRD_PARTY_NOTICES.md"]),
                "{style:?}"
            );
        }
    }

    #[test]
    fn replaces_the_windows_cli_copy_and_skips_linked_clis() {
        let temp = tempfile::tempdir().unwrap();
        let staged = update(temp.path());
        let folder = temp.path().join("LokalBot");
        write(&folder.join(APP_BINARY), "old app");
        write(&folder.join(CLI_BINARY), "old cli");
        let copy = temp.path().join("Programs/LokalBot/bin").join(CLI_BINARY);
        write(&copy, "old cli copy");
        let mut targets = targets(&folder);
        targets.cli_copy = Some(copy.clone());
        install(&staged, &targets, SwapStyle::Windows).unwrap();
        assert_eq!(read(&copy), "new cli");
        // No copy installed: nothing is created.
        let absent = temp.path().join("nowhere").join(CLI_BINARY);
        targets.cli_copy = Some(absent.clone());
        install(&staged, &targets, SwapStyle::Windows).unwrap();
        assert!(!absent.exists());
        #[cfg(unix)]
        {
            let bin = temp.path().join("bin");
            write(&bin.join(APP_BINARY), "old app");
            write(&temp.path().join("elsewhere/lokalbot-cli"), "other cli");
            std::os::unix::fs::symlink(
                temp.path().join("elsewhere/lokalbot-cli"),
                bin.join(CLI_BINARY),
            )
            .unwrap();
            install(&staged, &self::targets(&bin), SwapStyle::Unix).unwrap();
            assert_eq!(
                read(&temp.path().join("elsewhere/lokalbot-cli")),
                "other cli"
            );
        }
    }

    #[test]
    fn windows_style_leaves_old_files_for_the_next_start_when_they_are_busy() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path().join("LokalBot");
        write(&folder.join(APP_BINARY), "app");
        write(
            &folder.join(sibling(&folder.join(CLI_BINARY), "old")),
            "running old cli",
        );
        write(
            &folder.join(sibling(&folder.join(CLI_BINARY), "3.old")),
            "older",
        );
        write(
            &folder.join(sibling(&folder.join(APP_BINARY), "new")),
            "half staged",
        );
        write(&folder.join("notes.old"), "not ours");
        remove_leftovers(&targets(&folder));
        assert_eq!(names(&folder), sorted(&[APP_BINARY, "notes.old"]));
        assert!(is_leftover(&format!("{CLI_BINARY}.12.old")));
        assert!(!is_leftover(&format!("{CLI_BINARY}.x.old")));
        assert!(!is_leftover(&format!("{CLI_BINARY}..old")));
        assert!(!is_leftover(CLI_BINARY));
    }

    #[test]
    fn refreshes_install_sh_desktop_entry_and_icons() {
        let temp = tempfile::tempdir().unwrap();
        let staged = update(temp.path());
        let bin = temp.path().join("home/.local/bin");
        let data = temp.path().join("home/.local/share");
        write(&bin.join(APP_BINARY), "old app");
        write(&bin.join(CLI_BINARY), "old cli");
        let entry = data.join("applications").join(format!("{APP_ID}.desktop"));
        write(
            &entry,
            &format!(
                "[Desktop Entry]\nName=Old\nExec={} %U\n",
                bin.join(APP_BINARY).display()
            ),
        );
        let mut targets = targets(&bin);
        targets.data_dir = Some(data.clone());
        install(&staged, &targets, SwapStyle::Unix).unwrap();
        assert_eq!(
            read(&entry),
            format!(
                "[Desktop Entry]\nName=LokalBot\nExec={} %U\nIcon=com.lokalbot.LokalBot\n",
                bin.join(APP_BINARY).display()
            )
        );
        assert_eq!(
            read(&data.join(format!("icons/hicolor/48x48/apps/{APP_ID}.png"))),
            "new icon 48"
        );

        // An entry that starts another copy is left alone.
        let other = "[Desktop Entry]\nExec=/opt/LokalBot/lokalbot %U\n".to_string();
        write(&entry, &other);
        fs::remove_file(data.join(format!("icons/hicolor/48x48/apps/{APP_ID}.png"))).unwrap();
        install(&staged, &targets, SwapStyle::Unix).unwrap();
        assert_eq!(read(&entry), other);
        assert!(
            !data
                .join(format!("icons/hicolor/48x48/apps/{APP_ID}.png"))
                .exists()
        );
    }

    #[test]
    fn package_managed_and_source_build_folders_only_notify() {
        let temp = tempfile::tempdir().unwrap();
        let none = |_: &str| None;
        let dir = temp.path().join("bin");
        fs::create_dir_all(&dir).unwrap();
        assert_eq!(
            Installation::at(dir.clone(), &none).placement,
            Placement::Replaceable
        );
        let build = temp.path().join("LinuxWindows/target/release");
        fs::create_dir_all(&build).unwrap();
        assert_eq!(Installation::at(build, &none).placement, Placement::Managed);
        let cross = temp.path().join("target/x86_64-unknown-linux-gnu/release");
        fs::create_dir_all(&cross).unwrap();
        assert_eq!(Installation::at(cross, &none).placement, Placement::Managed);
        if cfg!(windows) {
            let program_files = temp.path().join("Program Files");
            let env = |name: &str| {
                (name == "ProgramFiles").then(|| program_files.clone().into_os_string())
            };
            let inside = program_files.join("LokalBot");
            fs::create_dir_all(&inside).unwrap();
            assert_eq!(Installation::at(inside, &env).placement, Placement::Managed);
        } else {
            assert_eq!(
                Installation::at("/usr/bin".into(), &none).placement,
                Placement::Managed
            );
            assert_eq!(
                Installation::at("/opt/LokalBot".into(), &none).placement,
                Placement::Managed
            );
            let appimage =
                |name: &str| (name == "APPIMAGE").then(|| OsString::from("/tmp/LokalBot.AppImage"));
            assert_eq!(
                Installation::at(dir.clone(), &appimage).placement,
                Placement::Managed
            );
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let locked = temp.path().join("locked");
            fs::create_dir_all(&locked).unwrap();
            fs::set_permissions(&locked, fs::Permissions::from_mode(0o555)).unwrap();
            // Root can write anywhere; the check only means something for users.
            if !is_writable(&locked) {
                assert_eq!(
                    Installation::at(locked.clone(), &none).placement,
                    Placement::NotWritable
                );
            }
            fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        }
    }

    #[test]
    fn finds_the_windows_cli_copy_and_the_xdg_data_folder() {
        let env = |name: &str| match name {
            "LOCALAPPDATA" => Some(OsString::from("C:/Users/a/AppData/Local")),
            "XDG_DATA_HOME" => Some(OsString::from("/home/a/.data")),
            "HOME" | "USERPROFILE" => Some(OsString::from("/home/a")),
            _ => None,
        };
        let targets = Targets::for_dir("/somewhere".into(), &env);
        if cfg!(windows) {
            assert_eq!(
                targets.cli_copy,
                Some(
                    PathBuf::from("C:/Users/a/AppData/Local/Programs/LokalBot/bin")
                        .join(CLI_BINARY)
                )
            );
            assert_eq!(targets.data_dir, None);
        } else {
            assert_eq!(targets.cli_copy, None);
            assert_eq!(targets.data_dir, Some(PathBuf::from("/home/a/.data")));
            let fallback = Targets::for_dir("/somewhere".into(), &|name: &str| {
                (name == "HOME").then(|| OsString::from("/home/a"))
            });
            assert_eq!(
                fallback.data_dir,
                Some(PathBuf::from("/home/a/.local/share"))
            );
        }
    }

    /// The real Windows case: the CLI is running (as an MCP server would be)
    /// while the update replaces it. Renaming works; deleting the old file
    /// waits until the process exits.
    #[cfg(windows)]
    #[test]
    fn windows_replaces_a_running_cli() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path().join("LokalBot");
        fs::create_dir_all(&folder).unwrap();
        let system = std::env::var_os("SystemRoot").unwrap();
        let ping = Path::new(&system).join("System32").join("PING.EXE");
        fs::copy(&ping, folder.join(CLI_BINARY)).unwrap();
        write(&folder.join(APP_BINARY), "old app");
        let mut running = Command::new(folder.join(CLI_BINARY))
            .args(["-n", "30", "127.0.0.1"])
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(300));
        // A running image cannot be overwritten or deleted in place.
        assert!(fs::write(folder.join(CLI_BINARY), "x").is_err());

        let staged = update(temp.path());
        install(&staged, &targets(&folder), SwapStyle::Windows).unwrap();
        assert_eq!(read(&folder.join(CLI_BINARY)), "new cli");
        assert_eq!(read(&folder.join(APP_BINARY)), "new app");
        let old = sibling(&folder.join(CLI_BINARY), "old");
        assert!(old.exists(), "the running CLI keeps its old file");
        assert!(
            running.try_wait().unwrap().is_none(),
            "the CLI keeps running"
        );

        // A second update while the first old CLI is still running.
        write(&staged.join(CLI_BINARY), "newer cli");
        fs::copy(&ping, folder.join(CLI_BINARY)).unwrap();
        let mut running_new = Command::new(folder.join(CLI_BINARY))
            .args(["-n", "30", "127.0.0.1"])
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(300));
        install(&staged, &targets(&folder), SwapStyle::Windows).unwrap();
        assert_eq!(read(&folder.join(CLI_BINARY)), "newer cli");
        assert!(sibling(&folder.join(CLI_BINARY), "1.old").exists());

        remove_leftovers(&targets(&folder));
        assert!(old.exists(), "still running");
        running.kill().unwrap();
        running.wait().unwrap();
        running_new.kill().unwrap();
        running_new.wait().unwrap();
        // The image is released shortly after exit.
        for _ in 0..50 {
            remove_leftovers(&targets(&folder));
            if !old.exists() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        assert!(!old.exists());
        assert!(!sibling(&folder.join(CLI_BINARY), "1.old").exists());
    }
}
