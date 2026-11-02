//! Reading the clipboard for autocomplete's prompt
//! (`CotypingClipboardProvider`). Markers for concealed copies are checked
//! before asking the clipboard's owner for any text, and a change while
//! reading drops the whole read. The text is held only until the next copy,
//! never written anywhere. On Wayland nothing is read: only LokalBot's own
//! practice editor runs there, and it uses no clipboard context.

/// One clipboard state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClipboardRead {
    /// Moves when the clipboard's contents change.
    pub change_count: u64,
    pub text: String,
}

/// `org.nspasteboard`'s types as the Mac checks them, plus what password
/// managers set on these platforms (X11's KDE hint, Windows' monitor and
/// history opt-outs). Compared lowercased.
const SENSITIVE_TYPES: [&str; 9] = [
    "org.nspasteboard.concealedtype",
    "org.nspasteboard.transienttype",
    "de.petermaurer.transientpasteboardtype",
    "com.agilebits.onepassword",
    "x-kde-passwordmanagerhint",
    "excludeclipboardcontentfrommonitorprocessing",
    "canincludeinclipboardhistory",
    "canuploadtocloudclipboard",
    "clipboard viewer ignore",
];

/// Whether a list of clipboard types holds text and nothing concealed.
#[cfg(any(target_os = "linux", test))]
fn allows<'a>(types: impl IntoIterator<Item = &'a str>, is_text: impl Fn(&str) -> bool) -> bool {
    let mut has_text = false;
    for name in types {
        if SENSITIVE_TYPES.contains(&name.to_lowercase().as_str()) {
            return false;
        }
        has_text |= is_text(name);
    }
    has_text
}

/// Reads the clipboard, keeping the last read until its change count moves,
/// so a read is rare however fast the typing.
#[derive(Default)]
pub struct ClipboardReader {
    backend: Option<backend::Backend>,
    /// The last change count looked at and what it held.
    last: Option<(u64, Option<String>)>,
    started: bool,
}

impl ClipboardReader {
    pub fn new() -> Self {
        Self::default()
    }

    /// The current clipboard, or `None` when it holds nothing readable or
    /// something concealed, or when this desktop has no way to read it.
    pub fn read(&mut self) -> Option<ClipboardRead> {
        if !self.started {
            self.started = true;
            self.backend = backend::Backend::connect();
        }
        let backend = self.backend.as_mut()?;
        let count = backend.change_count();
        if self.last.as_ref().is_none_or(|(seen, _)| *seen != count) {
            let text = backend.snapshot(count);
            self.last = Some((count, text));
        }
        let (change_count, text) = self.last.as_ref()?;
        Some(ClipboardRead {
            change_count: *change_count,
            text: text.clone()?,
        })
    }

    /// Lets go of the text and the connection.
    pub fn forget(&mut self) {
        *self = Self::default();
    }
}

#[cfg(target_os = "linux")]
mod backend {
    use std::time::{Duration, Instant};

    use x11rb::connection::Connection as _;
    use x11rb::protocol::Event;
    use x11rb::protocol::xfixes::{ConnectionExt as _, SelectionEventMask};
    use x11rb::protocol::xproto::{
        Atom, AtomEnum, ConnectionExt as _, CreateWindowAux, EventMask, WindowClass,
    };
    use x11rb::rust_connection::RustConnection;

    use super::allows;

    /// A clipboard owner that takes longer than this is not waited for: this
    /// runs on the autocomplete worker.
    const OWNER_TIMEOUT: Duration = Duration::from_millis(150);
    const MAX_TARGETS: usize = 64;
    /// Larger text arrives in increments, which is not worth following here.
    const MAX_TEXT_WORDS: u32 = 256 * 1024;

    pub(super) struct Backend {
        conn: RustConnection,
        window: u32,
        clipboard: Atom,
        targets: Atom,
        utf8_string: Atom,
        property: Atom,
        incr: Atom,
        count: u64,
    }

    impl Backend {
        pub(super) fn connect() -> Option<Self> {
            if crate::session::desktop() != crate::session::Desktop::X11 {
                return None;
            }
            let (conn, screen) = x11rb::connect(None).ok()?;
            let root = conn.setup().roots.get(screen)?.root;
            let intern = |name: &[u8]| -> Option<Atom> {
                Some(conn.intern_atom(false, name).ok()?.reply().ok()?.atom)
            };
            let clipboard = intern(b"CLIPBOARD")?;
            let targets = intern(b"TARGETS")?;
            let utf8_string = intern(b"UTF8_STRING")?;
            let property = intern(b"LOKALBOT_AUTOCOMPLETE_CLIPBOARD")?;
            let incr = intern(b"INCR")?;
            conn.xfixes_query_version(5, 0).ok()?.reply().ok()?;
            conn.xfixes_select_selection_input(
                root,
                clipboard,
                SelectionEventMask::SET_SELECTION_OWNER,
            )
            .ok()?;
            let window = conn.generate_id().ok()?;
            conn.create_window(
                0,
                window,
                root,
                -10,
                -10,
                1,
                1,
                0,
                WindowClass::INPUT_ONLY,
                x11rb::COPY_FROM_PARENT,
                &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE),
            )
            .ok()?
            .check()
            .ok()?;
            conn.flush().ok()?;
            Some(Self {
                conn,
                window,
                clipboard,
                targets,
                utf8_string,
                property,
                incr,
                count: 1,
            })
        }

