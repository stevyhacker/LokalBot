//! Friendly app names from `.desktop` files, the Linux counterpart of an
//! app's `localizedName`: `StartupWMClass`, the desktop-file id or the
//! executable picks the entry, whose `Name` (localized) is shown.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::capitalized;
use super::linux::FocusedWindow;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ResolvedApp {
    pub name: String,
    /// Desktop-file id when known, else the app id, `WM_CLASS` or executable.
    pub id: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Entry {
    id: String,
    name: String,
}

/// Lookup tables over every visible `.desktop` file, first match wins in
/// XDG precedence (user folders before system ones).
#[derive(Debug, Default)]
pub(super) struct DesktopEntries {
    by_id: HashMap<String, Entry>,
    by_wm_class: HashMap<String, Entry>,
    by_exec: HashMap<String, Entry>,
}

impl DesktopEntries {
    pub(super) fn load(dirs: &[PathBuf], locales: &[String]) -> Self {
        let mut index = Self::default();
        for dir in dirs {
            let Ok(read) = std::fs::read_dir(dir) else {
                continue;
            };
            let mut files: Vec<PathBuf> = read
                .filter_map(|entry| entry.ok().map(|e| e.path()))
                .filter(|path| path.extension().is_some_and(|ext| ext == "desktop"))
                .collect();
            files.sort();
            for path in files {
                if let Ok(text) = std::fs::read_to_string(&path) {
                    index.add(&path, &text, locales);
                }
            }
        }
        index
    }

    fn add(&mut self, path: &Path, text: &str, locales: &[String]) {
        let Some(id) = path.file_stem().and_then(|s| s.to_str()) else {
            return;
        };
        let Some(parsed) = parse(text, locales) else {
            return;
        };
        let entry = Entry {
            id: id.to_string(),
            name: parsed.name,
        };
        self.by_id
            .entry(id.to_lowercase())
            .or_insert_with(|| entry.clone());
        if let Some(class) = parsed.wm_class {
            self.by_wm_class
                .entry(class.to_lowercase())
                .or_insert_with(|| entry.clone());
        }
        if let Some(exec) = parsed.exec {
            self.by_exec.entry(exec.to_lowercase()).or_insert(entry);
        }
    }

    fn find(&self, window: &FocusedWindow, exe: Option<&str>) -> Option<&Entry> {
        let lower = |s: &Option<String>| s.as_deref().map(str::to_lowercase);
        let desktop_file = lower(&window.desktop_file);
        let class = lower(&window.class);
        let instance = lower(&window.instance);
        let by_id = |key: &str| {
            let key = key.strip_suffix(".desktop").unwrap_or(key);
            self.by_id.get(key)
        };
        desktop_file
            .as_deref()
            .and_then(by_id)
            .or_else(|| class.as_deref().and_then(|c| self.by_wm_class.get(c)))
            .or_else(|| instance.as_deref().and_then(|i| self.by_wm_class.get(i)))
            .or_else(|| class.as_deref().and_then(by_id))
            .or_else(|| instance.as_deref().and_then(by_id))
            .or_else(|| {
                // "firefox" → org.mozilla.firefox.desktop
                class.as_deref().and_then(|c| {
                    self.by_id
                        .iter()
                        .filter(|(id, _)| id.ends_with(&format!(".{c}")))
                        .min_by_key(|(id, _)| id.len())
                        .map(|(_, entry)| entry)
                })
            })
            .or_else(|| exe.and_then(|e| self.by_exec.get(&e.to_lowercase())))
    }
}

struct Parsed {
    name: String,
    wm_class: Option<String>,
    exec: Option<String>,
}

/// Reads the `[Desktop Entry]` group of an application entry.
fn parse(text: &str, locales: &[String]) -> Option<Parsed> {
    let mut in_entry = false;
    let mut values: HashMap<&str, &str> = HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry || line.starts_with('#') {
            continue;
        }
        if let Some((key, value)) = line.split_once('=') {
            values.entry(key.trim()).or_insert(value.trim());
        }
    }
    if values.get("Type").is_some_and(|t| *t != "Application")
        || values.get("Hidden").is_some_and(|h| *h == "true")
    {
        return None;
    }
    let name = locales
        .iter()
        .find_map(|locale| values.get(format!("Name[{locale}]").as_str()))
        .or_else(|| values.get("Name"))?
        .to_string();
    if name.is_empty() {
        return None;
    }
    Some(Parsed {
        name,
        wm_class: values
            .get("StartupWMClass")
            .filter(|c| !c.is_empty())
            .map(|c| c.to_string()),
        exec: values.get("Exec").and_then(|exec| exec_basename(exec)),
    })
}

