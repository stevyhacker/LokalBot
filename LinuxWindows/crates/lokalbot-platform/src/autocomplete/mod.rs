// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 18 October 2026.
// See THIRD_PARTY_NOTICES.md.

pub mod clipboard;
pub mod focused;
pub mod geometry;
pub mod policy;
pub mod session;
pub mod spell;
pub mod visible;

#[cfg(target_os = "linux")]
mod atspi;
#[cfg(target_os = "linux")]
mod input_method;
#[cfg(windows)]
mod uia;
#[cfg(windows)]
mod win32;
#[cfg(target_os = "linux")]
mod x11;

use std::sync::Arc;

pub use geometry::{FieldStyle, Rect, Rgb};
pub use policy::ReadPolicy;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Capability {
    Supported,
    Blocked(&'static str),
    Unsupported(&'static str),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FieldSnapshot {
    pub focus_key: String,
    pub app_name: String,
    pub app_id: String,
    pub pid: u32,
    pub window_title: String,
    pub before: String,
    pub before_truncated: bool,
    pub after: String,
    pub caret: Rect,
    pub caret_exact: bool,
    pub field_frame: Option<Rect>,
    pub single_line: bool,
    pub is_integrated_terminal: bool,
    pub url: Option<String>,
    pub visible_text: Option<String>,
    pub style: Option<FieldStyle>,
    pub target: InsertTarget,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct InsertTarget {
    #[cfg(target_os = "linux")]
    pub(crate) editable: Option<(String, String)>,
    pub(crate) pid: u32,
    #[cfg(target_os = "linux")]
    pub(crate) input_method: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FocusSnapshot {
    pub app_name: String,
    pub app_id: String,
    pub capability: Capability,
    pub field: Option<FieldSnapshot>,
    pub focus_key: Option<String>,
}

impl FocusSnapshot {
    pub fn none() -> Self {
        Self {
            app_name: String::new(),
            app_id: String::new(),
            capability: Capability::Unsupported(policy::reasons::NO_FIELD),
            field: None,
            focus_key: None,
        }
    }

    fn blocked(app_name: &str, app_id: &str, reason: &'static str, key: Option<String>) -> Self {
        Self {
            app_name: app_name.into(),
            app_id: app_id.into(),
            capability: Capability::Blocked(reason),
            field: None,
            focus_key: key,
        }
    }

    fn unsupported(app_name: &str, app_id: &str, reason: &'static str) -> Self {
        Self {
            app_name: app_name.into(),
            app_id: app_id.into(),
            capability: Capability::Unsupported(reason),
            field: None,
            focus_key: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Support {
    Available,
    Unavailable(String),
}

pub fn support() -> Support {
    #[cfg(target_os = "linux")]
    {
        if crate::session::is_wayland() {
            return input_method::support();
        }
        if !crate::session::has_x11_display() {
            return Support::Unavailable(
                "No desktop session was found, so autocomplete cannot see other apps.".into(),
            );
        }
        Support::Available
    }
    #[cfg(windows)]
    {
        Support::Available
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Support::Unavailable("Autocomplete is not available on this system.".into())
    }
}

pub fn ibus_component() -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        Some(input_method::ibus_component())
    }
    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

pub fn run_kwin_input_method() -> i32 {
    #[cfg(target_os = "linux")]
    {
        input_method::run_kwin_helper()
    }
    #[cfg(not(target_os = "linux"))]
    {
        2
    }
}

pub fn kwin_input_method_entry() -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        Some(input_method::kwin_desktop_entry())
    }
    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputSourceSteps {
    pub text: String,
    pub command: Option<String>,
}

pub fn input_source_steps() -> Option<InputSourceSteps> {
    #[cfg(target_os = "linux")]
    {
        if crate::session::is_wayland() {
            return input_method::input_source_steps();
        }
    }
    None
}

type FocusHandler = Arc<dyn Fn(FocusSnapshot) + Send + Sync>;
type KeyHandler = Arc<dyn Fn(InterceptedKey) + Send + Sync>;

pub struct FieldWatcher {
    #[cfg(target_os = "linux")]
    inner: LinuxWatcher,
    #[cfg(windows)]
    inner: uia::Watcher,
}

#[cfg(target_os = "linux")]
enum LinuxWatcher {
    Accessibility(atspi::Watcher),
    InputMethod(input_method::Watcher),
}

impl FieldWatcher {
    pub fn start(
        policy: ReadPolicy,
        handler: impl Fn(FocusSnapshot) + Send + Sync + 'static,
    ) -> anyhow::Result<Self> {
        let handler: FocusHandler = Arc::new(handler);
        #[cfg(target_os = "linux")]
        {
            if let Support::Unavailable(reason) = support() {
                anyhow::bail!(reason);
            }
            Ok(Self {
                inner: if crate::session::is_wayland() {
                    LinuxWatcher::InputMethod(input_method::Watcher::start(policy, handler)?)
                } else {
                    LinuxWatcher::Accessibility(atspi::Watcher::start(policy, handler)?)
                },
            })
        }
        #[cfg(windows)]
        {
            Ok(Self {
                inner: uia::Watcher::start(policy, handler)?,
            })
        }
        #[cfg(not(any(windows, target_os = "linux")))]
        {
            let _ = (policy, handler);
            anyhow::bail!("Autocomplete is not available on this system.")
        }
    }

    pub fn set_policy(&self, policy: ReadPolicy) {
        #[cfg(target_os = "linux")]
        match &self.inner {
            LinuxWatcher::Accessibility(watcher) => watcher.set_policy(policy),
            LinuxWatcher::InputMethod(watcher) => watcher.handle().set_policy(policy),
        }
        #[cfg(windows)]
        self.inner.set_policy(policy);
        #[cfg(not(any(windows, target_os = "linux")))]
        let _ = policy;
    }

    pub fn refresh_now(&self) {
        #[cfg(target_os = "linux")]
        match &self.inner {
            LinuxWatcher::Accessibility(watcher) => watcher.refresh_now(),
            LinuxWatcher::InputMethod(watcher) => watcher.handle().refresh_now(),
        }
        #[cfg(windows)]
        self.inner.refresh_now();
    }

    pub fn limitation(&self) -> Option<String> {
        #[cfg(target_os = "linux")]
        {
            match &self.inner {
                LinuxWatcher::Accessibility(watcher) => watcher.limitation(),
                LinuxWatcher::InputMethod(watcher) => watcher.handle().limitation(),
            }
        }
        #[cfg(windows)]
        {
            self.inner.limitation()
        }
        #[cfg(not(any(windows, target_os = "linux")))]
        {
            None
        }
    }

    pub fn inline_ghost(&self) -> Option<InlineGhost> {
        #[cfg(target_os = "linux")]
        {
            match &self.inner {
                LinuxWatcher::Accessibility(_) => None,
                LinuxWatcher::InputMethod(watcher) => Some(InlineGhost {
                    inner: watcher.handle(),
                }),
            }
        }
        #[cfg(not(target_os = "linux"))]
        {
            None
        }
    }
}

#[derive(Clone)]
pub struct InlineGhost {
    #[cfg(target_os = "linux")]
    inner: input_method::Handle,
}

impl InlineGhost {
    pub fn show(&self, field: &FieldSnapshot, text: &str) {
        #[cfg(target_os = "linux")]
        self.inner.show(field, text);
        #[cfg(not(target_os = "linux"))]
        let _ = (field, text);
    }

    pub fn accept(
        &self,
        field: &FieldSnapshot,
        before: &str,
        after: &str,
        edit: &Edit,
        next: &str,
    ) {
        #[cfg(target_os = "linux")]
        self.inner.accept(field, before, after, edit, next);
        #[cfg(not(target_os = "linux"))]
        let _ = (field, before, after, edit, next);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InterceptedKey {
    Tab,
    Escape,
    RightArrow,
    Backtick,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AcceptKeys {
    pub accept: InterceptedKey,
    pub full: Option<InterceptedKey>,
}

impl Default for AcceptKeys {
    fn default() -> Self {
        Self {
            accept: InterceptedKey::Tab,
            full: Some(InterceptedKey::Backtick),
        }
    }
}

impl AcceptKeys {
    pub fn from_settings(settings: &lokalbot_core::Settings) -> Self {
        use lokalbot_core::settings::{CotypingAcceptKey, CotypingFullAcceptKey};
        let accept = match settings.cotyping_accept_key {
            CotypingAcceptKey::Tab => InterceptedKey::Tab,
            CotypingAcceptKey::RightArrow => InterceptedKey::RightArrow,
        };
        let full = match settings.cotyping_full_accept_key {
            CotypingFullAcceptKey::Backtick => Some(InterceptedKey::Backtick),
            CotypingFullAcceptKey::RightArrow => Some(InterceptedKey::RightArrow),
            CotypingFullAcceptKey::Off => None,
        };
        Self {
            accept,
            full: full.filter(|key| *key != accept),
        }
    }

    pub fn taken(&self) -> Vec<InterceptedKey> {
        let mut keys = vec![self.accept, InterceptedKey::Escape];
        keys.extend(self.full);
        keys
    }

    pub fn takes(&self, key: InterceptedKey) -> bool {
        key == self.accept || key == InterceptedKey::Escape || self.full == Some(key)
    }

    pub fn is_full(&self, key: InterceptedKey) -> Option<bool> {
        if key == self.accept {
            Some(false)
        } else if self.full == Some(key) {
            Some(true)
        } else {
            None
        }
    }
}

pub struct KeyInterceptor {
    #[cfg(target_os = "linux")]
    inner: LinuxKeys,
    #[cfg(windows)]
    inner: win32::Hook,
}

#[cfg(target_os = "linux")]
enum LinuxKeys {
    X11(x11::Grabber),
    InputMethod(input_method::Handle),
}

impl KeyInterceptor {
    pub fn start(handler: impl Fn(InterceptedKey) + Send + Sync + 'static) -> anyhow::Result<Self> {
        let handler: KeyHandler = Arc::new(handler);
        #[cfg(target_os = "linux")]
        {
            if let Support::Unavailable(reason) = support() {
                anyhow::bail!(reason);
            }
            Ok(Self {
                inner: if crate::session::is_wayland() {
                    LinuxKeys::InputMethod(input_method::attach_keys(handler)?)
                } else {
                    LinuxKeys::X11(x11::Grabber::start(handler)?)
                },
            })
        }
        #[cfg(windows)]
        {
            Ok(Self {
                inner: win32::Hook::start(handler)?,
            })
        }
        #[cfg(not(any(windows, target_os = "linux")))]
        {
            let _ = handler;
            anyhow::bail!("Autocomplete is not available on this system.")
        }
    }

    pub fn set_keys(&self, keys: AcceptKeys) {
        #[cfg(target_os = "linux")]
        match &self.inner {
            LinuxKeys::X11(grabber) => grabber.set_keys(keys),
            LinuxKeys::InputMethod(handle) => handle.set_keys(keys),
        }
        #[cfg(windows)]
        self.inner.set_keys(keys);
        #[cfg(not(any(windows, target_os = "linux")))]
        let _ = keys;
    }

    pub fn set_active(&self, active: bool) {
        #[cfg(target_os = "linux")]
        match &self.inner {
            LinuxKeys::X11(grabber) => grabber.set_active(active),
            LinuxKeys::InputMethod(handle) => handle.set_active(active),
        }
        #[cfg(windows)]
        self.inner.set_active(active);
        #[cfg(not(any(windows, target_os = "linux")))]
        let _ = active;
    }

    pub fn pass_through(&self, key: InterceptedKey) {
        #[cfg(target_os = "linux")]
        match &self.inner {
            LinuxKeys::X11(grabber) => grabber.pass_through(key),
            LinuxKeys::InputMethod(handle) => handle.pass_through(key),
        }
        #[cfg(windows)]
        self.inner.pass_through(key);
        #[cfg(not(any(windows, target_os = "linux")))]
        let _ = key;
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Edit {
    pub text: String,
    pub backward: usize,
    pub forward: usize,
}

pub fn insert(field: &FieldSnapshot, edit: &Edit) -> anyhow::Result<()> {
    let text = edit.text.replace('\r', "");
    if text.is_empty() && edit.backward == 0 && edit.forward == 0 {
        return Ok(());
    }
    anyhow::ensure!(
        edit.backward <= 64 && edit.forward <= 64,
        "an accept never deletes more than 64 characters"
    );
    let edit = Edit {
        text,
        backward: edit.backward,
        forward: edit.forward,
    };
    #[cfg(target_os = "linux")]
    {
        if field.target.input_method {
            input_method::insert(field, &edit)
        } else {
            atspi::insert(field, &edit)
        }
    }
    #[cfg(windows)]
    {
        win32::insert(field, &edit)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = (field, edit);
        anyhow::bail!("Typing into other apps is not available on this system.")
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NativeWindow {
    X11(u32),
    Win32(isize),
}

pub fn prepare_overlay(window: NativeWindow, exclude_from_capture: bool) -> anyhow::Result<()> {
    match window {
        #[cfg(target_os = "linux")]
        NativeWindow::X11(id) => {
            let _ = exclude_from_capture;
            x11::prepare_overlay(id)
        }
        #[cfg(windows)]
        NativeWindow::Win32(hwnd) => win32::prepare_overlay(hwnd, exclude_from_capture),
        _ => {
            let _ = exclude_from_capture;
            Ok(())
        }
    }
}

pub fn place_overlay(window: NativeWindow, frame: Option<Rect>) -> anyhow::Result<()> {
    match window {
        #[cfg(target_os = "linux")]
        NativeWindow::X11(id) => x11::place_overlay(id, frame),
        #[cfg(windows)]
        NativeWindow::Win32(hwnd) => win32::place_overlay(hwnd, frame),
        _ => {
            let _ = frame;
            Ok(())
        }
    }
}

pub fn scale_at(rect: &Rect) -> Option<f32> {
    #[cfg(windows)]
    {
        win32::scale_at(rect)
    }
    #[cfg(not(windows))]
    {
        let _ = rect;
        None
    }
}

pub fn screen_containing(rect: &Rect) -> Option<Rect> {
    #[cfg(target_os = "linux")]
    {
        x11::screen_containing(rect)
    }
    #[cfg(windows)]
    {
        win32::screen_containing(rect)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = rect;
        None
    }
}

pub fn sample_luminance(rect: &Rect) -> Option<f32> {
    #[cfg(target_os = "linux")]
    {
        x11::sample_luminance(rect)
    }
    #[cfg(windows)]
    {
        win32::sample_luminance(rect)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = rect;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_primary_key_wins_and_settings_map_to_keys() {
        use lokalbot_core::Settings;
        use lokalbot_core::settings::{CotypingAcceptKey, CotypingFullAcceptKey};
        let defaults = AcceptKeys::from_settings(&Settings::default());
        assert_eq!(defaults, AcceptKeys::default());
        assert_eq!(defaults.is_full(InterceptedKey::Tab), Some(false));
        assert_eq!(defaults.is_full(InterceptedKey::Backtick), Some(true));
        assert_eq!(defaults.is_full(InterceptedKey::RightArrow), None);
        assert!(defaults.takes(InterceptedKey::Escape));
        assert!(!defaults.takes(InterceptedKey::RightArrow));
        let same = AcceptKeys::from_settings(&Settings {
            cotyping_accept_key: CotypingAcceptKey::RightArrow,
            cotyping_full_accept_key: CotypingFullAcceptKey::RightArrow,
            ..Settings::default()
        });
        assert_eq!(same.is_full(InterceptedKey::RightArrow), Some(false));
        assert_eq!(same.full, None);
        let off = AcceptKeys::from_settings(&Settings {
            cotyping_full_accept_key: CotypingFullAcceptKey::Off,
            ..Settings::default()
        });
        assert_eq!(off.taken(), [InterceptedKey::Tab, InterceptedKey::Escape]);
    }
}
