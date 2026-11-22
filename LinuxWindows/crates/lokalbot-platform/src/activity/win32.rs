use std::collections::HashMap;
use std::ffi::{OsString, c_void};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};

use chrono::Utc;
use lokalbot_core::ActivitySample;
use windows::Win32::Foundation::{CloseHandle, FILETIME, HWND, LPARAM, RECT};
use windows::Win32::Storage::FileSystem::{
    GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW,
};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::SystemInformation::GetTickCount;
use windows::Win32::System::Threading::{
    GetProcessTimes, OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    QueryFullProcessImageNameW,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumChildWindows, EnumWindows, GetClassNameW, GetForegroundWindow, GetWindowRect,
    GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId, IsWindowVisible,
};
use windows::core::{BOOL, PCWSTR, PWSTR};

use super::{ActivitySource, capitalized, own_window_sample};

pub(super) struct WindowsSource {
    own_pid: u32,
    names: HashMap<PathBuf, String>,
}

impl WindowsSource {
    pub(super) fn new() -> Self {
        Self {
            own_pid: std::process::id(),
            names: HashMap::new(),
        }
    }

    fn friendly_name(&mut self, image: &Path) -> String {
        if let Some(name) = self.names.get(image) {
            return name.clone();
        }
        let name = friendly_name(image);
        self.names.insert(image.to_path_buf(), name.clone());
        name
    }
}

impl ActivitySource for WindowsSource {
    fn sample(&mut self) -> anyhow::Result<Option<ActivitySample>> {
        let idle = self.idle_seconds().unwrap_or(0.0);
        let window = unsafe { GetForegroundWindow() };
        if window.0.is_null() {
            return Ok(None);
        }
        let mut pid = window_pid(window);
        if pid == 0 {
            return Ok(None);
        }
        if pid == self.own_pid {
            return Ok(Some(own_window_sample(idle)));
        }
        let class = window_class(window);
        let mut title = window_title(window);
        let mut image = process_image(pid);
        if image
            .as_deref()
            .is_some_and(|path| file_name(path).eq_ignore_ascii_case("ApplicationFrameHost.exe"))
            && let Some(app_pid) = hosted_app_pid(window, pid)
        {
            pid = app_pid;
            image = process_image(pid).or(image);
        }
        if pid == self.own_pid {
            return Ok(Some(own_window_sample(idle)));
        }
        if matches!(class.as_str(), "Progman" | "WorkerW") {
            title.clear();
        }
        let (app, app_id) = match &image {
            Some(path) => (self.friendly_name(path), file_name(path).to_lowercase()),
            None => ("Unknown app".to_string(), String::new()),
        };
        Ok(Some(ActivitySample {
            at: Utc::now(),
            app,
            app_id,
            title,
            url: None,
            idle_seconds: idle,
        }))
    }

    fn idle_seconds(&mut self) -> Option<f64> {
        let mut info = LASTINPUTINFO {
            cbSize: size_of::<LASTINPUTINFO>() as u32,
            dwTime: 0,
        };
        if !unsafe { GetLastInputInfo(&mut info) }.as_bool() {
            return None;
        }
        let now = unsafe { GetTickCount() };
        Some(f64::from(now.wrapping_sub(info.dwTime)) / 1000.0)
    }

    fn backend_name(&self) -> &'static str {
        "win32"
    }

    fn limitation(&self) -> Option<String> {
        None
    }
}

fn app_for_pid(pid: u32) -> Option<(String, String)> {
    let image = process_image(pid)?;
    Some((friendly_name(&image), file_name(&image).to_lowercase()))
}

pub(crate) fn host_app_for_pid(pid: u32) -> Option<(String, String)> {
    let fg = unsafe { GetForegroundWindow() };
    if fg.0.is_null() {
        return None;
    }
    let host_pid = window_pid(fg);
    if host_pid == 0
        || host_pid == pid
        || is_shell_or_host_wrapper(host_pid)
        || !window_owns_pid(fg, pid)
    {
        return None;
    }
    app_for_pid(host_pid)
}

