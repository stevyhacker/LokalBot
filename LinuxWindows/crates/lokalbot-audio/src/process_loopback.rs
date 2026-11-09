//! Windows: one process tree's sound through WASAPI process loopback, the
//! counterpart of `CoreAudioProcessTap`. It needs Windows 10 build 20348 or
//! later, which is checked at run time; older systems record the whole output.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Duration;

use anyhow::{Context as _, Result, anyhow};
use windows::Wdk::System::SystemServices::RtlGetVersion;
use windows::Win32::Foundation::{CloseHandle, HANDLE, S_OK, WAIT_OBJECT_0};
use windows::Win32::Media::Audio::{
    AUDCLNT_BUFFERFLAGS_SILENT, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
    AUDCLNT_STREAMFLAGS_LOOPBACK, AUDIOCLIENT_ACTIVATION_PARAMS, AUDIOCLIENT_ACTIVATION_PARAMS_0,
    AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK, AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS,
    ActivateAudioInterfaceAsync, AudioSessionStateActive, DEVICE_STATE_ACTIVE,
    IActivateAudioInterfaceAsyncOperation, IActivateAudioInterfaceCompletionHandler,
    IActivateAudioInterfaceCompletionHandler_Impl, IAudioCaptureClient, IAudioClient,
    IAudioSessionControl2, IAudioSessionManager2, IMMDeviceEnumerator, MMDeviceEnumerator,
    PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE, VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
    WAVE_FORMAT_PCM, WAVEFORMATEX, eRender,
};
use windows::Win32::System::Com::StructuredStorage::{
    PROPVARIANT, PROPVARIANT_0, PROPVARIANT_0_0, PROPVARIANT_0_0_0,
};
use windows::Win32::System::Com::{
    BLOB, CLSCTX_ALL, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize,
    IAgileObject, IAgileObject_Impl,
};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::SystemInformation::OSVERSIONINFOW;
use windows::Win32::System::Threading::{CreateEventW, WaitForSingleObject};
use windows::Win32::System::Variant::VT_BLOB;
use windows::core::{IUnknown, Interface, Ref, implement};

use crate::app_audio::{AppStream, build_has_process_loopback};
use crate::capture::StreamFlags;
use crate::track::ChunkSink;

/// How long Windows may take to activate the client.
const ACTIVATION_TIMEOUT: Duration = Duration::from_secs(5);
/// Windows' own process loopback sample records this format; it mixes down
/// whatever the process plays. Process loopback has no mix format to ask for.
const SAMPLE_RATE: u32 = 44_100;
const CHANNELS: u16 = 2;
const BITS: u16 = 16;
/// 200 ms, in 100 ns units.
const BUFFER_DURATION: i64 = 2_000_000;
const WAIT_MS: u32 = 100;

/// Whether this Windows has process loopback.
pub(crate) fn supported() -> bool {
    let mut info = OSVERSIONINFOW {
        dwOSVersionInfoSize: size_of::<OSVERSIONINFOW>() as u32,
        ..Default::default()
    };
    // SAFETY: `info` is valid and its size field is set, as the call requires.
    let status = unsafe { RtlGetVersion(&mut info) };
    status.is_ok() && build_has_process_loopback(info.dwBuildNumber)
}

/// Balances `CoInitializeEx` on this thread.
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

/// Parents of every process.
fn process_parents() -> HashMap<u32, u32> {
    let mut parents = HashMap::new();
    // SAFETY: the snapshot handle is closed below; `entry` has dwSize set as
    // Process32FirstW requires.
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

/// Whether `pid` is `root` or one of its descendants.
fn in_tree(pid: u32, root: u32, parents: &HashMap<u32, u32>) -> bool {
    let mut current = pid;
    for _ in 0..16 {
        if current == root {
            return true;
        }
        match parents.get(&current) {
            Some(parent) if *parent != 0 && *parent != current => current = *parent,
            _ => return false,
        }
    }
    false
}

/// The processes of `root`'s tree with an active session on any output.
/// `None` when the sessions can't be read.
pub(crate) fn playing_processes(root: u32) -> Option<Vec<AppStream>> {
    let _com = ComScope::enter();
    let parents = process_parents();
    if parents.is_empty() {
        return None;
    }
    let mut streams = Vec::new();
    // SAFETY: COM calls on interfaces this function owns; COM is initialized
    // by the scope above.
    unsafe {
        let enumerator: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).ok()?;
        let devices = enumerator
            .EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE)
            .ok()?;
        for index in 0..devices.GetCount().ok()? {
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
                    && in_tree(pid, root, &parents)
                {
                    streams.push(AppStream {
                        id: pid,
                        device: index,
                    });
                }
            }
        }
    }
    Some(streams)
}

