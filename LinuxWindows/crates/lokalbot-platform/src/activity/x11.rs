//! X11 through EWMH: `_NET_ACTIVE_WINDOW`, `_NET_WM_NAME`/`WM_NAME`,
//! `WM_CLASS` and `_NET_WM_PID` (or the X-Resource extension), and idle time
//! from MIT-SCREEN-SAVER.

use anyhow::Context as _;
use x11rb::connection::{Connection, RequestConnection as _};
use x11rb::errors::{ConnectionError, ReplyError};
use x11rb::protocol::res::{self, ClientIdMask, ClientIdSpec, ConnectionExt as _};
use x11rb::protocol::screensaver::{self, ConnectionExt as _};
use x11rb::protocol::xproto::{Atom, AtomEnum, ConnectionExt as _, GetPropertyReply, Window};
use x11rb::rust_connection::RustConnection;

use super::linux::{FocusedWindow, IdleProbe, WindowProbe};

/// Longest property read, in 32-bit units (titles are cut at 8 KiB).
const MAX_PROPERTY_WORDS: u32 = 2048;

struct Atoms {
    net_active_window: Atom,
    net_client_list: Atom,
    net_wm_name: Atom,
    net_wm_pid: Atom,
    utf8_string: Atom,
}

struct Session {
    conn: RustConnection,
    root: Window,
    atoms: Atoms,
    has_res: bool,
}

fn intern(conn: &RustConnection, name: &[u8]) -> anyhow::Result<Atom> {
    Ok(conn.intern_atom(false, name)?.reply()?.atom)
}

impl Session {
    fn open() -> anyhow::Result<Self> {
        let (conn, screen) = x11rb::connect(None).context("could not connect to the X server")?;
        let root = conn
            .setup()
            .roots
            .get(screen)
            .context("the X server reported no screen")?
            .root;
        let atoms = Atoms {
            net_active_window: intern(&conn, b"_NET_ACTIVE_WINDOW")?,
            net_client_list: intern(&conn, b"_NET_CLIENT_LIST")?,
            net_wm_name: intern(&conn, b"_NET_WM_NAME")?,
            net_wm_pid: intern(&conn, b"_NET_WM_PID")?,
            utf8_string: intern(&conn, b"UTF8_STRING")?,
        };
        let has_res = conn
            .extension_information(res::X11_EXTENSION_NAME)?
            .is_some();
        Ok(Self {
            conn,
            root,
            atoms,
            has_res,
        })
    }

    /// A property, or `None` when it is missing or the window has gone.
    fn property(
        &self,
        window: Window,
        property: impl Into<Atom>,
        kind: impl Into<Atom>,
    ) -> Result<Option<GetPropertyReply>, ConnectionError> {
        let cookie =
            self.conn
                .get_property(false, window, property, kind, 0, MAX_PROPERTY_WORDS)?;
        match cookie.reply() {
            Ok(reply) if reply.type_ != x11rb::NONE => Ok(Some(reply)),
            Ok(_) | Err(ReplyError::X11Error(_)) => Ok(None),
            Err(ReplyError::ConnectionError(err)) => Err(err),
        }
    }

    fn active_window(&self) -> Result<Option<Window>, ConnectionError> {
        Ok(self
            .property(self.root, self.atoms.net_active_window, AtomEnum::WINDOW)?
            .and_then(|reply| reply.value32().and_then(|mut values| values.next()))
            .filter(|window| *window != x11rb::NONE))
    }

    fn title(&self, window: Window) -> Result<String, ConnectionError> {
        if let Some(reply) =
            self.property(window, self.atoms.net_wm_name, self.atoms.utf8_string)?
            && !reply.value.is_empty()
        {
            return Ok(String::from_utf8_lossy(&reply.value).into_owned());
        }
        Ok(self
            .property(window, AtomEnum::WM_NAME, AtomEnum::ANY)?
            .map(|reply| {
                if reply.type_ == self.atoms.utf8_string {
                    String::from_utf8_lossy(&reply.value).into_owned()
                } else {
                    // STRING is Latin-1; COMPOUND_TEXT is Latin-1 with escapes.
                    decode_compound_text(&reply.value)
                }
            })
            .unwrap_or_default())
    }

