//! Dictation shortcuts made only of modifier keys, like Ctrl+Alt
//! (`DictationInputMonitor`'s chords). They are watched, never taken: reading the
//! keyboard's state consumes nothing, so other shortcuts that start with the same
//! modifiers keep working. X11 and Windows can both report that state. A Wayland
//! desktop tells an app about keys only through a shortcut with a real key, so
//! chords aren't offered there.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use lokalbot_core::settings::DictationTriggerMode;

use crate::shortcuts::{Handler, Shortcut, ShortcutError, ShortcutEvent};

/// How often the keyboard's state is read. A chord can't be missed at this rate:
/// nobody holds two modifiers for under 30 ms on purpose.
const POLL: Duration = Duration::from_millis(30);
/// How long a chord is held before push to talk starts, so Ctrl+Alt followed
/// quickly by another key never opens the microphone (`chordHoldDelay`).
const HOLD_DELAY: Duration = Duration::from_millis(200);
/// Tap or hold: a press shorter than this keeps recording after release.
const TAP_THRESHOLD: Duration = Duration::from_millis(300);

/// What a chord asks dictation to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChordAction {
    Start,
    Stop,
    Toggle,
    /// It turned out to be part of another shortcut (Ctrl+Alt then T).
    Cancel,
}

/// The keyboard at one moment.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Held {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub logo: bool,
    /// Any key that isn't a modifier.
    pub other_key: bool,
}

impl Held {
    fn is_superset_of(&self, other: &Held) -> bool {
        (self.ctrl || !other.ctrl)
            && (self.alt || !other.alt)
            && (self.shift || !other.shift)
            && (self.logo || !other.logo)
    }

    fn same_modifiers(&self, other: &Held) -> bool {
        self.ctrl == other.ctrl
            && self.alt == other.alt
            && self.shift == other.shift
            && self.logo == other.logo
    }
}

/// The chord state machine (`handleModifiers`, `interruptChord`, `releaseChord`).
pub(crate) struct ChordTracker {
    chord: Held,
    mode: DictationTriggerMode,
    /// The chord is down.
    held: bool,
    interrupted: bool,
    started: bool,
    pressed_at: Option<Instant>,
    /// Tap or hold: pressed while dictating, so a clean release finishes.
    finishes_on_release: bool,
    start_at: Option<Instant>,
}

impl ChordTracker {
    pub fn new(shortcut: &Shortcut, mode: DictationTriggerMode) -> Self {
        Self {
            chord: Held {
                ctrl: shortcut.ctrl,
                alt: shortcut.alt,
                shift: shortcut.shift,
                logo: shortcut.logo,
                other_key: false,
            },
            mode,
            held: false,
            interrupted: false,
            started: false,
            pressed_at: None,
            finishes_on_release: false,
            start_at: None,
        }
    }

    /// One reading of the keyboard. `active` says whether a dictation is
    /// starting or recording.
    pub fn update(&mut self, now_held: Held, active: bool, now: Instant) -> Option<ChordAction> {
        if !self.held {
            if now_held.same_modifiers(&self.chord) && !now_held.other_key {
                self.press(active, now);
            }
            return None;
        }
        if !now_held.is_superset_of(&self.chord) {
            return self.release(now);
        }
        // Another key or another modifier: a different shortcut, unless this
        // hold already started a dictation and it's just a modifier joining.
        let extra_modifier = !now_held.same_modifiers(&self.chord);
        if now_held.other_key || (extra_modifier && !self.started) {
            return self.interrupt();
        }
        if let Some(at) = self.start_at
            && now >= at
            && !self.interrupted
        {
            self.start_at = None;
            self.started = true;
            return Some(ChordAction::Start);
        }
        None
    }