#[implement(IActivateAudioInterfaceCompletionHandler, IAgileObject)]
struct Activation(mpsc::Sender<windows::core::Result<IUnknown>>);

impl IAgileObject_Impl for Activation_Impl {}

impl IActivateAudioInterfaceCompletionHandler_Impl for Activation_Impl {
    fn ActivateCompleted(
        &self,
        operation: Ref<'_, IActivateAudioInterfaceAsyncOperation>,
    ) -> windows::core::Result<()> {
        let result = operation.ok().and_then(|operation| {
            let mut status = windows::core::HRESULT::default();
            let mut interface: Option<IUnknown> = None;
            // SAFETY: both out parameters live for the call.
            unsafe { operation.GetActivateResult(&mut status, &mut interface)? };
            status.ok()?;
            interface.ok_or_else(windows::core::Error::empty)
        });
        let _ = self.0.send(result);
        Ok(())
    }
}

/// Asks Windows for an audio client that hears only `pid`'s process tree.
fn activate(pid: u32) -> Result<IAudioClient> {
    let mut parameters = AUDIOCLIENT_ACTIVATION_PARAMS {
        ActivationType: AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK,
        Anonymous: AUDIOCLIENT_ACTIVATION_PARAMS_0 {
            ProcessLoopbackParams: AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
                TargetProcessId: pid,
                ProcessLoopbackMode: PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE,
            },
        },
    };
    // Raw union, so nothing tries to free the blob, which lives on this stack.
    let variant = PROPVARIANT {
        Anonymous: PROPVARIANT_0 {
            Anonymous: std::mem::ManuallyDrop::new(PROPVARIANT_0_0 {
                vt: VT_BLOB,
                wReserved1: 0,
                wReserved2: 0,
                wReserved3: 0,
                Anonymous: PROPVARIANT_0_0_0 {
                    blob: BLOB {
                        cbSize: size_of::<AUDIOCLIENT_ACTIVATION_PARAMS>() as u32,
                        pBlobData: (&raw mut parameters).cast(),
                    },
                },
            }),
        },
    };
    let (tx, rx) = mpsc::channel();
    let handler: IActivateAudioInterfaceCompletionHandler = Activation(tx).into();
    // SAFETY: `variant` and `parameters` outlive the call, which copies them.
    unsafe {
        ActivateAudioInterfaceAsync(
            VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
            &IAudioClient::IID,
            Some(&variant),
            &handler,
        )
    }
    .context("process loopback did not start")?;
    let interface = rx
        .recv_timeout(ACTIVATION_TIMEOUT)
        .map_err(|_| anyhow!("process loopback did not answer"))?
        .context("process loopback was refused")?;
    interface.cast().context("process loopback gave no client")
}

/// A running client and the event that says a buffer is ready.
struct Session {
    client: IAudioClient,
    capture: IAudioCaptureClient,
    ready: HANDLE,
}

impl Session {
    fn open(pid: u32) -> Result<Self> {
        let client = activate(pid)?;
        let block = CHANNELS * BITS / 8;
        let format = WAVEFORMATEX {
            wFormatTag: WAVE_FORMAT_PCM as u16,
            nChannels: CHANNELS,
            nSamplesPerSec: SAMPLE_RATE,
            nAvgBytesPerSec: SAMPLE_RATE * u32::from(block),
            nBlockAlign: block,
            wBitsPerSample: BITS,
            cbSize: 0,
        };
        // SAFETY: `format` outlives the calls; the event is closed in `drop`.
        unsafe {
            client
                .Initialize(
                    AUDCLNT_SHAREMODE_SHARED,
                    AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                    BUFFER_DURATION,
                    0,
                    &format,
                    None,
                )
                .context("process loopback refused its format")?;
            let ready = CreateEventW(None, false, false, None)?;
            let session = Self {
                capture: client.GetService()?,
                client,
                ready,
            };
            session.client.SetEventHandle(session.ready)?;
            session.client.Start()?;
            Ok(session)
        }
    }