        pub(super) fn change_count(&mut self) -> u64 {
            while let Ok(Some(event)) = self.conn.poll_for_event() {
                if matches!(event, Event::XfixesSelectionNotify(_)) {
                    self.count += 1;
                }
            }
            self.count
        }

        /// Asks the owner to convert the clipboard to `target` and reads the
        /// result. `None` when there is no answer in time.
        fn convert(&mut self, target: Atom) -> Option<(Atom, Vec<u8>, u32)> {
            self.conn
                .convert_selection(
                    self.window,
                    self.clipboard,
                    target,
                    self.property,
                    x11rb::CURRENT_TIME,
                )
                .ok()?;
            self.conn.flush().ok()?;
            let deadline = Instant::now() + OWNER_TIMEOUT;
            loop {
                match self.conn.poll_for_event().ok()? {
                    Some(Event::SelectionNotify(notify))
                        if notify.requestor == self.window && notify.target == target =>
                    {
                        if notify.property == u32::from(AtomEnum::NONE) {
                            return None;
                        }
                        let reply = self
                            .conn
                            .get_property(
                                true,
                                self.window,
                                self.property,
                                AtomEnum::ANY,
                                0,
                                MAX_TEXT_WORDS,
                            )
                            .ok()?
                            .reply()
                            .ok()?;
                        let _ = self.conn.flush();
                        return Some((reply.type_, reply.value, reply.bytes_after));
                    }
                    Some(Event::XfixesSelectionNotify(_)) => self.count += 1,
                    Some(_) => {}
                    None => {
                        if Instant::now() >= deadline {
                            return None;
                        }
                        std::thread::sleep(Duration::from_millis(2));
                    }
                }
            }
        }

        fn types(&mut self) -> Option<Vec<String>> {
            let (_, value, _) = self.convert(self.targets)?;
            let atoms: Vec<Atom> = value
                .as_chunks::<4>()
                .0
                .iter()
                .take(MAX_TARGETS)
                .map(|bytes| u32::from_ne_bytes(*bytes))
                .collect();
            let mut names = Vec::with_capacity(atoms.len());
            for atom in atoms {
                let name = self.conn.get_atom_name(atom).ok()?.reply().ok()?;
                names.push(String::from_utf8_lossy(&name.name).into_owned());
            }
            Some(names)
        }

        /// `CotypingClipboardProvider.snapshot`: types, text, then the types
        /// again, with the change count unmoved throughout.
        pub(super) fn snapshot(&mut self, count: u64) -> Option<String> {
            let is_text = |name: &str| name == "UTF8_STRING";
            let types = self.types()?;
            if !allows(types.iter().map(String::as_str), is_text) || self.change_count() != count {
                return None;
            }
            let (kind, bytes, more) = self.convert(self.utf8_string)?;
            if kind == self.incr || more > 0 {
                return None;
            }
            let text = String::from_utf8(bytes).ok()?;
            let again = self.types()?;
            let same = {
                let mut a = types.clone();
                let mut b = again.clone();
                a.sort();
                b.sort();
                a == b
            };
            if !same
                || !allows(again.iter().map(String::as_str), is_text)
                || self.change_count() != count
            {
                return None;
            }
            Some(text)
        }
    }

    impl Drop for Backend {
        fn drop(&mut self) {
            let _ = self.conn.destroy_window(self.window);
            let _ = self.conn.flush();
        }
    }
}

#[cfg(windows)]
mod backend {
    use windows::Win32::System::DataExchange::{
        GetClipboardSequenceNumber, IsClipboardFormatAvailable, RegisterClipboardFormatW,
    };
    use windows::core::HSTRING;

    use super::SENSITIVE_TYPES;

    /// `CF_UNICODETEXT`.
    const UNICODE_TEXT: u32 = 13;
    /// Their registered names, as password managers and Windows spell them.
    const SENSITIVE_FORMATS: [&str; 4] = [
        "ExcludeClipboardContentFromMonitorProcessing",
        "CanIncludeInClipboardHistory",
        "CanUploadToCloudClipboard",
        "Clipboard Viewer Ignore",
    ];

    pub(super) struct Backend;

    fn holds_text_and_nothing_concealed() -> bool {
        // SAFETY: no pointers beyond the strings that outlive each call; these
        // calls do not open the clipboard, so its owner is not asked for text.
        unsafe {
            let concealed = SENSITIVE_FORMATS
                .iter()
                .chain(SENSITIVE_TYPES.iter().take(4))
                .any(|name| {
                    let format = RegisterClipboardFormatW(&HSTRING::from(*name));
                    format != 0 && IsClipboardFormatAvailable(format).is_ok()
                });
            !concealed && IsClipboardFormatAvailable(UNICODE_TEXT).is_ok()
        }
    }