pub(crate) fn effective_app_for_pid(pid: u32) -> Option<(String, String)> {
    let image = process_image(pid)?;
    let exe = file_name(&image);
    if exe.eq_ignore_ascii_case("msedgewebview2.exe")
        && let Some(host_app) = host_app_for_pid(pid)
    {
        return Some(host_app);
    }
    Some((friendly_name(&image), exe.to_lowercase()))
}

pub(crate) fn foreground_pid() -> Option<u32> {
    let window = unsafe { GetForegroundWindow() };
    if window.0.is_null() {
        return None;
    }
    let pid = window_pid(window);
    let image = process_image(pid)?;
    if file_name(&image).eq_ignore_ascii_case("ApplicationFrameHost.exe")
        && let Some(app_pid) = hosted_app_pid(window, pid)
    {
        return Some(app_pid);
    }
    Some(pid)
}

pub(super) fn foreground_app_id() -> Option<String> {
    let window = unsafe { GetForegroundWindow() };
    if window.0.is_null() {
        return None;
    }
    let mut pid = window_pid(window);
    let mut image = process_image(pid)?;
    if file_name(&image).eq_ignore_ascii_case("ApplicationFrameHost.exe")
        && let Some(app_pid) = hosted_app_pid(window, pid)
    {
        pid = app_pid;
        image = process_image(pid).unwrap_or(image);
    }
    Some(file_name(&image).to_lowercase())
}

fn window_pid(window: HWND) -> u32 {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(window, Some(&mut pid)) };
    pid
}

fn window_title(window: HWND) -> String {
    unsafe {
        let length = GetWindowTextLengthW(window);
        if length <= 0 {
            return String::new();
        }
        let mut buffer = vec![0u16; length as usize + 1];
        let copied = GetWindowTextW(window, &mut buffer);
        String::from_utf16_lossy(&buffer[..copied.max(0) as usize])
    }
}

fn window_class(window: HWND) -> String {
    let mut buffer = [0u16; 256];
    let copied = unsafe { GetClassNameW(window, &mut buffer) };
    String::from_utf16_lossy(&buffer[..copied.max(0) as usize])
}

fn process_image(pid: u32) -> Option<PathBuf> {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buffer = vec![0u16; 1024];
        let mut size = buffer.len() as u32;
        let result = QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            PWSTR(buffer.as_mut_ptr()),
            &mut size,
        );
        let _ = CloseHandle(process);
        result.ok()?;
        Some(PathBuf::from(OsString::from_wide(&buffer[..size as usize])))
    }
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

struct HostedSearch {
    host: u32,
    found: u32,
}

unsafe extern "system" fn visit_child(child: HWND, lparam: LPARAM) -> BOOL {
    let search = unsafe { &mut *(lparam.0 as *mut HostedSearch) };
    let pid = window_pid(child);
    if pid != 0 && pid != search.host {
        search.found = pid;
        return BOOL(0);
    }
    BOOL(1)
}

fn hosted_app_pid(frame: HWND, host: u32) -> Option<u32> {
    let mut search = HostedSearch { host, found: 0 };
    unsafe {
        let _ = EnumChildWindows(
            Some(frame),
            Some(visit_child),
            LPARAM(&mut search as *mut HostedSearch as isize),
        );
    }
    (search.found != 0).then_some(search.found)
}

struct TargetPidSearch {
    target: u32,
    found_thread: u32,
}

unsafe extern "system" fn visit_child_for_pid(child: HWND, lparam: LPARAM) -> BOOL {
    let search = unsafe { &mut *(lparam.0 as *mut TargetPidSearch) };
    let mut pid = 0u32;
    let thread = unsafe { GetWindowThreadProcessId(child, Some(&mut pid)) };
    if pid != 0 && pid == search.target && thread != 0 {
        search.found_thread = thread;
        return BOOL(0);
    }
    BOOL(1)
}

pub(crate) fn window_thread_for_pid(window: HWND, target_pid: u32) -> Option<u32> {
    if window.0.is_null() || target_pid == 0 {
        return None;
    }
    let mut owner = 0u32;
    let thread = unsafe { GetWindowThreadProcessId(window, Some(&mut owner)) };
    if owner == target_pid && thread != 0 {
        return Some(thread);
    }
    let mut search = TargetPidSearch {
        target: target_pid,
        found_thread: 0,
    };
    unsafe {
        let _ = EnumChildWindows(
            Some(window),
            Some(visit_child_for_pid),
            LPARAM(&mut search as *mut TargetPidSearch as isize),
        );
    }
    (search.found_thread != 0).then_some(search.found_thread)
}

