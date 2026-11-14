//! Where each thing LokalBot needs from this computer stands, worked out once
//! for setup's access step and for Settings (Privacy & permissions, the
//! status lines, the list's badges, Overview) and `lokalbot-cli permissions`.
//! Linux and Windows have no permission prompts like macOS: a state is what
//! this computer can be seen to allow (`lokalbot_platform::access`), read
//! into one [`Probe`] that `AppData` keeps, plus what the running app has
//! found out for itself (a microphone listed, capture or the screenshot key
//! failing). Both places map that same reading through [`Permission::state`],
//! so they never disagree, and a state that can't be known before the
//! feature runs claims none.

use lokalbot_platform::access::{Check, Gap};

/// The Window Calls extension's page, where GNOME installs it from.
pub const WINDOW_CALLS_URL: &str = "https://extensions.gnome.org/extension/4724/window-calls/";

/// What this computer allows, read in the background.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Probe {
    pub microphone: Check,
    pub window_titles: Check,
    pub screen_text: Check,
    pub screenshots: Check,
    pub credential_store: Check,
}

impl Default for Probe {
    /// Nothing read yet: every state unknown.
    fn default() -> Self {
        Self {
            microphone: Check::Unknown,
            window_titles: Check::Unknown,
            screen_text: Check::Unknown,
            screenshots: Check::Unknown,
            credential_store: Check::Unknown,
        }
    }
}

impl Probe {
    /// Reads every check. Blocks for up to a few seconds; call it off the
    /// UI thread.
    pub fn read() -> Self {
        use lokalbot_platform::access;
        Self {
            microphone: access::microphone(),
            window_titles: access::window_titles(),
            screen_text: access::screen_text(),
            screenshots: access::screenshots(),
            credential_store: access::credential_store(),
        }
    }
}

/// What the running app has seen for itself, beyond the probe.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Observed {
    /// A microphone shows up at all. On Linux, where no switch guards it,
    /// that is what can be checked.
    pub microphone_found: bool,
    /// Screen capture said this desktop can't capture the window in front.
    pub capture_failed: bool,
    /// The key that encrypts screenshots couldn't be kept.
    pub key_failed: bool,
}

/// One thing setup asks about and Settings lists.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Permission {
    Microphone,
    /// The app and window title in front (X11, a compositor, a GNOME extension).
    WindowTitles,
    /// Text on screen through AT-SPI or UI Automation.
    Accessibility,
    Screenshots,
    /// The key that encrypts screenshots.
    CredentialStore,
}

/// Where one stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Allowed,
    /// The system has it switched off; only its settings can turn it on.
    TurnedOff,
    Missing(Gap),
    /// Can't be known before the feature runs: no state is claimed.
    Unchecked,
}

impl Permission {
    /// As `lokalbot-cli permissions request` takes it.
    pub fn name(self) -> &'static str {
        match self {
            Permission::Microphone => "microphone",
            Permission::WindowTitles => "window-titles",
            Permission::Accessibility => "accessibility",
            Permission::Screenshots => "screen-recording",
            Permission::CredentialStore => "credential-store",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Permission::Microphone => lokalbot_i18n::tr("Microphone"),
            Permission::WindowTitles => lokalbot_i18n::tr("App and window activity"),
            Permission::Accessibility => lokalbot_i18n::tr("Accessibility"),
            Permission::Screenshots => lokalbot_i18n::tr("Screen Recording"),
            Permission::CredentialStore => lokalbot_i18n::tr("Credential store"),
        }
    }

    /// What it is for.
    pub fn reason(self) -> &'static str {
        match self {
            Permission::Microphone => lokalbot_i18n::tr("Records your side of each call."),
            Permission::WindowTitles => {
                lokalbot_i18n::tr("Reads the title of the window you are using.")
            }
            Permission::Accessibility => {
                lokalbot_i18n::tr("Reads window titles and the text on screen.")
            }
            Permission::Screenshots => {
                lokalbot_i18n::tr("Takes the screenshots, which stay encrypted on this PC.")
            }
            Permission::CredentialStore => {
                lokalbot_i18n::tr("Keeps the key that encrypts your screenshots.")
            }
        }
    }

    /// Where it stands, from `probe` and what the app has `observed`.
    /// `linux` because only there does a listed microphone mean it can be used.
    pub fn state(self, probe: &Probe, observed: &Observed, linux: bool) -> State {
        let check = match self {
            Permission::Microphone => match probe.microphone {
                Check::Unknown if linux && observed.microphone_found => Check::Ready,
                check => check,
            },
            Permission::WindowTitles => probe.window_titles,
            Permission::Accessibility => probe.screen_text,
            Permission::Screenshots if observed.capture_failed => {
                Check::Missing(Gap::WindowScreenshots)
            }
            Permission::Screenshots => probe.screenshots,
            Permission::CredentialStore if observed.key_failed => {
                Check::Missing(Gap::CredentialStore)
            }
            Permission::CredentialStore => probe.credential_store,
        };
        match check {
            Check::Ready => State::Allowed,
            Check::TurnedOff => State::TurnedOff,
            Check::Missing(gap) => State::Missing(gap),
            Check::Unknown => State::Unchecked,
        }
    }

    /// What a row says about `state` beyond its reason: the problem, or why
    /// nothing can be said yet. `None` when there's nothing to add.
    pub fn note(self, state: State) -> Option<&'static str> {
        match state {
            State::Allowed => None,
            State::TurnedOff => Some(lokalbot_i18n::tr(
                "Turned off earlier. Switch it on in System Settings.",
            )),
            State::Missing(gap) => Some(gap_text(gap)),
            State::Unchecked => unchecked_text(self),
        }
    }
}

