//! Who owns the active field, asked for on a thread of its own so a slow app
//! or compositor never holds up the keyboard: the compositor names the window
//! in front, and accessibility adds what it knows about the field. Also looks
//! out for other input methods, since a desktop runs one at a time.
//!
//! The owner is judged before the field's text is used. An app that cannot be
//! named is ruled out.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, RecvTimeoutError};

use super::super::atspi::focused;
use super::super::policy::{self, ReadPolicy, reasons};
use super::{Command, Handle, Refusal, Surface};
use crate::activity::{AppResolver, FrontWindow, FrontWindows};
use crate::session::Desktop;

/// How often to look for another input method.
const SCAN_EVERY: Duration = Duration::from_secs(5);
const CALL_TIMEOUT: Duration = Duration::from_millis(500);

/// Session bus names of input methods. Their daemons own these for as long as
/// they run, and looking here stays within this desktop session.
const OTHER_INPUT_METHODS: [(&str, &str); 3] = [
    ("org.fcitx.Fcitx5", "Fcitx 5"),
    ("org.fcitx.Fcitx", "Fcitx"),
    ("org.freedesktop.portal.IBus", "IBus"),
];

pub(super) enum Request {
    Read { activation: u64, policy: ReadPolicy },
    Forget,
    Stop,
}

/// Answers questions until told to stop. With `scan`, it also keeps looking for
/// other input methods, for a route where only one can run.
pub(super) fn run(requests: Receiver<Request>, back: Handle, scan: bool) {
    let mut reader = Reader::new();
    let far_future = Duration::from_secs(60 * 60 * 24);
    let mut next_scan = if scan {
        Instant::now()
    } else {
        Instant::now() + far_future
    };
    let bus = zbus::blocking::connection::Builder::session()
        .and_then(|builder| builder.method_timeout(CALL_TIMEOUT).build())
        .ok();
    loop {
        match requests.recv_deadline(next_scan) {
            Ok(Request::Stop) | Err(RecvTimeoutError::Disconnected) => break,
            Err(RecvTimeoutError::Timeout) => {
                back.send(Command::Scanned(bus.as_ref().and_then(other_input_method)));
                next_scan = Instant::now() + if scan { SCAN_EVERY } else { far_future };
            }
            Ok(mut request) => {
                // Only the newest question matters.
                while let Ok(newer) = requests.try_recv() {
                    request = newer;
                }
                match request {
                    Request::Read { activation, policy } => {
                        back.send(Command::Surface(reader.read(activation, &policy)));
                    }
                    Request::Forget => reader.visible.clear(),
                    Request::Stop => break,
                }
            }
        }
    }
}

/// The name of an input method running in this session.
fn other_input_method(bus: &zbus::blocking::Connection) -> Option<String> {
    OTHER_INPUT_METHODS.iter().find_map(|(bus_name, name)| {
        let reply = bus
            .call_method(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                Some("org.freedesktop.DBus"),
                "NameHasOwner",
                &(*bus_name,),
            )
            .ok()?;
        reply
            .body()
            .deserialize::<bool>()
            .ok()?
            .then(|| (*name).to_string())
    })
}

struct Reader {
    front: Option<FrontWindows>,
    apps: AppResolver,
    own_pid: u32,
    /// Text above the field, read once per field and page.
    visible: HashMap<(u64, Option<String>, String), Option<String>>,
}

impl Reader {
    fn new() -> Self {
        Self {
            front: None,
            apps: AppResolver::new(),
            own_pid: std::process::id(),
            visible: HashMap::new(),
        }
    }

    fn front_window(&mut self) -> Option<FrontWindow> {
        if self.front.is_none() {
            self.front = FrontWindows::connect();
        }
        let window = self.front.as_mut().and_then(FrontWindows::read);
        if window.is_some() {
            return window;
        }
        self.front = None;
        // GNOME names the window in front only through an extension. Apps that
        // publish accessibility can still say for themselves.
        if crate::session::desktop() != Desktop::Gnome {
            return None;
        }
        let pid = super::super::focused::active_pid()?;
        let (name, id) = self.apps.resolve(pid, None, None);
        Some(FrontWindow {
            title: String::new(),
            pid: Some(pid),
            name,
            id,
        })
    }