    fn press(&mut self, active: bool, now: Instant) {
        self.held = true;
        self.interrupted = false;
        self.started = false;
        self.finishes_on_release = false;
        self.pressed_at = Some(now);
        self.start_at = None;
        if self.mode == DictationTriggerMode::TapOrHold && active {
            self.finishes_on_release = true;
            return;
        }
        if matches!(
            self.mode,
            DictationTriggerMode::PushToTalk | DictationTriggerMode::TapOrHold
        ) {
            self.start_at = Some(now + HOLD_DELAY);
        }
    }

    fn interrupt(&mut self) -> Option<ChordAction> {
        if self.interrupted {
            return None;
        }
        self.interrupted = true;
        self.start_at = None;
        let cancels = self.started && self.mode != DictationTriggerMode::Toggle;
        self.started = false;
        cancels.then_some(ChordAction::Cancel)
    }

    fn release(&mut self, now: Instant) -> Option<ChordAction> {
        let started = self.started;
        let clean = !self.interrupted;
        let finishes = self.finishes_on_release;
        let held_for = self
            .pressed_at
            .map_or(Duration::ZERO, |at| now.duration_since(at));
        self.held = false;
        self.interrupted = false;
        self.started = false;
        self.finishes_on_release = false;
        self.pressed_at = None;
        self.start_at = None;
        match self.mode {
            DictationTriggerMode::PushToTalk => started.then_some(ChordAction::Stop),
            DictationTriggerMode::Toggle => clean.then_some(ChordAction::Toggle),
            DictationTriggerMode::TapOrHold => {
                if finishes {
                    clean.then_some(ChordAction::Stop)
                } else if started {
                    // A hold finishes on release; a tap keeps recording.
                    (held_for >= TAP_THRESHOLD).then_some(ChordAction::Stop)
                } else {
                    // Released before the hold delay: a tap, so start now.
                    clean.then_some(ChordAction::Start)
                }
            }
        }
    }
}

/// Reads the keyboard. `None` when it can't any more, which ends the watcher.
pub(crate) trait KeyState: Send {
    fn read(&mut self) -> Option<Held>;
}

/// Whether this desktop can watch modifier keys alone.
#[cfg(target_os = "linux")]
pub fn chords_available() -> bool {
    !crate::session::is_wayland() && crate::session::has_x11_display()
}

/// Whether this desktop can watch modifier keys alone.
#[cfg(not(target_os = "linux"))]
pub fn chords_available() -> bool {
    cfg!(windows)
}

/// Watches the keyboard for one chord until dropped.
pub(crate) struct Watcher {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Watcher {
    pub fn start(
        id: &str,
        shortcut: &Shortcut,
        mode: DictationTriggerMode,
        active: Arc<AtomicBool>,
        handler: Handler,
    ) -> Result<Self, ShortcutError> {
        let keys = key_state().map_err(ShortcutError::Failed)?;
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let stop = stop.clone();
            let id = id.to_string();
            let tracker = ChordTracker::new(shortcut, mode);
            std::thread::Builder::new()
                .name("lokalbot-shortcut-chord".into())
                .spawn(move || watch(keys, tracker, &id, &active, &stop, &handler))
                .map_err(|err| ShortcutError::Failed(err.to_string()))?
        };
        Ok(Self {
            stop,
            thread: Some(thread),
        })
    }
}

impl Drop for Watcher {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn watch(
    mut keys: Box<dyn KeyState>,
    mut tracker: ChordTracker,
    id: &str,
    active: &AtomicBool,
    stop: &AtomicBool,
    handler: &Handler,
) {
    while !stop.load(Ordering::SeqCst) {
        let Some(held) = keys.read() else {
            log::warn!("the dictation chord stopped: the keyboard can't be read");
            return;
        };
        let action = tracker.update(held, active.load(Ordering::SeqCst), Instant::now());
        if let Some(action) = action {
            handler(ShortcutEvent {
                id: id.to_string(),
                pressed: action == ChordAction::Start,
                chord: Some(action),
            });
        }
        std::thread::sleep(POLL);
    }
}

#[cfg(target_os = "linux")]
fn key_state() -> Result<Box<dyn KeyState>, String> {
    x11_keys::X11Keys::connect().map(|keys| Box::new(keys) as Box<dyn KeyState>)
}

#[cfg(windows)]
fn key_state() -> Result<Box<dyn KeyState>, String> {
    Ok(Box::new(win_keys::WinKeys))
}

#[cfg(not(any(target_os = "linux", windows)))]
fn key_state() -> Result<Box<dyn KeyState>, String> {
    Err("this system can't report modifier keys".into())
}

#[cfg(target_os = "linux")]
mod x11_keys {
    use std::time::{Duration, Instant};

    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::ConnectionExt as _;
    use x11rb::rust_connection::RustConnection;

