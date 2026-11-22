use lokalbot_core::ActivitySample;

#[cfg(target_os = "linux")]
mod desktop_entries;
#[cfg(target_os = "linux")]
mod idle;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
mod wayland;
#[cfg(windows)]
mod win32;
#[cfg(target_os = "linux")]
mod x11;

#[cfg(target_os = "linux")]
pub(crate) use linux::{AppResolver, FrontWindow, FrontWindows, WindowLister};
#[cfg(windows)]
pub(crate) use win32::{
    detached_webview_window_for_foreground, effective_app_for_pid, foreground_pid,
    host_app_for_pid, window_owns_pid, window_thread_for_pid,
};

pub trait ActivitySource: Send {
    fn sample(&mut self) -> anyhow::Result<Option<ActivitySample>>;
    fn idle_seconds(&mut self) -> Option<f64>;
    fn backend_name(&self) -> &'static str;
    fn limitation(&self) -> Option<String>;
}

pub fn activity_source() -> Box<dyn ActivitySource> {
    #[cfg(windows)]
    {
        Box::new(win32::WindowsSource::new())
    }
    #[cfg(target_os = "linux")]
    {
        linux::source()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Box::new(Unavailable::new(
            "Activity tracking is not available on this system.".into(),
        ))
    }
}

pub(crate) fn focused_app_hint() -> Option<String> {
    #[cfg(windows)]
    {
        win32::foreground_app_id()
    }
    #[cfg(target_os = "linux")]
    {
        linux::focused_app_hint()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        None
    }
}

pub struct Unavailable {
    reason: String,
}

impl Unavailable {
    pub fn new(reason: String) -> Self {
        Self { reason }
    }
}

impl ActivitySource for Unavailable {
    fn sample(&mut self) -> anyhow::Result<Option<ActivitySample>> {
        Ok(None)
    }

    fn idle_seconds(&mut self) -> Option<f64> {
        None
    }

    fn backend_name(&self) -> &'static str {
        "unavailable"
    }

    fn limitation(&self) -> Option<String> {
        Some(self.reason.clone())
    }
}

pub(crate) fn own_window_sample(idle_seconds: f64) -> ActivitySample {
    ActivitySample {
        at: chrono::Utc::now(),
        app: "LokalBot".into(),
        app_id: crate::privacy::SELF_APP_ID.into(),
        title: String::new(),
        url: None,
        idle_seconds,
    }
}

pub(crate) fn capitalized(name: &str) -> String {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}
