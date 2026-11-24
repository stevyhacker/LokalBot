use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, S_OK};
use windows::Win32::Media::Audio::{
    AudioSessionStateActive, DEVICE_STATE_ACTIVE, EDataFlow, IAudioSessionControl2,
    IAudioSessionManager2, IMMDeviceEnumerator, MMDeviceEnumerator, eCapture, eRender,
};
use windows::Win32::System::Com::{
    CLSCTX_ALL, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize,
};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId, IsWindowVisible,
};
use windows::core::{BOOL, Interface};

use super::{
    CaptureStream, Evidence, EvidenceSource, WindowPrivacy, WindowTitle, browser_family,
    document_family, window_browser_family,
};

const UNCONFIRMED_RETRY: Duration = Duration::from_secs(10);

pub(super) struct WasapiEvidence {
    calls: crate::screen::BrowserCallReader,
    privacy: WindowPrivacyCache,
    scan_private_windows: bool,
}

impl WasapiEvidence {
    pub(super) fn new() -> Self {
        Self {
            calls: crate::screen::BrowserCallReader::new(),
            privacy: WindowPrivacyCache::new(),
            scan_private_windows: false,
        }
    }
}

pub(super) fn probe() -> Vec<super::BrowserWindowProbe> {
    let _com = ComScope::enter();
    let processes = process_table();
    let mut reader = crate::screen::BrowserInterfaceReader::new();
    browser_windows(&processes)
        .into_iter()
        .filter_map(|window| {
            let family = window_browser_family(&window.title.app)?;
            let interface = match reader.privacy(HWND(window.handle as *mut _)) {
                WindowPrivacy::Public => "public",
                WindowPrivacy::Private => "private",
                WindowPrivacy::Unknown => "unconfirmed",
            };
            Some(super::BrowserWindowProbe {
                family,
                title_marker: crate::privacy::is_private_window(&window.title.title),
                interface,
                title: window.title.title,
            })
        })
        .collect()
}

pub(crate) struct WindowPrivacyCache {
    reader: crate::screen::BrowserInterfaceReader,
    known: HashMap<isize, (WindowPrivacy, Instant)>,
}

impl WindowPrivacyCache {
    pub(crate) fn new() -> Self {
        Self {
            reader: crate::screen::BrowserInterfaceReader::new(),
            known: HashMap::new(),
        }
    }

    fn classify(&mut self, windows: &mut [BrowserWindow], families: &HashSet<&'static str>) {
        let now = Instant::now();
        self.known
            .retain(|handle, _| windows.iter().any(|window| window.handle == *handle));
        for window in windows {
            let watched = window_browser_family(&window.title.app)
                .is_some_and(|family| families.contains(family));
            if !watched || crate::privacy::is_private_window(&window.title.title) {
                continue;
            }
            let reusable = self.known.get(&window.handle).filter(|(privacy, at)| {
                *privacy != WindowPrivacy::Unknown
                    || now.saturating_duration_since(*at) < UNCONFIRMED_RETRY
            });
            window.title.privacy = match reusable {
                Some((privacy, _)) => *privacy,
                None => {
                    let privacy = self.reader.privacy(HWND(window.handle as *mut _));
                    self.known.insert(window.handle, (privacy, now));
                    privacy
                }
            };
        }
    }

    fn forget(&mut self) {
        self.known.clear();
    }
}

pub(crate) struct BrowserWindow {
    pub handle: isize,
    pub title: WindowTitle,
}

impl EvidenceSource for WasapiEvidence {
    fn scan_private_windows(&mut self, enabled: bool) {
        self.scan_private_windows = enabled;
        if !enabled {
            self.privacy.forget();
        }
    }