    fn read(&mut self, activation: u64, policy: &ReadPolicy) -> Surface {
        let window = self.front_window();
        let judged = judge(
            activation,
            policy,
            self.own_pid,
            window.as_ref(),
            focused::surroundings,
        );
        let mut surface = judged.inner;
        // A later activation means this field is gone, and its text with it.
        self.visible.retain(|(seen, _, _), _| *seen == activation);
        if judged.refusal.is_none()
            && let Some(key) = judged.accessible_key
        {
            let cache = (
                activation,
                surface.url.clone(),
                surface.window_title.clone(),
            );
            surface.visible_text = self
                .visible
                .entry(cache)
                .or_insert_with(|| {
                    focused::visible_text(
                        surface.pid,
                        &key,
                        &surface.app_name,
                        &surface.app_id,
                        policy,
                    )
                })
                .clone();
        }
        surface
    }
}

/// A surface and the accessibility key its visible text can be read through.
struct Judged {
    inner: Surface,
    accessible_key: Option<String>,
    refusal: Option<Refusal>,
}

/// Decides what the owner and accessibility say about a field, in the order
/// the X11 watcher does: identity first, then the field's kind.
fn judge(
    activation: u64,
    policy: &ReadPolicy,
    own_pid: u32,
    window: Option<&FrontWindow>,
    surroundings: impl FnOnce(u32) -> Option<focused::Surroundings>,
) -> Judged {
    let refused = |inner: Surface, refusal: Refusal| Judged {
        inner: Surface {
            refusal: Some(refusal),
            ..inner
        },
        accessible_key: None,
        refusal: Some(refusal),
    };
    let unknown = Surface {
        activation,
        ..Surface::default()
    };
    let Some(window) = window else {
        return refused(unknown, Refusal::Unsupported(reasons::UNKNOWN_APP));
    };
    let Some(pid) = window.pid else {
        return refused(unknown, Refusal::Unsupported(reasons::UNKNOWN_APP));
    };
    let mut inner = Surface {
        activation,
        pid,
        app_name: window.name.clone(),
        app_id: window.id.clone(),
        window_title: window.title.clone(),
        ..Surface::default()
    };
    if pid == own_pid {
        // The practice editor feeds the engine itself.
        inner.app_name = "LokalBot".into();
        inner.app_id = crate::privacy::SELF_APP_ID.into();
        return refused(inner, Refusal::Unsupported("Off in LokalBot."));
    }
    if !policy.allows_app(&inner.app_name, &inner.app_id) {
        let reason = if policy::is_terminal_app(&inner.app_name, &inner.app_id) {
            reasons::TERMINAL
        } else {
            reasons::EXCLUDED_APP
        };
        return refused(inner, Refusal::Unsupported(reason));
    }
    let Some(found) = surroundings(pid) else {
        return Judged {
            inner,
            accessible_key: None,
            refusal: None,
        };
    };
    if found.secure {
        return refused(inner, Refusal::Blocked(reasons::SECURE));
    }
    if found.terminal {
        return refused(inner, Refusal::Unsupported(reasons::TERMINAL));
    }
    if found.search {
        return refused(inner, Refusal::Unsupported(reasons::SEARCH));
    }
    if found.file_dialog {
        return refused(inner, Refusal::Unsupported(reasons::FILE_DIALOG));
    }
    inner.single_line = Some(found.single_line);
    inner.is_integrated_terminal = found.integrated_terminal;
    inner.url = found.url;
    if !found.title.is_empty() {
        inner.window_title = found.title;
    }
    Judged {
        inner,
        accessible_key: Some(found.key),
        refusal: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy() -> ReadPolicy {
        ReadPolicy {
            enabled: true,
            excluded_apps: vec!["bitwarden".into(), "secret".into()],
            ..ReadPolicy::default()
        }
    }

    fn window(name: &str, id: &str) -> FrontWindow {
        FrontWindow {
            title: "Doc".into(),
            pid: Some(7),
            name: name.into(),
            id: id.into(),
        }
    }

    fn field() -> focused::Surroundings {
        focused::Surroundings {
            key: ":1.5/field".into(),
            single_line: true,
            ..focused::Surroundings::default()
        }
    }

    #[test]
    fn an_app_that_cannot_be_named_fails_closed() {
        let judged = judge(1, &policy(), 99, None, |_| Some(field()));
        assert_eq!(
            judged.refusal,
            Some(Refusal::Unsupported(reasons::UNKNOWN_APP))
        );
        let no_pid = FrontWindow {
            pid: None,
            ..window("Editor", "editor")
        };
        let judged = judge(1, &policy(), 99, Some(&no_pid), |_| Some(field()));
        assert!(judged.refusal.is_some());
    }

    #[test]
    fn the_owner_is_judged_before_accessibility_is_asked() {
        let cases = [
            ("Foot", "foot", reasons::TERMINAL),
            ("Secret Notes", "notes", reasons::EXCLUDED_APP),
        ];
        for (name, id, reason) in cases {
            let judged = judge(1, &policy(), 99, Some(&window(name, id)), |_| {
                panic!("accessibility must not be asked about {name}")
            });
            assert_eq!(judged.refusal, Some(Refusal::Unsupported(reason)));
        }
        // LokalBot's own windows, by pid.
        let judged = judge(1, &policy(), 7, Some(&window("LokalBot", "x")), |_| {
            panic!("accessibility must not be asked about LokalBot")
        });
        assert_eq!(
            judged.refusal,
            Some(Refusal::Unsupported("Off in LokalBot."))
        );
    }

    #[test]
    fn accessibility_can_refuse_a_field_the_hints_allowed() {
        let editor = window("Editor", "editor");
        for (change, expected) in [
            (
                focused::Surroundings {
                    secure: true,
                    ..field()
                },
                Refusal::Blocked(reasons::SECURE),
            ),
            (
                focused::Surroundings {
                    terminal: true,
                    ..field()
                },
                Refusal::Unsupported(reasons::TERMINAL),
            ),
            (
                focused::Surroundings {
                    search: true,
                    ..field()
                },
                Refusal::Unsupported(reasons::SEARCH),
            ),
            (
                focused::Surroundings {
                    file_dialog: true,
                    ..field()
                },
                Refusal::Unsupported(reasons::FILE_DIALOG),
            ),
        ] {
            let judged = judge(1, &policy(), 99, Some(&editor), |_| Some(change));
            assert_eq!(judged.refusal, Some(expected));
            assert_eq!(judged.inner.refusal, Some(expected));
            assert_eq!(judged.accessible_key, None);
        }
    }

    #[test]
    fn an_app_without_accessibility_still_works_on_the_hints_alone() {
        let judged = judge(1, &policy(), 99, Some(&window("Editor", "editor")), |_| {
            None
        });
        assert_eq!(judged.refusal, None);
        assert_eq!(judged.inner.single_line, None);
        assert_eq!(judged.accessible_key, None);
        assert_eq!(judged.inner.window_title, "Doc");
    }

    #[test]
    fn accessibility_fills_in_the_rest() {
        let found = focused::Surroundings {
            title: "Doc - Browser".into(),
            url: Some("https://example.com/a".into()),
            ..field()
        };
        let judged = judge(1, &policy(), 99, Some(&window("Editor", "editor")), |_| {
            Some(found)
        });
        assert_eq!(judged.refusal, None);
        assert_eq!(judged.accessible_key.as_deref(), Some(":1.5/field"));
        assert_eq!(judged.inner.single_line, Some(true));
        assert_eq!(judged.inner.window_title, "Doc - Browser");
        assert_eq!(judged.inner.url.as_deref(), Some("https://example.com/a"));
    }
}