    /// Passes every waiting packet to `sink` as mono.
    fn drain(&self, sink: &ChunkSink) -> windows::core::Result<()> {
        // SAFETY: the buffer is read only between GetBuffer and ReleaseBuffer,
        // and holds `frames` frames of the format `open` set.
        unsafe {
            while self.capture.GetNextPacketSize()? > 0 {
                let mut data = std::ptr::null_mut();
                let (mut frames, mut flags) = (0u32, 0u32);
                self.capture
                    .GetBuffer(&mut data, &mut frames, &mut flags, None, None)?;
                let silent = flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0;
                let samples: Vec<f32> = if silent || data.is_null() {
                    vec![0.0; frames as usize]
                } else {
                    let raw = std::slice::from_raw_parts(
                        data.cast::<i16>(),
                        frames as usize * usize::from(CHANNELS),
                    );
                    raw.chunks_exact(usize::from(CHANNELS))
                        .map(|frame| {
                            frame.iter().map(|s| f32::from(*s) / 32_768.0).sum::<f32>()
                                / f32::from(CHANNELS)
                        })
                        .collect()
                };
                self.capture.ReleaseBuffer(frames)?;
                sink.push_captured(samples, SAMPLE_RATE, None);
            }
        }
        Ok(())
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // SAFETY: the client and event are this session's own.
        unsafe {
            let _ = self.client.Stop();
            let _ = CloseHandle(self.ready);
        }
    }
}

/// A running tap. Dropping it stops the capture.
pub(crate) struct ProcessLoopback {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl ProcessLoopback {
    /// Returns once the tap records, or with the reason it can't.
    pub fn start(pid: u32, sink: ChunkSink, flags: Arc<StreamFlags>) -> Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let (ready_tx, ready_rx) = mpsc::channel();
        let thread_stop = Arc::clone(&stop);
        let thread = std::thread::Builder::new()
            .name("lokalbot-process-loopback".into())
            .spawn(move || {
                let _com = ComScope::enter();
                let session = match Session::open(pid) {
                    Ok(session) => {
                        let _ = ready_tx.send(Ok(()));
                        session
                    }
                    Err(error) => {
                        let _ = ready_tx.send(Err(error));
                        return;
                    }
                };
                while !thread_stop.load(Ordering::Relaxed) {
                    // SAFETY: the event lives as long as `session`.
                    let woken = unsafe { WaitForSingleObject(session.ready, WAIT_MS) };
                    if woken != WAIT_OBJECT_0 {
                        continue;
                    }
                    if let Err(error) = session.drain(&sink) {
                        flags.fail(format!("process loopback: {}", error.message()));
                        break;
                    }
                }
            })
            .context("could not start the process loopback thread")?;
        let mut capture = Self {
            stop,
            thread: Some(thread),
        };
        match ready_rx.recv_timeout(ACTIVATION_TIMEOUT * 2) {
            Ok(Ok(())) => Ok(capture),
            Ok(Err(error)) => {
                capture.finish();
                Err(error)
            }
            Err(_) => {
                capture.finish();
                Err(anyhow!("process loopback did not start"))
            }
        }
    }

    fn finish(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for ProcessLoopback {
    fn drop(&mut self) {
        self.finish();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_process_belongs_to_a_tree_through_its_parents() {
        let parents = HashMap::from([(30, 20), (20, 10), (10, 0), (99, 98)]);
        assert!(in_tree(30, 10, &parents));
        assert!(in_tree(10, 10, &parents));
        assert!(!in_tree(99, 10, &parents));
        assert!(!in_tree(10, 30, &parents));
    }
}