    fn collect(&mut self) -> anyhow::Result<Evidence> {
        let _com = ComScope::enter();
        let processes = process_table();
        let capturing: Vec<CaptureStream> = active_session_pids(eCapture)?
            .into_iter()
            .map(|pid| stream_for(pid, &processes))
            .collect();
        let browsing = capturing.iter().any(|stream| {
            std::iter::once(stream.process_name.as_str())
                .chain(stream.ancestors.iter().map(String::as_str))
                .any(|name| browser_family(name).is_some())
        });
        let windows = if browsing {
            let families = capturing
                .iter()
                .filter_map(|stream| {
                    std::iter::once(stream.process_name.as_str())
                        .chain(stream.ancestors.iter().map(String::as_str))
                        .find_map(browser_family)
                })
                .collect::<HashSet<_>>();
            let mut windows = browser_windows(&processes);
            if self.scan_private_windows {
                self.privacy.classify(&mut windows, &families);
            }
            windows.into_iter().map(|window| window.title).collect()
        } else {
            self.privacy.forget();
            Vec::new()
        };
        let rendering = active_session_pids(eRender)
            .unwrap_or_default()
            .into_iter()
            .map(|pid| stream_for(pid, &processes))
            .collect::<Vec<_>>();
        let active_families = capturing
            .iter()
            .chain(&rendering)
            .filter_map(|stream| {
                std::iter::once(stream.process_name.as_str())
                    .chain(stream.ancestors.iter().map(String::as_str))
                    .find_map(document_family)
            })
            .collect::<HashSet<_>>();
        let documents = self.calls.read(&active_families, |pid| {
            document_family(&processes.get(&pid)?.name)
        });
        Ok(Evidence {
            capturing,
            windows,
            documents,
        })
    }
}

struct ComScope {
    initialized: bool,
}

impl ComScope {
    fn enter() -> Self {
        let result = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        Self {
            initialized: result.is_ok(),
        }
    }
}

impl Drop for ComScope {
    fn drop(&mut self) {
        if self.initialized {
            unsafe { CoUninitialize() };
        }
    }
}

pub(crate) struct ProcessInfo {
    pub name: String,
    pub parent: u32,
}

pub(crate) fn process_table() -> HashMap<u32, ProcessInfo> {
    let mut table = HashMap::new();
    unsafe {
        let Ok(snapshot) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else {
            return table;
        };
        let mut entry = PROCESSENTRY32W {
            dwSize: size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        if Process32FirstW(snapshot, &mut entry).is_ok() {
            loop {
                let length = entry
                    .szExeFile
                    .iter()
                    .position(|&unit| unit == 0)
                    .unwrap_or(entry.szExeFile.len());
                let name = String::from_utf16_lossy(&entry.szExeFile[..length]);
                let name = if name.eq_ignore_ascii_case("browser.exe") {
                    let image = crate::activity::process_image(entry.th32ProcessID);
                    super::canonical_executable(
                        &name,
                        image.as_deref().and_then(std::path::Path::to_str),
                    )
                } else {
                    name
                };
                table.insert(
                    entry.th32ProcessID,
                    ProcessInfo {
                        name,
                        parent: entry.th32ParentProcessID,
                    },
                );
                if Process32NextW(snapshot, &mut entry).is_err() {
                    break;
                }
            }
        }
        let _ = CloseHandle(snapshot);
    }
    table
}

fn stream_for(pid: u32, processes: &HashMap<u32, ProcessInfo>) -> CaptureStream {
    let process_name = processes
        .get(&pid)
        .map(|info| info.name.clone())
        .unwrap_or_default();
    let mut ancestors = Vec::new();
    let mut ancestor_pids = Vec::new();
    let mut current = processes.get(&pid).map(|info| info.parent);
    while let Some(parent) = current
        && ancestors.len() < 6
        && parent != 0
        && parent != pid
    {
        let Some(info) = processes.get(&parent) else {
            break;
        };
        ancestors.push(info.name.clone());
        ancestor_pids.push(parent);
        current = Some(info.parent).filter(|next| *next != parent);
    }
    CaptureStream {
        pid,
        process_name,
        app_name: None,
        ancestors,
        ancestor_pids,
    }
}

pub(crate) fn active_session_pids(flow: EDataFlow) -> anyhow::Result<Vec<u32>> {
    let mut pids = Vec::new();
    unsafe {
        let enumerator: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
        let devices = enumerator.EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE)?;
        for index in 0..devices.GetCount()? {
            let Ok(device) = devices.Item(index) else {
                continue;
            };
            let Ok(manager) = device.Activate::<IAudioSessionManager2>(CLSCTX_ALL, None) else {
                continue;
            };
            let Ok(sessions) = manager.GetSessionEnumerator() else {
                continue;
            };
            for session in 0..sessions.GetCount().unwrap_or(0) {
                let Ok(control) = sessions.GetSession(session) else {
                    continue;
                };
                if control.GetState().ok() != Some(AudioSessionStateActive) {
                    continue;
                }
                let Ok(control) = control.cast::<IAudioSessionControl2>() else {
                    continue;
                };
                if control.IsSystemSoundsSession() == S_OK {
                    continue;
                }
                if let Ok(pid) = control.GetProcessId()
                    && pid != 0
                    && !pids.contains(&pid)
                {
                    pids.push(pid);
                }
            }
        }
    }
    Ok(pids)
}

