//! Windows evidence: processes with an active WASAPI capture session on any
//! active microphone (`IAudioSessionManager2`), their executable and parent
//! names from a ToolHelp snapshot, and browser window titles.

use std::collections::HashMap;

use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, S_OK};
use windows::Win32::Media::Audio::{
    AudioSessionStateActive, DEVICE_STATE_ACTIVE, EDataFlow, IAudioSessionControl2,
    IAudioSessionManager2, IMMDeviceEnumerator, MMDeviceEnumerator, eCapture,
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

use super::{CaptureStream, Evidence, EvidenceSource, WindowTitle, browser_family};

pub(super) struct WasapiEvidence;

impl WasapiEvidence {
    pub(super) fn new() -> Self {
        Self
    }
}

impl EvidenceSource for WasapiEvidence {
    fn collect(&mut self) -> anyhow::Result<Evidence> {
        let _com = ComScope::enter();
        let processes = process_table();
        let capturing: Vec<CaptureStream> = active_session_pids(eCapture)?
            .into_iter()
            .map(|pid| stream_for(pid, &processes))
            .collect();
        let windows = if capturing
            .iter()
            .any(|stream| browser_family(&stream.process_name).is_some())
        {
            browser_windows(&processes)
        } else {
            Vec::new()
        };
        Ok(Evidence { capturing, windows })
    }
}

/// Balances `CoInitializeEx` on this thread. A thread already in another
/// apartment keeps it; COM works there too.
struct ComScope {
    initialized: bool,
}

impl ComScope {
    fn enter() -> Self {
        // SAFETY: plain COM initialization for the calling thread; balanced
        // in `drop` when it succeeded.
        let result = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        Self {
            initialized: result.is_ok(),
        }
    }
}

impl Drop for ComScope {
    fn drop(&mut self) {
        if self.initialized {
            // SAFETY: matches the successful CoInitializeEx above.
            unsafe { CoUninitialize() };
        }
    }
}

/// Executable name and parent of every process.
pub(crate) struct ProcessInfo {
    pub name: String,
    pub parent: u32,
}

pub(crate) fn process_table() -> HashMap<u32, ProcessInfo> {
    let mut table = HashMap::new();
    // SAFETY: the snapshot handle is closed below; `entry` has dwSize set as
    // Process32FirstW requires.
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
                table.insert(
                    entry.th32ProcessID,
                    ProcessInfo {
                        name: String::from_utf16_lossy(&entry.szExeFile[..length]),
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
    let mut current = processes.get(&pid).map(|info| info.parent);
    // WebView2 and Electron helpers sit a few levels below the app.
    while let Some(parent) = current
        && ancestors.len() < 6
        && parent != 0
        && parent != pid
    {
        let Some(info) = processes.get(&parent) else {
            break;
        };
        ancestors.push(info.name.clone());
        current = Some(info.parent).filter(|next| *next != parent);
    }
    CaptureStream {
        pid,
        process_name,
        app_name: None,
        ancestors,
    }
}

/// Processes with an active (not merely open) session on any active
/// endpoint of `flow`, excluding the system-sounds session.
pub(crate) fn active_session_pids(flow: EDataFlow) -> anyhow::Result<Vec<u32>> {
    let mut pids = Vec::new();
    // SAFETY: COM calls on interfaces this function owns; COM is initialized
    // by the caller's `ComScope`.
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
    found: Vec<WindowTitle>,
}

unsafe extern "system" fn visit_window(window: HWND, lparam: LPARAM) -> BOOL {
    // SAFETY: `lparam` is the `WindowSearch` that `browser_windows` keeps
    // alive for the whole enumeration.
    let search = unsafe { &mut *(lparam.0 as *mut WindowSearch<'_>) };
    // SAFETY: plain queries on a window handle supplied by EnumWindows.
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
        search.found.push(WindowTitle {
            app: info.name.clone(),
            title: String::from_utf16_lossy(&buffer[..copied]),
        });
    }
    BOOL(1)
}

/// Titles of visible browser windows (each shows its active tab).
fn browser_windows(processes: &HashMap<u32, ProcessInfo>) -> Vec<WindowTitle> {
    let mut search = WindowSearch {
        processes,
        found: Vec::new(),
    };
    // SAFETY: the callback only runs during this call, while `search` lives.
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

    /// Reports what this machine's audio stack shows; over SSH there may be
    /// no audio session at all, which is fine.
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