    fn class(&self, window: Window) -> Result<(Option<String>, Option<String>), ConnectionError> {
        let Some(reply) = self.property(window, AtomEnum::WM_CLASS, AtomEnum::STRING)? else {
            return Ok((None, None));
        };
        let mut parts = reply
            .value
            .split(|&b| b == 0)
            .map(|part| String::from_utf8_lossy(part).into_owned());
        let instance = parts.next().filter(|s| !s.is_empty());
        let class = parts.next().filter(|s| !s.is_empty());
        Ok((instance, class))
    }

    fn pid(&self, window: Window) -> Result<Option<u32>, ConnectionError> {
        let from_property = self
            .property(window, self.atoms.net_wm_pid, AtomEnum::CARDINAL)?
            .and_then(|reply| reply.value32().and_then(|mut values| values.next()))
            .filter(|pid| *pid != 0);
        if from_property.is_some() || !self.has_res {
            return Ok(from_property);
        }
        // Apps that do not set _NET_WM_PID: ask the server who owns the window.
        let spec = ClientIdSpec {
            client: window,
            mask: ClientIdMask::LOCAL_CLIENT_PID,
        };
        match self.conn.res_query_client_ids(&[spec])?.reply() {
            Ok(reply) => Ok(reply
                .ids
                .iter()
                .find(|id| id.spec.mask.contains(ClientIdMask::LOCAL_CLIENT_PID))
                .and_then(|id| id.value.first().copied())),
            Err(ReplyError::X11Error(_)) => Ok(None),
            Err(ReplyError::ConnectionError(err)) => Err(err),
        }
    }

    fn focused(&self) -> Result<Option<FocusedWindow>, ConnectionError> {
        let Some(window) = self.active_window()? else {
            return Ok(None);
        };
        let title = self.title(window)?;
        let (instance, class) = self.class(window)?;
        let pid = self.pid(window)?;
        if title.is_empty() && class.is_none() && pid.is_none() {
            return Ok(None);
        }
        Ok(Some(FocusedWindow {
            title,
            pid,
            class,
            instance,
            desktop_file: None,
        }))
    }

    /// Class (or instance) and title of every managed window.
    fn client_titles(&self) -> Result<Vec<(String, String)>, ConnectionError> {
        let windows: Vec<Window> = self
            .property(self.root, self.atoms.net_client_list, AtomEnum::WINDOW)?
            .and_then(|reply| reply.value32().map(|values| values.collect()))
            .unwrap_or_default();
        let mut titles = Vec::with_capacity(windows.len());
        for window in windows {
            let title = self.title(window)?;
            if title.is_empty() {
                continue;
            }
            let (instance, class) = self.class(window)?;
            if let Some(app) = class.or(instance) {
                titles.push((app, title));
            }
        }
        Ok(titles)
    }

    fn idle_ms(&self) -> anyhow::Result<u32> {
        Ok(self
            .conn
            .screensaver_query_info(self.root)?
            .reply()?
            .ms_since_user_input)
    }
}