/// What is missing, worded for a row.
pub fn gap_text(gap: Gap) -> &'static str {
    match gap {
        Gap::GnomeWindowExtension => lokalbot_i18n::tr(
            "GNOME needs the Window Calls extension to tell LokalBot which window is in front. Until it is installed, day memory records nothing.",
        ),
        Gap::WindowTitles => lokalbot_i18n::tr(
            "This desktop does not tell LokalBot which window is in front, so day memory records nothing here.",
        ),
        Gap::AccessibilityService => {
            lokalbot_i18n::tr("The accessibility service (AT-SPI) isn't available in this session.")
        }
        Gap::WindowScreenshots => lokalbot_i18n::tr(
            "This desktop can't capture only the window in front, so LokalBot keeps text without screenshots.",
        ),
        Gap::CredentialStore => lokalbot_i18n::tr("The system credential store is not available."),
    }
}

/// What a row whose state can't be checked says instead.
fn unchecked_text(permission: Permission) -> Option<&'static str> {
    match permission {
        Permission::Microphone if cfg!(target_os = "windows") => Some(lokalbot_i18n::tr(
            "Checked when you first record. Windows keeps its own switch under Privacy & security → Microphone.",
        )),
        Permission::Microphone => Some(lokalbot_i18n::tr("Checked when you first record.")),
        Permission::Screenshots => Some(lokalbot_i18n::tr(
            "Your desktop may ask once, the first time LokalBot takes a screenshot.",
        )),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_found_microphone_counts_as_allowed_only_on_linux() {
        let probe = Probe::default();
        let found = Observed {
            microphone_found: true,
            ..Observed::default()
        };
        let mic = Permission::Microphone;
        assert_eq!(mic.state(&probe, &found, true), State::Allowed);
        assert_eq!(
            mic.state(&probe, &Observed::default(), true),
            State::Unchecked
        );
        // Windows lists microphones its privacy switch keeps apps away from.
        assert_eq!(mic.state(&probe, &found, false), State::Unchecked);
        let off = Probe {
            microphone: Check::TurnedOff,
            ..Probe::default()
        };
        assert_eq!(mic.state(&off, &found, false), State::TurnedOff);
        assert_eq!(mic.state(&off, &found, true), State::TurnedOff);
    }

    #[test]
    fn each_permission_reads_its_own_check() {
        let probe = Probe {
            microphone: Check::Ready,
            window_titles: Check::Missing(Gap::GnomeWindowExtension),
            screen_text: Check::Ready,
            screenshots: Check::Unknown,
            credential_store: Check::Missing(Gap::CredentialStore),
        };
        let seen = Observed::default();
        let states: Vec<State> = [
            Permission::Microphone,
            Permission::WindowTitles,
            Permission::Accessibility,
            Permission::Screenshots,
            Permission::CredentialStore,
        ]
        .into_iter()
        .map(|p| p.state(&probe, &seen, true))
        .collect();
        assert_eq!(
            states,
            [
                State::Allowed,
                State::Missing(Gap::GnomeWindowExtension),
                State::Allowed,
                State::Unchecked,
                State::Missing(Gap::CredentialStore),
            ]
        );
    }

    #[test]
    fn what_capture_found_out_outranks_the_probe() {
        let ready = Probe {
            screenshots: Check::Ready,
            credential_store: Check::Ready,
            ..Probe::default()
        };
        let failed = Observed {
            capture_failed: true,
            key_failed: true,
            ..Observed::default()
        };
        assert_eq!(
            Permission::Screenshots.state(&ready, &failed, true),
            State::Missing(Gap::WindowScreenshots)
        );
        assert_eq!(
            Permission::CredentialStore.state(&ready, &failed, true),
            State::Missing(Gap::CredentialStore)
        );
        // A portal that may ask stays unknown until capture says otherwise.
        assert_eq!(
            Permission::Screenshots.state(&Probe::default(), &Observed::default(), true),
            State::Unchecked
        );
    }

    #[test]
    fn notes_say_what_is_wrong_and_never_claim_an_unknown() {
        assert_eq!(Permission::Microphone.note(State::Allowed), None);
        assert_eq!(
            Permission::WindowTitles.note(State::Missing(Gap::GnomeWindowExtension)),
            Some(gap_text(Gap::GnomeWindowExtension))
        );
        assert!(Permission::Microphone.note(State::Unchecked).is_some());
        assert!(Permission::Screenshots.note(State::Unchecked).is_some());
        assert_eq!(Permission::WindowTitles.note(State::Unchecked), None);
    }
}