pub(crate) fn window_owns_pid(window: HWND, target_pid: u32) -> bool {
    if window_thread_for_pid(window, target_pid).is_some() {
        return true;
    }
    if window.0.is_null() || target_pid == 0 {
        return false;
    }
    let detached = detached_webview_windows_for(window);
    if detached.is_empty() {
        return false;
    }
    if detached.iter().any(|(_, pid, _)| *pid == target_pid) {
        return true;
    }
    let parents = process_parents();
    detached
        .iter()
        .any(|(_, pid, _)| has_ancestor_in(&parents, target_pid, *pid))
}

fn is_shell_or_host_wrapper_name(name: &str) -> bool {
    let lower = name.to_lowercase();
    matches!(
        lower.as_str(),
        "explorer.exe"
            | "applicationframehost.exe"
            | "svchost.exe"
            | "services.exe"
            | "wininit.exe"
            | "wt.exe"
            | "wsl.exe"
            | "bash.exe"
            | "sh.exe"
            | "git-bash.exe"
    ) || crate::insert::TERMINALS.contains(&lower.as_str())
}

fn is_shell_or_host_wrapper(pid: u32) -> bool {
    let Some(image) = process_image(pid) else {
        return true;
    };
    is_shell_or_host_wrapper_name(&file_name(&image))
}

fn process_creation_time(pid: u32) -> Option<u64> {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut creation = FILETIME::default();
        let mut exit = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user = FILETIME::default();
        let result = GetProcessTimes(process, &mut creation, &mut exit, &mut kernel, &mut user);
        let _ = CloseHandle(process);
        result.ok()?;
        Some((u64::from(creation.dwHighDateTime) << 32) | u64::from(creation.dwLowDateTime))
    }
}