/// Decodes ICCCM `COMPOUND_TEXT` (and plain `STRING`): Latin-1 by default,
/// with UTF-8 segments between `ESC % G` and `ESC % @`, as Xlib writes them.
/// Other character sets become U+FFFD.
fn decode_compound_text(bytes: &[u8]) -> String {
    const ESC: u8 = 0x1b;
    let mut out = String::with_capacity(bytes.len());
    let mut utf8: Vec<u8> = Vec::new();
    let mut in_utf8 = false;
    let mut foreign = false;
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == ESC {
            // ESC, intermediate bytes 0x20–0x2F, one final byte 0x30–0x7E.
            let mut end = i + 1;
            while end < bytes.len() && (0x20..=0x2f).contains(&bytes[end]) {
                end += 1;
            }
            let sequence = &bytes[i + 1..(end + 1).min(bytes.len())];
            if in_utf8 {
                out.push_str(&String::from_utf8_lossy(&utf8));
                utf8.clear();
            }
            in_utf8 = sequence == b"%G";
            // ASCII or Latin-1 designations keep the default decoding.
            foreign = !(in_utf8 || sequence == b"%@" || sequence == b"(B" || sequence == b"-A");
            i = end + 1;
            continue;
        }
        let byte = bytes[i];
        if in_utf8 {
            utf8.push(byte);
        } else if foreign && byte >= 0x80 {
            out.push(char::REPLACEMENT_CHARACTER);
        } else {
            out.push(char::from(byte));
        }
        i += 1;
    }
    if in_utf8 {
        out.push_str(&String::from_utf8_lossy(&utf8));
    }
    out
}

/// Reconnects after the X server goes away (for example a restarted session).
pub(super) struct X11Probe {
    session: Option<Session>,
}

impl X11Probe {
    pub(super) fn connect() -> anyhow::Result<Self> {
        Ok(Self {
            session: Some(Session::open()?),
        })
    }
}

impl WindowProbe for X11Probe {
    fn focused(&mut self) -> anyhow::Result<Option<FocusedWindow>> {
        if self.session.is_none() {
            self.session = Some(Session::open()?);
        }
        let Some(session) = &self.session else {
            return Ok(None);
        };
        match session.focused() {
            Ok(window) => Ok(window),
            Err(err) => {
                self.session = None;
                Err(anyhow::Error::new(err).context("lost the X server connection"))
            }
        }
    }

    fn name(&self) -> &'static str {
        "x11"
    }
}

/// Every window's title, for meeting detection.
pub(super) struct ClientList {
    session: Option<Session>,
}

impl ClientList {
    pub(super) fn new() -> Self {
        Self { session: None }
    }

    pub(super) fn list(&mut self) -> Vec<(String, String)> {
        if self.session.is_none() {
            self.session = Session::open().ok();
        }
        let Some(session) = &self.session else {
            return Vec::new();
        };
        match session.client_titles() {
            Ok(titles) => titles,
            Err(err) => {
                log::debug!("x11 client list: {err}");
                self.session = None;
                Vec::new()
            }
        }
    }
}

pub(super) struct X11Idle {
    session: Option<Session>,
}

impl X11Idle {
    pub(super) fn connect() -> anyhow::Result<Self> {
        let session = Session::open()?;
        if session
            .conn
            .extension_information(screensaver::X11_EXTENSION_NAME)?
            .is_none()
        {
            anyhow::bail!("the X server has no MIT-SCREEN-SAVER extension");
        }
        Ok(Self {
            session: Some(session),
        })
    }
}

impl IdleProbe for X11Idle {
    fn idle_seconds(&mut self) -> Option<f64> {
        if self.session.is_none() {
            self.session = Session::open().ok();
        }
        match self.session.as_ref()?.idle_ms() {
            Ok(ms) => Some(f64::from(ms) / 1000.0),
            Err(err) => {
                log::debug!("x11 idle: {err:#}");
                self.session = None;
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compound_text_titles() {
        assert_eq!(
            decode_compound_text(b"Quarterly plan \x1b%G\xe2\x80\x94\x1b%@ token"),
            "Quarterly plan \u{2014} token"
        );
        assert_eq!(decode_compound_text(b"caf\xe9"), "caf\u{e9}");
        assert_eq!(
            decode_compound_text(b"\x1b-Ar\xe9sum\xe9"),
            "r\u{e9}sum\u{e9}"
        );
        assert_eq!(decode_compound_text(b"\x1b$(B\xb0\xa1"), "\u{fffd}\u{fffd}");
        assert_eq!(
            decode_compound_text(b"\x1b%Gunterminated \xc3\xa9"),
            "unterminated \u{e9}"
        );
    }
}