    use super::{Held, KeyState};

    /// A keyboard layout can move modifiers around while LokalBot runs.
    const MAPPING_LIFETIME: Duration = Duration::from_secs(5);

    /// Which keycodes count as what, from the server's modifier mapping.
    #[derive(Default)]
    struct Mapping {
        ctrl: Vec<u8>,
        alt: Vec<u8>,
        shift: Vec<u8>,
        logo: Vec<u8>,
        /// Caps Lock, Num Lock and the rest, which don't interrupt a chord.
        ignored: Vec<u8>,
    }

    pub(super) struct X11Keys {
        connection: RustConnection,
        mapping: Mapping,
        mapped_at: Instant,
    }

    impl X11Keys {
        pub(super) fn connect() -> Result<Self, String> {
            let (connection, _) = x11rb::connect(None).map_err(|err| err.to_string())?;
            let mapping = read_mapping(&connection).ok_or("no modifier mapping")?;
            Ok(Self {
                connection,
                mapping,
                mapped_at: Instant::now(),
            })
        }
    }

    fn read_mapping(connection: &RustConnection) -> Option<Mapping> {
        let reply = connection.get_modifier_mapping().ok()?.reply().ok()?;
        let per = usize::from(reply.keycodes_per_modifier());
        let mut mapping = Mapping::default();
        if per == 0 {
            return Some(mapping);
        }
        for (index, keycodes) in reply.keycodes.chunks(per).enumerate() {
            let keycodes = keycodes.iter().copied().filter(|code| *code != 0);
            match index {
                0 => mapping.shift.extend(keycodes),
                2 => mapping.ctrl.extend(keycodes),
                3 => mapping.alt.extend(keycodes),
                6 => mapping.logo.extend(keycodes),
                _ => mapping.ignored.extend(keycodes),
            }
        }
        Some(mapping)
    }

    fn held_from_keymap(keys: &[u8], mapping: &Mapping) -> Held {
        let down = |code: u8| {
            keys.get(usize::from(code) / 8)
                .is_some_and(|byte| byte & (1 << (code % 8)) != 0)
        };
        let any = |codes: &[u8]| codes.iter().any(|code| down(*code));
        let modifier = |code: u8| {
            [
                &mapping.ctrl,
                &mapping.alt,
                &mapping.shift,
                &mapping.logo,
                &mapping.ignored,
            ]
            .iter()
            .any(|codes| codes.contains(&code))
        };
        Held {
            ctrl: any(&mapping.ctrl),
            alt: any(&mapping.alt),
            shift: any(&mapping.shift),
            logo: any(&mapping.logo),
            other_key: (8..=255u8).any(|code| down(code) && !modifier(code)),
        }
    }