struct WindowSearch<'a> {
    processes: &'a HashMap<u32, ProcessInfo>,
    found: Vec<BrowserWindow>,
}

unsafe extern "system" fn visit_window(window: HWND, lparam: LPARAM) -> BOOL {
    let search = unsafe { &mut *(lparam.0 as *mut WindowSearch<'_>) };
    unsafe {
        if !IsWindowVisible(window).as_bool() {
            return BOOL(1);
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(window, Some(&mut pid));
        let Some(info) = search.processes.get(&pid) else {
            return BOOL(1);
        };
        if browser_family(&info.name).is_none() {
            return BOOL(1);
        }
        let length = GetWindowTextLengthW(window);
        if length <= 0 {
            return BOOL(1);
        }
        let mut buffer = vec![0u16; length as usize + 1];
        let copied = GetWindowTextW(window, &mut buffer).max(0) as usize;
        search.found.push(BrowserWindow {
            handle: window.0 as isize,
            title: WindowTitle {
                app: info.name.clone(),
                title: String::from_utf16_lossy(&buffer[..copied]),
                privacy: WindowPrivacy::Public,
            },
        });
    }
    BOOL(1)
}

pub(crate) fn browser_windows(processes: &HashMap<u32, ProcessInfo>) -> Vec<BrowserWindow> {
    let mut search = WindowSearch {
        processes,
        found: Vec::new(),
    };
    unsafe {
        let _ = EnumWindows(
            Some(visit_window),
            LPARAM(&mut search as *mut WindowSearch<'_> as isize),
        );
    }
    search.found
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::Media::Audio::eRender;

    #[test]
    fn enumerates_audio_sessions() {
        let _com = ComScope::enter();
        let processes = process_table();
        assert!(processes.contains_key(&std::process::id()));
        let name = |pid: &u32| {
            processes
                .get(pid)
                .map(|info| info.name.clone())
                .unwrap_or_default()
        };
        match active_session_pids(eCapture) {
            Ok(pids) => eprintln!(
                "active capture sessions: {:?}",
                pids.iter().map(|pid| (pid, name(pid))).collect::<Vec<_>>()
            ),
            Err(err) => eprintln!("capture endpoints unavailable: {err:#}"),
        }
        match active_session_pids(eRender) {
            Ok(pids) => eprintln!(
                "active render sessions: {:?}",
                pids.iter().map(|pid| (pid, name(pid))).collect::<Vec<_>>()
            ),
            Err(err) => eprintln!("render endpoints unavailable: {err:#}"),
        }
        let mut detector = super::super::MeetingDetector::new();
        eprintln!("first poll: {:?}", detector.poll());
    }

    #[test]
    fn parents_are_followed() {
        let processes = process_table();
        let stream = stream_for(std::process::id(), &processes);
        assert!(stream.process_name.to_lowercase().ends_with(".exe"));
        eprintln!("test process ancestry: {:?}", stream.ancestors);
    }
}