fn process_parents() -> HashMap<u32, u32> {
    let mut parents = HashMap::new();
    unsafe {
        let Ok(snapshot) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else {
            return parents;
        };
        let mut entry = PROCESSENTRY32W {
            dwSize: size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        if Process32FirstW(snapshot, &mut entry).is_ok() {
            loop {
                parents.insert(entry.th32ProcessID, entry.th32ParentProcessID);
                if Process32NextW(snapshot, &mut entry).is_err() {
                    break;
                }
            }
        }
        let _ = CloseHandle(snapshot);
    }
    parents
}

fn has_ancestor_with(
    parents: &HashMap<u32, u32>,
    mut pid: u32,
    ancestor: u32,
    is_wrapper: impl Fn(u32) -> bool,
    creation_time: impl Fn(u32) -> Option<u64>,
) -> bool {
    if pid == 0 || ancestor == 0 || pid == ancestor {
        return false;
    }
    for _ in 0..4 {
        let Some(&parent) = parents.get(&pid) else {
            return false;
        };
        if parent == 0 || parent == pid {
            return false;
        }
        let (Some(child_created), Some(parent_created)) =
            (creation_time(pid), creation_time(parent))
        else {
            return false;
        };
        if parent_created > child_created {
            return false;
        }
        if parent == ancestor {
            return true;
        }
        if is_wrapper(parent) {
            return false;
        }
        pid = parent;
    }
    false
}

fn has_ancestor_in(parents: &HashMap<u32, u32>, pid: u32, ancestor: u32) -> bool {
    has_ancestor_with(
        parents,
        pid,
        ancestor,
        is_shell_or_host_wrapper,
        process_creation_time,
    )
}

fn child_window_overlap_area(
    child: (i32, i32, i32, i32),
    host: (i32, i32, i32, i32),
) -> Option<i64> {
    let child_w = i64::from(child.2) - i64::from(child.0);
    let child_h = i64::from(child.3) - i64::from(child.1);
    let host_w = i64::from(host.2) - i64::from(host.0);
    let host_h = i64::from(host.3) - i64::from(host.1);
    if child_w < 32 || child_h < 24 || host_w <= 0 || host_h <= 0 {
        return None;
    }
    let overlap_w = i64::from(child.2.min(host.2)) - i64::from(child.0.max(host.0));
    let overlap_h = i64::from(child.3.min(host.3)) - i64::from(child.1.max(host.1));
    if overlap_w <= 0 || overlap_h <= 0 {
        return None;
    }
    let overlap = overlap_w * overlap_h;
    let child_area = child_w * child_h;
    (overlap * 4 >= child_area).then_some(overlap)
}

struct WebViewCandidates {
    exclude_pid: u32,
    host_bounds: (i32, i32, i32, i32),
    items: Vec<(HWND, u32, i64)>,
}

unsafe extern "system" fn collect_webview_windows(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let state = unsafe { &mut *(lparam.0 as *mut WebViewCandidates) };
    if unsafe { IsWindowVisible(hwnd) }.as_bool() {
        let pid = window_pid(hwnd);
        if pid != 0 && pid != state.exclude_pid {
            let mut rect = RECT::default();
            if unsafe { GetWindowRect(hwnd, &mut rect) }.is_ok()
                && let Some(overlap) = child_window_overlap_area(
                    (rect.left, rect.top, rect.right, rect.bottom),
                    state.host_bounds,
                )
            {
                state.items.push((hwnd, pid, overlap));
            }
        }
    }
    BOOL(1)
}

fn detached_webview_windows_for(window: HWND) -> Vec<(HWND, u32, i64)> {
    if window.0.is_null() {
        return Vec::new();
    }
    let owner = window_pid(window);
    if owner == 0 || is_shell_or_host_wrapper(owner) {
        return Vec::new();
    }
    let mut bounds = RECT::default();
    if unsafe { GetWindowRect(window, &mut bounds) }.is_err() {
        return Vec::new();
    }
    let mut candidates = WebViewCandidates {
        exclude_pid: owner,
        host_bounds: (bounds.left, bounds.top, bounds.right, bounds.bottom),
        items: Vec::new(),
    };
    unsafe {
        let _ = EnumWindows(
            Some(collect_webview_windows),
            LPARAM(&mut candidates as *mut WebViewCandidates as isize),
        );
    }
    if candidates.items.is_empty() {
        return Vec::new();
    }
    let parents = process_parents();
    candidates
        .items
        .into_iter()
        .filter(|(_, pid, _)| has_ancestor_in(&parents, *pid, owner))
        .collect()
}

pub(crate) fn detached_webview_window_for_foreground() -> Option<HWND> {
    let fg = unsafe { GetForegroundWindow() };
    detached_webview_windows_for(fg)
        .into_iter()
        .max_by_key(|(_, _, overlap)| *overlap)
        .map(|(hwnd, _, _)| hwnd)
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

pub(crate) fn friendly_name(image: &Path) -> String {
    let stem = image
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_default();
    if stem.eq_ignore_ascii_case("explorer") {
        return "File Explorer".into();
    }
    version_string(image, "FileDescription")
        .or_else(|| version_string(image, "ProductName"))
        .unwrap_or_else(|| capitalized(&stem))
}

fn version_string(image: &Path, key: &str) -> Option<String> {
    let path: Vec<u16> = image.as_os_str().encode_wide().chain(Some(0)).collect();
    unsafe {
        let size = GetFileVersionInfoSizeW(PCWSTR(path.as_ptr()), None);
        if size == 0 {
            return None;
        }
        let mut data = vec![0u8; size as usize];
        GetFileVersionInfoW(PCWSTR(path.as_ptr()), None, size, data.as_mut_ptr().cast()).ok()?;
        let block = data.as_ptr().cast::<c_void>();

        let mut translations: Vec<(u16, u16)> = Vec::new();
        let query = wide("\\VarFileInfo\\Translation");
        let mut pointer: *mut c_void = std::ptr::null_mut();
        let mut length = 0u32;
        if VerQueryValueW(block, PCWSTR(query.as_ptr()), &mut pointer, &mut length).as_bool()
            && !pointer.is_null()
        {
            let words = std::slice::from_raw_parts(pointer.cast::<u16>(), (length / 2) as usize);
            translations.extend(
                words
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|[language, codepage]| (*language, *codepage)),
            );
        }
        translations.extend([(0x0409, 0x04B0), (0x0409, 0x04E4), (0x0000, 0x04B0)]);

        for (language, codepage) in translations {
            let query = wide(&format!(
                "\\StringFileInfo\\{language:04x}{codepage:04x}\\{key}"
            ));
            let mut value: *mut c_void = std::ptr::null_mut();
            let mut chars = 0u32;
            if VerQueryValueW(block, PCWSTR(query.as_ptr()), &mut value, &mut chars).as_bool()
                && !value.is_null()
                && chars > 0
            {
                let units = std::slice::from_raw_parts(value.cast::<u16>(), chars as usize);
                let text = String::from_utf16_lossy(units);
                let text = text.trim_end_matches('\0').trim();
                if !text.is_empty() {
                    return Some(text.to_string());
                }
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_executables_have_friendly_names() {
        let windows = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
        let notepad = Path::new(&windows).join("System32").join("notepad.exe");
        if notepad.exists() {
            assert_eq!(friendly_name(&notepad), "Notepad");
        }
        let cmd = Path::new(&windows).join("System32").join("cmd.exe");
        assert!(!friendly_name(&cmd).is_empty());
        assert_eq!(
            friendly_name(Path::new(r"C:\Windows\explorer.exe")),
            "File Explorer"
        );
        assert_eq!(friendly_name(Path::new(r"C:\missing\tool.exe")), "Tool");
    }

    #[test]
    fn sampling_never_fails_without_a_desktop() {
        let mut source = WindowsSource::new();
        let sample = source.sample().unwrap();
        eprintln!("windows sample: {sample:?}");
        assert!(source.idle_seconds().is_some_and(|idle| idle >= 0.0));
        assert_eq!(source.backend_name(), "win32");
    }

    #[test]
    fn own_process_image_is_readable() {
        let image = process_image(std::process::id()).unwrap();
        assert!(image.is_absolute());
        assert!(file_name(&image).to_lowercase().ends_with(".exe"));
    }

    #[test]
    fn detached_child_window_overlap_requires_substantial_bounds() {
        let host = (100, 100, 1100, 800);
        assert_eq!(
            child_window_overlap_area((100, 140, 1100, 800), host),
            Some(1000 * 660)
        );
        assert_eq!(
            child_window_overlap_area((2000, 100, 2500, 600), host),
            None
        );
        assert_eq!(
            child_window_overlap_area((1080, 100, 1400, 600), host),
            None
        );
        assert_eq!(child_window_overlap_area((100, 100, 110, 110), host), None);
    }

    #[test]
    fn host_wrapper_filter_excludes_shells_and_terminals() {
        for blocked in [
            "explorer.exe",
            "ApplicationFrameHost.exe",
            "WindowsTerminal.exe",
            "cmd.exe",
            "powershell.exe",
            "pwsh.exe",
            "conhost.exe",
            "wsl.exe",
            "bash.exe",
        ] {
            assert!(is_shell_or_host_wrapper_name(blocked), "{blocked}");
        }
        for allowed in ["olk.exe", "WhatsApp.exe", "ms-teams.exe", "steam.exe"] {
            assert!(!is_shell_or_host_wrapper_name(allowed), "{allowed}");
        }
    }

    #[test]
    fn ancestor_walk_rejects_reused_pids_missing_times_and_terminal_hops() {
        let parents = HashMap::from([(300, 200), (200, 100)]);
        let ordered_times = HashMap::from([(100, 10), (200, 20), (300, 30)]);
        assert!(has_ancestor_with(
            &parents,
            300,
            100,
            |_| false,
            |pid| ordered_times.get(&pid).copied(),
        ));
        assert!(!has_ancestor_with(
            &parents,
            300,
            100,
            |pid| pid == 200,
            |pid| ordered_times.get(&pid).copied(),
        ));
        let reused_parent_times = HashMap::from([(100, 40), (200, 20), (300, 30)]);
        assert!(!has_ancestor_with(
            &parents,
            300,
            100,
            |_| false,
            |pid| reused_parent_times.get(&pid).copied(),
        ));
        assert!(!has_ancestor_with(
            &parents,
            300,
            100,
            |_| false,
            |pid| (pid != 200).then_some(10),
        ));
    }
}