    impl KeyState for X11Keys {
        fn read(&mut self) -> Option<Held> {
            if self.mapped_at.elapsed() >= MAPPING_LIFETIME {
                self.mapping = read_mapping(&self.connection)?;
                self.mapped_at = Instant::now();
            }
            let reply = self.connection.query_keymap().ok()?.reply().ok()?;
            let _ = self.connection.flush();
            Some(held_from_keymap(&reply.keys, &self.mapping))
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn mapping() -> Mapping {
            Mapping {
                ctrl: vec![37, 105],
                alt: vec![64],
                shift: vec![50],
                logo: vec![133],
                ignored: vec![66, 77],
            }
        }

        fn keymap(pressed: &[u8]) -> Vec<u8> {
            let mut keys = vec![0u8; 32];
            for code in pressed {
                keys[usize::from(*code) / 8] |= 1 << (code % 8);
            }
            keys
        }

        #[test]
        fn modifiers_and_other_keys_read_from_the_keymap() {
            let held = held_from_keymap(&keymap(&[37, 64]), &mapping());
            assert!(held.ctrl && held.alt && !held.shift && !held.logo && !held.other_key);
            let held = held_from_keymap(&keymap(&[105, 64, 28]), &mapping());
            assert!(held.ctrl && held.alt && held.other_key);
            // Caps Lock and Num Lock aren't another shortcut.
            let held = held_from_keymap(&keymap(&[37, 64, 66, 77]), &mapping());
            assert!(!held.other_key);
        }
    }
}

#[cfg(windows)]
mod win_keys {
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        GetAsyncKeyState, VK_CONTROL, VK_LCONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_MENU,
        VK_RCONTROL, VK_RMENU, VK_RSHIFT, VK_RWIN, VK_SHIFT,
    };

    use super::{Held, KeyState};

    pub(super) struct WinKeys;

    fn down(key: u16) -> bool {
        // SAFETY: takes only a virtual-key code.
        (unsafe { GetAsyncKeyState(i32::from(key)) } as u16) & 0x8000 != 0
    }

