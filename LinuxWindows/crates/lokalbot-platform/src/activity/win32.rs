//! Windows: the foreground window (`GetForegroundWindow`), its title, the
//! owning process's name from its executable's version resources
//! (`FileDescription`, then `ProductName`, then the file name), and idle time
//! from `GetLastInputInfo`.

use std::collections::HashMap;
use std::ffi::{OsString, c_void};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};

use chrono::Utc;
use lokalbot_core::ActivitySample;
use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM};
use windows::Win32::Storage::FileSystem::{
    GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW,
};
use windows::Win32::System::SystemInformation::GetTickCount;
use windows::Win32::System::Threading::{
    OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumChildWindows, GetClassNameW, GetForegroundWindow, GetWindowTextLengthW, GetWindowTextW,
    GetWindowThreadProcessId,
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
        // SAFETY: no arguments; returns a possibly null window handle.
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
        // Store apps draw inside ApplicationFrameHost; their own process owns
        // a child window.
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
            // The desktop itself ("Program Manager").
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
        // SAFETY: `info` is a valid LASTINPUTINFO with cbSize set.
        if !unsafe { GetLastInputInfo(&mut info) }.as_bool() {
            return None;
        }
        // SAFETY: no arguments. Both values wrap every 49.7 days together.
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

/// `(friendly name, lowercase executable)` of a process, by day memory's
/// rules, for autocomplete's exclusions.
pub(crate) fn app_for_pid(pid: u32) -> Option<(String, String)> {
    let image = process_image(pid)?;
    Some((friendly_name(&image), file_name(&image).to_lowercase()))
}

/// Lowercase executable name of the foreground window's process.
pub(super) fn foreground_app_id() -> Option<String> {
    // SAFETY: no arguments; returns a possibly null window handle.
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
    // SAFETY: `pid` outlives the call; an invalid window leaves it 0.
    unsafe { GetWindowThreadProcessId(window, Some(&mut pid)) };
    pid
}

fn window_title(window: HWND) -> String {
    // SAFETY: reads the caption into a buffer of the reported length. For
    // other processes this never sends WM_GETTEXT, so a hung app cannot
    // block the sampler.
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
    // SAFETY: the buffer is writable for its full length.
    let copied = unsafe { GetClassNameW(window, &mut buffer) };
    String::from_utf16_lossy(&buffer[..copied.max(0) as usize])
}

/// Full path of a process's executable, if this user may query it.
fn process_image(pid: u32) -> Option<PathBuf> {
    // SAFETY: the handle is closed below; the buffer is writable for `size`
    // UTF-16 units and `size` is updated to the length written.
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
    // SAFETY: `lparam` is the address of the `HostedSearch` that
    // `hosted_app_pid` keeps alive for the whole enumeration.
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
    // SAFETY: the callback only runs during this call, while `search` lives.
    unsafe {
        let _ = EnumChildWindows(
            Some(frame),
            Some(visit_child),
            LPARAM(&mut search as *mut HostedSearch as isize),
        );
    }
    (search.found != 0).then_some(search.found)
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

/// `FileDescription`, then `ProductName`, then the file name.
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
    // SAFETY: `data` holds the whole version block for as long as the
    // pointers VerQueryValueW returns into it are read; every read stays
    // within the lengths it reports.
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
        // Over SSH (session 0) there is no foreground window; that is fine.
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
}