/// The program an `Exec=` line runs: skips `env VAR=…`, honors quotes, and
/// drops the folder. Flatpak launchers are matched by id instead.
fn exec_basename(exec: &str) -> Option<String> {
    let tokens = exec_tokens(exec);
    let mut tokens = tokens.iter().map(String::as_str);
    let mut program = tokens.next()?;
    if program == "env" || program.ends_with("/env") {
        program = tokens.find(|t| !t.contains('=') && !t.starts_with('-'))?;
    }
    let base = Path::new(program).file_name()?.to_str()?;
    if base == "flatpak" || base.is_empty() {
        return None;
    }
    Some(base.to_string())
}

fn exec_tokens(exec: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut chars = exec.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => quoted = !quoted,
            '\\' if quoted => current.extend(chars.next()),
            c if c.is_whitespace() && !quoted => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            c => current.push(c),
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

/// `XDG_DATA_HOME` and `XDG_DATA_DIRS` application folders plus Flatpak and
/// Snap exports.
pub(super) fn application_dirs() -> Vec<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let data_home = std::env::var_os("XDG_DATA_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| home.as_ref().map(|h| h.join(".local/share")));
    let data_dirs = std::env::var("XDG_DATA_DIRS")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    let mut dirs: Vec<PathBuf> = Vec::new();
    dirs.extend(data_home.map(|d| d.join("applications")));
    if let Some(home) = &home {
        dirs.push(home.join(".local/share/flatpak/exports/share/applications"));
    }
    dirs.extend(
        data_dirs
            .split(':')
            .filter(|d| !d.is_empty())
            .map(|d| Path::new(d).join("applications")),
    );
    dirs.push("/var/lib/flatpak/exports/share/applications".into());
    dirs.push("/var/lib/snapd/desktop/applications".into());
    let mut unique = Vec::new();
    for dir in dirs {
        if !unique.contains(&dir) {
            unique.push(dir);
        }
    }
    unique
}

/// `de_DE.UTF-8@euro` → `["de_DE@euro", "de_DE", "de@euro", "de"]`.
pub(super) fn locale_keys() -> Vec<String> {
    let raw = ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .find_map(|name| std::env::var(name).ok().filter(|v| !v.is_empty()))
        .unwrap_or_default();
    locale_keys_for(&raw)
}

fn locale_keys_for(raw: &str) -> Vec<String> {
    if raw.is_empty() || raw == "C" || raw == "POSIX" || raw.starts_with("C.") {
        return Vec::new();
    }
    let (rest, modifier) = match raw.split_once('@') {
        Some((rest, modifier)) => (rest, Some(modifier)),
        None => (raw, None),
    };
    let rest = rest.split('.').next().unwrap_or(rest);
    let (lang, country) = match rest.split_once('_') {
        Some((lang, country)) => (lang, Some(country)),
        None => (rest, None),
    };
    let mut keys = Vec::new();
    if let (Some(country), Some(modifier)) = (country, modifier) {
        keys.push(format!("{lang}_{country}@{modifier}"));
    }
    if let Some(country) = country {
        keys.push(format!("{lang}_{country}"));
    }
    if let Some(modifier) = modifier {
        keys.push(format!("{lang}@{modifier}"));
    }
    keys.push(lang.to_string());
    keys
}

/// The executable's file name for a process: `/proc/<pid>/exe`, else `comm`.
fn process_name(pid: u32) -> Option<String> {
    if let Ok(target) = std::fs::read_link(format!("/proc/{pid}/exe"))
        && let Some(name) = target.file_name().and_then(|n| n.to_str())
    {
        // A replaced binary reads "name (deleted)".
        return Some(name.trim_end_matches(" (deleted)").to_string());
    }
    std::fs::read_to_string(format!("/proc/{pid}/comm"))
        .ok()
        .map(|comm| comm.trim().to_string())
        .filter(|comm| !comm.is_empty())
}

/// Resolves windows to app names, re-reading the `.desktop` folders at most
/// once a minute when an app is not found (it may have just been installed).
pub(super) struct AppNames {
    entries: Option<DesktopEntries>,
    loaded_at: Option<Instant>,
    cache: HashMap<CacheKey, ResolvedApp>,
}

/// Class, instance, desktop-file hint and executable of a window.
type CacheKey = (
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
);

const RELOAD_AFTER: Duration = Duration::from_secs(60);

impl AppNames {
    pub(super) fn new() -> Self {
        Self {
            entries: None,
            loaded_at: None,
            cache: HashMap::new(),
        }
    }

    #[cfg(test)]
    fn with_entries(entries: DesktopEntries) -> Self {
        Self {
            entries: Some(entries),
            loaded_at: Some(Instant::now()),
            cache: HashMap::new(),
        }
    }

    fn entries(&mut self, reload_if_stale: bool) -> &DesktopEntries {
        let stale = self
            .loaded_at
            .is_none_or(|at| reload_if_stale && at.elapsed() > RELOAD_AFTER);
        if self.entries.is_none() || stale {
            self.entries = Some(DesktopEntries::load(&application_dirs(), &locale_keys()));
            self.loaded_at = Some(Instant::now());
            self.cache.clear();
        }
        self.entries.get_or_insert_with(DesktopEntries::default)
    }

    pub(super) fn resolve(&mut self, window: &FocusedWindow) -> ResolvedApp {
        let exe = window.pid.and_then(process_name);
        let key = (
            window.class.clone(),
            window.instance.clone(),
            window.desktop_file.clone(),
            exe.clone(),
        );
        if let Some(found) = self.cache.get(&key) {
            return found.clone();
        }
        let entry = self.entries(false).find(window, exe.as_deref()).cloned();
        let entry = match entry {
            Some(entry) => Some(entry),
            None => self.entries(true).find(window, exe.as_deref()).cloned(),
        };
        let resolved = resolve_with(entry, window, exe.as_deref());
        self.cache.insert(key, resolved.clone());
        resolved
    }
}

fn resolve_with(entry: Option<Entry>, window: &FocusedWindow, exe: Option<&str>) -> ResolvedApp {
    if let Some(entry) = entry {
        return ResolvedApp {
            name: entry.name,
            id: entry.id,
        };
    }
    let class = window.class.as_deref().filter(|c| !c.is_empty());
    let id = window
        .desktop_file
        .clone()
        .or_else(|| class.map(str::to_lowercase))
        .or_else(|| exe.map(str::to_string))
        .unwrap_or_default();
    let name = class
        .map(|c| {
            // Wayland ids like "org.gnome.Nautilus": keep the last part.
            let last = c.rsplit('.').next().unwrap_or(c);
            capitalized(last)
        })
        .or_else(|| exe.map(capitalized))
        .unwrap_or_else(|| "Unknown app".into());
    ResolvedApp { name, id }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index(files: &[(&str, &str)], locales: &[&str]) -> DesktopEntries {
        let dir = tempfile::tempdir().unwrap();
        for (name, text) in files {
            std::fs::write(dir.path().join(name), text).unwrap();
        }
        let locales: Vec<String> = locales.iter().map(|s| s.to_string()).collect();
        DesktopEntries::load(&[dir.path().to_path_buf()], &locales)
    }

    fn window(class: &str, instance: &str) -> FocusedWindow {
        FocusedWindow {
            title: "t".into(),
            class: Some(class.into()),
            instance: Some(instance.into()),
            ..Default::default()
        }
    }

    #[test]
    fn startup_wm_class_and_ids_pick_entries() {
        let entries = index(
            &[
                (
                    "code.desktop",
                    "[Desktop Entry]\nType=Application\nName=Visual Studio Code\nExec=/usr/share/code/code --unity-launch %F\nStartupWMClass=Code\n[Desktop Action new]\nName=New Window\n",
                ),
                (
                    "org.mozilla.firefox.desktop",
                    "[Desktop Entry]\nName=Firefox\nName[de]=Firefox-Browser\nExec=env MOZ_ENABLE_WAYLAND=1 firefox %u\n",
                ),
                (
                    "org.gnome.Nautilus.desktop",
                    "[Desktop Entry]\nName=Files\nName[de]=Dateien\nExec=nautilus --new-window %U\n",
                ),
                (
                    "hidden.desktop",
                    "[Desktop Entry]\nName=Gone\nHidden=true\nExec=gone\n",
                ),
                (
                    "link.desktop",
                    "[Desktop Entry]\nType=Link\nName=Site\nURL=https://x\n",
                ),
            ],
            &["de"],
        );
        let mut names = AppNames::with_entries(entries);
        assert_eq!(
            names.resolve(&window("Code", "code")),
            ResolvedApp {
                name: "Visual Studio Code".into(),
                id: "code".into()
            }
        );
        // Wayland app id matching the desktop-file id, localized.
        let nautilus = FocusedWindow {
            class: Some("org.gnome.Nautilus".into()),
            ..Default::default()
        };
        assert_eq!(names.resolve(&nautilus).name, "Dateien");
        // X11 class "firefox" → org.mozilla.firefox.desktop.
        assert_eq!(
            names.resolve(&window("firefox", "Navigator")).name,
            "Firefox-Browser"
        );
        assert_eq!(
            names
                .entries(false)
                .by_exec
                .get("firefox")
                .map(|e| e.id.as_str()),
            Some("org.mozilla.firefox")
        );
        assert!(!names.entries(false).by_id.contains_key("hidden"));
        assert!(!names.entries(false).by_id.contains_key("link"));
    }

    #[test]
    fn unknown_apps_fall_back_to_their_class() {
        let mut names = AppNames::with_entries(DesktopEntries::default());
        assert_eq!(
            names.resolve(&window("XTerm", "xterm")),
            ResolvedApp {
                name: "XTerm".into(),
                id: "xterm".into()
            }
        );
        let wayland = FocusedWindow {
            class: Some("com.example.Notes".into()),
            ..Default::default()
        };
        assert_eq!(names.resolve(&wayland).name, "Notes");
        assert_eq!(names.resolve(&FocusedWindow::default()).name, "Unknown app");
    }

    #[test]
    fn locales_expand_like_the_desktop_entry_spec() {
        assert_eq!(
            locale_keys_for("de_DE.UTF-8@euro"),
            vec!["de_DE@euro", "de_DE", "de@euro", "de"]
        );
        assert_eq!(locale_keys_for("sr_RS"), vec!["sr_RS", "sr"]);
        assert!(locale_keys_for("C.UTF-8").is_empty());
        assert!(locale_keys_for("").is_empty());
    }

    #[test]
    fn exec_lines() {
        assert_eq!(exec_basename("/usr/bin/gedit %U").as_deref(), Some("gedit"));
        assert_eq!(
            exec_basename("\"/opt/My App/app\" --x").as_deref(),
            Some("app")
        );
        assert_eq!(
            exec_basename("env A=1 B=2 slack %U").as_deref(),
            Some("slack")
        );
        assert_eq!(exec_basename("/usr/bin/flatpak run org.x.Y"), None);
    }

    #[test]
    fn own_process_resolves_from_proc() {
        let name = process_name(std::process::id());
        assert!(name.is_some_and(|n| !n.is_empty()));
    }
}
