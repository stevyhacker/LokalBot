//! Interaction boundaries as capture hints (`ScreenContextEventMonitor`).
//!
//! The Mac app watches clicks, key presses and scrolls through a global
//! event monitor and reports when they settle. Here the idle timer stands in
//! for all three: input that stops for a moment is one "typing pause"
//! boundary. A clipboard change is noticed from its sequence number (Windows)
//! or a selection-owner event (X11). No key, pointer position, event type or
//! clipboard content is ever read.

/// A settled interaction worth a capture.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Interaction {
    /// Keyboard or pointer input stopped for a moment.
    TypingPause,
    /// Something new was copied.
    ClipboardChange,
}

/// Input this recent counts as ongoing.
const ACTIVE_SECONDS: f64 = 1.0;
/// Input settled once it has been idle this long (the Mac waits 0.8 s after
/// the last key).
const SETTLED_SECONDS: f64 = 0.8;

/// Polled about once a second by the capture worker.
pub struct InteractionMonitor {
    active: bool,
    clipboard: Option<ClipboardWatch>,
}

impl Default for InteractionMonitor {
    fn default() -> Self {
        Self::new()
    }
}

impl InteractionMonitor {
    pub fn new() -> Self {
        Self {
            active: false,
            clipboard: ClipboardWatch::new(),
        }
    }

    /// Boundaries since the last poll, given the current idle time.
    pub fn poll(&mut self, idle_seconds: Option<f64>) -> Vec<Interaction> {
        let mut found = Vec::new();
        if let Some(idle) = idle_seconds {
            if idle < ACTIVE_SECONDS {
                self.active = true;
            } else if self.active && idle >= SETTLED_SECONDS {
                self.active = false;
                found.push(Interaction::TypingPause);
            }
        }
        if self.clipboard.as_mut().is_some_and(ClipboardWatch::changed) {
            found.push(Interaction::ClipboardChange);
        }
        found
    }

    /// Whether clipboard changes can be noticed on this desktop.
    pub fn watches_clipboard(&self) -> bool {
        self.clipboard.is_some()
    }
}

#[cfg(windows)]
struct ClipboardWatch {
    sequence: u32,
}

#[cfg(windows)]
impl ClipboardWatch {
    fn new() -> Option<Self> {
        Some(Self {
            sequence: Self::current(),
        })
    }

    fn current() -> u32 {
        // SAFETY: no arguments; returns 0 when the station has no clipboard access.
        unsafe { windows::Win32::System::DataExchange::GetClipboardSequenceNumber() }
    }

    fn changed(&mut self) -> bool {
        let current = Self::current();
        let changed = current != 0 && current != self.sequence;
        self.sequence = current;
        changed
    }
}

/// X11: XFixes reports every new owner of the CLIPBOARD selection; the
/// events are drained without reading the selection itself.
#[cfg(target_os = "linux")]
struct ClipboardWatch {
    conn: x11rb::rust_connection::RustConnection,
}

#[cfg(target_os = "linux")]
impl ClipboardWatch {
    fn new() -> Option<Self> {
        use x11rb::connection::Connection as _;
        use x11rb::protocol::xfixes::{ConnectionExt as _, SelectionEventMask};
        use x11rb::protocol::xproto::ConnectionExt as _;

        if crate::session::desktop() != crate::session::Desktop::X11 {
            return None;
        }
        let (conn, screen) = x11rb::connect(None).ok()?;
        let root = conn.setup().roots.get(screen)?.root;
        conn.xfixes_query_version(5, 0).ok()?.reply().ok()?;
        let clipboard = conn
            .intern_atom(false, b"CLIPBOARD")
            .ok()?
            .reply()
            .ok()?
            .atom;
        conn.xfixes_select_selection_input(
            root,
            clipboard,
            SelectionEventMask::SET_SELECTION_OWNER,
        )
        .ok()?;
        conn.flush().ok()?;
        Some(Self { conn })
    }

    fn changed(&mut self) -> bool {
        use x11rb::connection::Connection as _;
        use x11rb::protocol::Event;

        let mut changed = false;
        while let Ok(Some(event)) = self.conn.poll_for_event() {
            if matches!(event, Event::XfixesSelectionNotify(_)) {
                changed = true;
            }
        }
        changed
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
struct ClipboardWatch;

#[cfg(not(any(windows, target_os = "linux")))]
impl ClipboardWatch {
    fn new() -> Option<Self> {
        None
    }

    fn changed(&mut self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_that_settles_is_one_boundary() {
        let mut monitor = InteractionMonitor {
            active: false,
            clipboard: None,
        };
        assert!(monitor.poll(Some(30.0)).is_empty(), "idle all along");
        assert!(monitor.poll(Some(0.2)).is_empty(), "typing");
        assert!(monitor.poll(Some(0.4)).is_empty(), "still typing");
        assert_eq!(monitor.poll(Some(1.3)), [Interaction::TypingPause]);
        assert!(monitor.poll(Some(2.3)).is_empty(), "reported once");
        assert!(monitor.poll(None).is_empty(), "idle time unknown");
    }
}