    impl Backend {
        pub(super) fn connect() -> Option<Self> {
            Some(Self)
        }

        pub(super) fn change_count(&mut self) -> u64 {
            // SAFETY: no arguments; returns 0 without clipboard access.
            u64::from(unsafe { GetClipboardSequenceNumber() })
        }

        pub(super) fn snapshot(&mut self, count: u64) -> Option<String> {
            if count == 0 || !holds_text_and_nothing_concealed() || self.change_count() != count {
                return None;
            }
            let text = arboard::Clipboard::new().ok()?.get_text().ok()?;
            if !holds_text_and_nothing_concealed() || self.change_count() != count {
                return None;
            }
            Some(text)
        }
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod backend {
    pub(super) struct Backend;

    impl Backend {
        pub(super) fn connect() -> Option<Self> {
            None
        }

        pub(super) fn change_count(&mut self) -> u64 {
            0
        }

        pub(super) fn snapshot(&mut self, _: u64) -> Option<String> {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn concealed_copies_are_refused_before_any_text_is_asked_for() {
        let text = |name: &str| name == "UTF8_STRING";
        assert!(allows(["TARGETS", "UTF8_STRING"], text));
        assert!(!allows(["TARGETS"], text));
        assert!(!allows(["UTF8_STRING", "x-kde-passwordManagerHint"], text));
        assert!(!allows(
            ["UTF8_STRING", "org.nspasteboard.ConcealedType"],
            text
        ));
        assert!(!allows(["Clipboard Viewer Ignore", "UTF8_STRING"], text));
    }

    /// Reads a real selection owner: runs only with an X display, such as
    /// under `xvfb-run`.
    #[cfg(target_os = "linux")]
    #[test]
    fn reads_an_x11_owner_and_refuses_a_password_manager() {
        use x11rb::connection::Connection as _;
        use x11rb::protocol::Event;
        use x11rb::protocol::xproto::{
            AtomEnum, ConnectionExt as _, CreateWindowAux, EventMask, PropMode,
            SELECTION_NOTIFY_EVENT, SelectionNotifyEvent, WindowClass,
        };
        use x11rb::wrapper::ConnectionExt as _;

        if crate::session::desktop() != crate::session::Desktop::X11 {
            return;
        }
        let Ok((conn, screen)) = x11rb::connect(None) else {
            return;
        };
        let root = conn.setup().roots[screen].root;
        let intern = |name: &[u8]| conn.intern_atom(false, name).unwrap().reply().unwrap().atom;
        let clipboard = intern(b"CLIPBOARD");
        let targets = intern(b"TARGETS");
        let utf8 = intern(b"UTF8_STRING");
        let hint = intern(b"x-kde-passwordManagerHint");
        let window = conn.generate_id().unwrap();
        conn.create_window(
            0,
            window,
            root,
            0,
            0,
            1,
            1,
            0,
            WindowClass::INPUT_ONLY,
            x11rb::COPY_FROM_PARENT,
            &CreateWindowAux::new().event_mask(EventMask::NO_EVENT),
        )
        .unwrap();
        conn.set_selection_owner(window, clipboard, x11rb::CURRENT_TIME)
            .unwrap();
        conn.flush().unwrap();
        let concealed = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = concealed.clone();
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stopping = stop.clone();
        let owner = std::thread::spawn(move || {
            while !stopping.load(std::sync::atomic::Ordering::Relaxed) {
                let event = conn.poll_for_event().unwrap();
                let Some(Event::SelectionRequest(request)) = event else {
                    std::thread::sleep(std::time::Duration::from_millis(2));
                    continue;
                };
                if request.target == targets {
                    let mut offered = vec![targets, utf8];
                    if flag.load(std::sync::atomic::Ordering::Relaxed) {
                        offered.push(hint);
                    }
                    conn.change_property32(
                        PropMode::REPLACE,
                        request.requestor,
                        request.property,
                        AtomEnum::ATOM,
                        &offered,
                    )
                    .unwrap();
                } else {
                    conn.change_property8(
                        PropMode::REPLACE,
                        request.requestor,
                        request.property,
                        utf8,
                        "the cutover plan".as_bytes(),
                    )
                    .unwrap();
                }
                let notify = SelectionNotifyEvent {
                    response_type: SELECTION_NOTIFY_EVENT,
                    sequence: 0,
                    time: request.time,
                    requestor: request.requestor,
                    selection: request.selection,
                    target: request.target,
                    property: request.property,
                };
                conn.send_event(false, request.requestor, EventMask::NO_EVENT, notify)
                    .unwrap();
                conn.flush().unwrap();
            }
        });
        let mut reader = ClipboardReader::new();
        let first = reader.read().expect("the owner answers");
        assert_eq!(first.text, "the cutover plan");
        // The same state is answered without asking the owner again.
        assert_eq!(reader.read(), Some(first));
        concealed.store(true, std::sync::atomic::Ordering::Relaxed);
        let mut fresh = ClipboardReader::new();
        assert_eq!(fresh.read(), None);
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        owner.join().unwrap();
    }
}