    impl KeyState for WinKeys {
        fn read(&mut self) -> Option<Held> {
            let ctrl = down(VK_LCONTROL.0) || down(VK_RCONTROL.0);
            // AltGr reports as Left Ctrl + Right Alt on many layouts: pressing
            // it alone must not read as Ctrl+Alt.
            let alt = down(VK_LMENU.0) || (down(VK_RMENU.0) && !down(VK_LCONTROL.0));
            let modifiers = [
                VK_SHIFT.0,
                VK_LSHIFT.0,
                VK_RSHIFT.0,
                VK_CONTROL.0,
                VK_LCONTROL.0,
                VK_RCONTROL.0,
                VK_MENU.0,
                VK_LMENU.0,
                VK_RMENU.0,
                VK_LWIN.0,
                VK_RWIN.0,
            ];
            // 0x08 is Backspace: below it are the mouse buttons. The lock keys
            // at 0x14, 0x90 and 0x91 aren't another shortcut.
            let other_key = (0x08..=0xFEu16)
                .filter(|key| !modifiers.contains(key) && ![0x14, 0x90, 0x91].contains(key))
                .any(down);
            Some(Held {
                ctrl,
                alt,
                shift: down(VK_LSHIFT.0) || down(VK_RSHIFT.0),
                logo: down(VK_LWIN.0) || down(VK_RWIN.0),
                other_key,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tracker(mode: DictationTriggerMode) -> ChordTracker {
        ChordTracker::new(&Shortcut::parse("Ctrl+Alt").unwrap(), mode)
    }

    const NOTHING: Held = Held {
        ctrl: false,
        alt: false,
        shift: false,
        logo: false,
        other_key: false,
    };
    const CHORD: Held = Held {
        ctrl: true,
        alt: true,
        ..NOTHING
    };
    const ONE: Held = Held {
        ctrl: true,
        ..NOTHING
    };
    const CHORD_AND_KEY: Held = Held {
        other_key: true,
        ..CHORD
    };
    const MORE: Held = Held {
        shift: true,
        ..CHORD
    };

    /// Feeds readings at `at` milliseconds and collects what they asked for.
    fn play(
        tracker: &mut ChordTracker,
        active: bool,
        readings: &[(u64, Held)],
    ) -> Vec<(u64, ChordAction)> {
        let start = Instant::now();
        readings
            .iter()
            .filter_map(|(at, held)| {
                tracker
                    .update(*held, active, start + Duration::from_millis(*at))
                    .map(|action| (*at, action))
            })
            .collect()
    }

    #[test]
    fn push_to_talk_starts_after_the_hold_delay_and_stops_on_release() {
        let mut chord = tracker(DictationTriggerMode::PushToTalk);
        assert_eq!(
            play(
                &mut chord,
                false,
                &[
                    (0, CHORD),
                    (100, CHORD),
                    (210, CHORD),
                    (500, CHORD),
                    (600, NOTHING)
                ],
            ),
            vec![(210, ChordAction::Start), (600, ChordAction::Stop)]
        );
    }

    #[test]
    fn a_chord_that_becomes_another_shortcut_never_opens_the_microphone() {
        let mut chord = tracker(DictationTriggerMode::PushToTalk);
        assert_eq!(
            play(
                &mut chord,
                false,
                &[
                    (0, CHORD),
                    (100, CHORD_AND_KEY),
                    (250, CHORD),
                    (300, NOTHING)
                ],
            ),
            vec![]
        );
    }

    #[test]
    fn a_key_after_dictation_began_cancels_it() {
        let mut chord = tracker(DictationTriggerMode::PushToTalk);
        assert_eq!(
            play(
                &mut chord,
                false,
                &[
                    (0, CHORD),
                    (210, CHORD),
                    (400, CHORD_AND_KEY),
                    (500, NOTHING)
                ],
            ),
            vec![(210, ChordAction::Start), (400, ChordAction::Cancel)]
        );
    }

    #[test]
    fn another_modifier_joining_is_a_different_shortcut() {
        let mut chord = tracker(DictationTriggerMode::Toggle);
        assert_eq!(
            play(
                &mut chord,
                false,
                &[(0, CHORD), (100, MORE), (200, NOTHING)]
            ),
            vec![]
        );
    }

    #[test]
    fn toggle_fires_on_a_clean_release_only() {
        let mut chord = tracker(DictationTriggerMode::Toggle);
        assert_eq!(
            play(&mut chord, false, &[(0, CHORD), (500, ONE), (510, NOTHING)]),
            vec![(500, ChordAction::Toggle)]
        );
        // Ctrl+Alt+T used as its own shortcut.
        let mut chord = tracker(DictationTriggerMode::Toggle);
        assert_eq!(
            play(
                &mut chord,
                false,
                &[(0, CHORD), (50, CHORD_AND_KEY), (60, CHORD), (70, NOTHING)],
            ),
            vec![]
        );
    }

    #[test]
    fn tap_or_hold_follows_how_long_it_was_held() {
        // A tap before the delay starts and keeps recording.
        let mut chord = tracker(DictationTriggerMode::TapOrHold);
        assert_eq!(
            play(&mut chord, false, &[(0, CHORD), (100, NOTHING)]),
            vec![(100, ChordAction::Start)]
        );
        // A tap just past the delay has started, and doesn't stop on release.
        let mut chord = tracker(DictationTriggerMode::TapOrHold);
        assert_eq!(
            play(
                &mut chord,
                false,
                &[(0, CHORD), (210, CHORD), (250, NOTHING)]
            ),
            vec![(210, ChordAction::Start)]
        );
        // A hold stops on release.
        let mut chord = tracker(DictationTriggerMode::TapOrHold);
        assert_eq!(
            play(
                &mut chord,
                false,
                &[(0, CHORD), (210, CHORD), (700, NOTHING)]
            ),
            vec![(210, ChordAction::Start), (700, ChordAction::Stop)]
        );
        // Pressed while dictating: a clean release finishes.
        let mut chord = tracker(DictationTriggerMode::TapOrHold);
        assert_eq!(
            play(&mut chord, true, &[(0, CHORD), (900, NOTHING)]),
            vec![(900, ChordAction::Stop)]
        );
    }

    #[test]
    fn a_chord_formed_while_typing_does_not_count() {
        let mut chord = tracker(DictationTriggerMode::Toggle);
        assert_eq!(
            play(
                &mut chord,
                false,
                &[(0, CHORD_AND_KEY), (20, CHORD_AND_KEY), (40, NOTHING)],
            ),
            vec![]
        );
    }
}
