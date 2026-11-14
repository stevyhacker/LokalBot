//! Setup, step 2 (`OnboardingAccessStep.swift`): only what the choices need,
//! each row naming the feature it serves, why, and where it stands. Linux and
//! Windows have no permission prompts like macOS: each row shows what this
//! computer can be seen to allow (`lokalbot_platform::access`), and a row
//! whose state can't be known before the feature runs claims none.

use crate::i18n::h_flex;
use gpui_kit::component::button::Button;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Div, IntoElement, ParentElement as _, Styled as _, div, px,
};
use lokalbot_platform::access::{Check, Gap};

use super::{Draft, Onboarding, card, done_label, heading, quiet, row, row_title};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

/// The Window Calls extension's page, where GNOME installs it from.
const WINDOW_CALLS_URL: &str = "https://extensions.gnome.org/extension/4724/window-calls/";

/// What setup can ask about on this computer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Permission {
    Microphone,
    /// The app and window title in front (X11, a compositor, a GNOME extension).
    WindowTitles,
    /// Text on screen through AT-SPI or UI Automation.
    Accessibility,
    Screenshots,
    /// The key that encrypts screenshots.
    CredentialStore,
}

/// The microphone always (Record uses it even with detection off), window
/// titles for the workday, accessibility once it keeps text, and screenshots
/// with their key only for screenshots (`OnboardingAccess.permissions`).
pub(super) fn permissions(draft: &Draft) -> Vec<Permission> {
    let mut result = vec![Permission::Microphone];
    if draft.day_memory {
        result.push(Permission::WindowTitles);
    }
    if draft.reads_screen_text() {
        result.push(Permission::Accessibility);
    }
    if draft.takes_screenshots() {
        result.push(Permission::Screenshots);
        result.push(Permission::CredentialStore);
    }
    result
}

/// What one row shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum RowState {
    Allowed,
    /// The system has it switched off; only its settings can turn it on.
    TurnedOff,
    Missing(Gap),
    /// Can't be known before the feature runs: no state is claimed.
    Unchecked,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Row {
    pub permission: Permission,
    pub state: RowState,
}

/// What this computer allows, read in the background.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Probe {
    microphone: Check,
    window_titles: Check,
    screen_text: Check,
    screenshots: Check,
    credential_store: Check,
}

impl Default for Probe {
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
    pub(super) fn read() -> Self {
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

/// The rows for `draft`. `microphone_found` is whether a microphone shows up
/// at all; on Linux, where no switch guards it, that is what can be checked.
pub(super) fn rows(draft: &Draft, probe: &Probe, microphone_found: bool, linux: bool) -> Vec<Row> {
    permissions(draft)
        .into_iter()
        .map(|permission| {
            let check = match permission {
                Permission::Microphone => match probe.microphone {
                    Check::Unknown if linux && microphone_found => Check::Ready,
                    check => check,
                },
                Permission::WindowTitles => probe.window_titles,
                Permission::Accessibility => probe.screen_text,
                Permission::Screenshots => probe.screenshots,
                Permission::CredentialStore => probe.credential_store,
            };
            let state = match check {
                Check::Ready => RowState::Allowed,
                Check::TurnedOff => RowState::TurnedOff,
                Check::Missing(gap) => RowState::Missing(gap),
                Check::Unknown => RowState::Unchecked,
            };
            Row { permission, state }
        })
        .collect()
}

/// "2 of 3 allowed", counting only rows whose state is known; `None` when
/// no row's is.
pub(super) fn allowed_count(rows: &[Row]) -> Option<(usize, usize)> {
    let known: Vec<&Row> = rows
        .iter()
        .filter(|row| row.state != RowState::Unchecked)
        .collect();
    (!known.is_empty()).then(|| {
        (
            known
                .iter()
                .filter(|row| row.state == RowState::Allowed)
                .count(),
            known.len(),
        )
    })
}

impl Permission {
    fn symbol(self) -> Ico {
        match self {
            Permission::Microphone => Ico::Mic,
            Permission::WindowTitles => Ico::AppWindow,
            Permission::Accessibility => Ico::Accessibility,
            Permission::Screenshots => Ico::Camera,
            Permission::CredentialStore => Ico::KeyRound,
        }
    }

    fn title(self) -> &'static str {
        match self {
            Permission::Microphone => lokalbot_i18n::tr("Microphone"),
            Permission::WindowTitles => lokalbot_i18n::tr("App and window activity"),
            Permission::Accessibility => lokalbot_i18n::tr("Accessibility"),
            Permission::Screenshots => lokalbot_i18n::tr("Screen Recording"),
            Permission::CredentialStore => lokalbot_i18n::tr("Credential store"),
        }
    }

    /// The setup choice it serves, shown as a tag on its row.
    fn feature(self) -> &'static str {
        match self {
            Permission::Microphone => lokalbot_i18n::tr("Meeting notes"),
            _ => lokalbot_i18n::tr("Your workday"),
        }
    }

    fn reason(self) -> &'static str {
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
}

/// What is missing, worded for the row.
fn gap_text(gap: Gap) -> &'static str {
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

impl Onboarding {
    pub(super) fn access_rows(&self, cx: &App) -> Vec<Row> {
        let microphone_found = !self.data.read(cx).audio_inputs.is_empty();
        rows(
            &self.draft,
            &self.access,
            microphone_found,
            cfg!(target_os = "linux"),
        )
    }

    pub(super) fn render_access(&self, cx: &mut Context<Self>) -> Div {
        let rows = self.access_rows(cx);
        let mut list = card(cx);
        for (index, item) in rows.iter().enumerate() {
            if index > 0 {
                list = list.child(ui::divider(cx));
            }
            list = list.child(self.permission_row(index, *item, cx));
        }
        v_flex()
            .w_full()
            .gap(px(16.))
            .child(heading(
                lokalbot_i18n::tr("Allow access"),
                Some(
                    lokalbot_i18n::tr(
                        "LokalBot asks only for what your choices need. Skip one and that feature waits until you allow it.",
                    )
                    .to_string(),
                ),
                cx,
            ))
            .child(list)
    }

    fn permission_row(&self, index: usize, item: Row, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let permission = item.permission;
        let detail = v_flex()
            .gap(px(2.))
            .child(row_title(
                permission.title(),
                Some(permission.feature()),
                cx,
            ))
            .child(quiet(permission.reason(), cx))
            .map(|this| match item.state {
                RowState::Allowed => this,
                RowState::TurnedOff => this.child(warning(
                    lokalbot_i18n::tr("Turned off earlier. Switch it on in System Settings."),
                    cx,
                )),
                RowState::Missing(gap) => this.child(warning(gap_text(gap), cx)),
                RowState::Unchecked => this.children(unchecked_text(permission).map(|text| {
                    div()
                        .text_size(ty::SECONDARY)
                        .line_height(px(18.))
                        .text_color(lb.text_secondary)
                        .child(ui::text::paragraph(text))
                })),
            });
        let data = self.data.clone();
        let open_settings = move |id: &'static str| -> AnyElement {
            let data = data.clone();
            Button::new((id, index))
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Open System Settings…"))
                .on_click(move |_, _, cx| {
                    crate::control::permissions::request("microphone", &data, cx)
                })
                .into_any_element()
        };
        let trailing: Option<AnyElement> = match (item.state, permission) {
            (RowState::Allowed, _) => Some(done_label(lokalbot_i18n::tr("Allowed"), cx)),
            (RowState::TurnedOff, Permission::Microphone) => {
                Some(open_settings("onboarding-open-settings"))
            }
            (RowState::Unchecked, Permission::Microphone) if cfg!(target_os = "windows") => {
                Some(open_settings("onboarding-open-settings"))
            }
            (RowState::Missing(Gap::GnomeWindowExtension), _) => Some(
                Button::new(("onboarding-window-calls", index))
                    .outline()
                    .small()
                    .label(lokalbot_i18n::tr("Get Window Calls…"))
                    .on_click(|_, _, cx| cx.open_url(WINDOW_CALLS_URL))
                    .into_any_element(),
            ),
            (RowState::Missing(_) | RowState::TurnedOff, _) => Some(super::attention_label(
                lokalbot_i18n::tr("Needs Attention"),
                cx,
            )),
            (RowState::Unchecked, _) => None,
        };
        row(permission.symbol(), false, detail, trailing, cx)
    }
}

/// A line in the attention colour with a warning symbol.
fn warning(text: &'static str, cx: &App) -> Div {
    let lb = cx.lb();
    h_flex()
        .pt(px(2.))
        .gap(px(5.))
        .items_start()
        .child(div().pt(px(2.)).flex_none().child(ui::icon(
            Ico::TriangleAlert,
            px(12.),
            lb.attention_text,
        )))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(ty::SECONDARY)
                .line_height(px(18.))
                .text_color(lb.attention_text)
                .child(ui::text::paragraph(text)),
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::ScreenContextMode;
    use lokalbot_core::settings::Settings;

    fn draft(day_memory: bool, mode: ScreenContextMode) -> Draft {
        let mut draft = Draft::new(&Settings::default());
        draft.day_memory = day_memory;
        draft.context_mode = mode;
        draft
    }

    #[test]
    fn asks_only_for_what_the_choices_need() {
        use Permission::*;
        assert_eq!(
            permissions(&draft(false, ScreenContextMode::TextAndVisual)),
            [Microphone]
        );
        assert_eq!(
            permissions(&draft(true, ScreenContextMode::ActivityOnly)),
            [Microphone, WindowTitles]
        );
        assert_eq!(
            permissions(&draft(true, ScreenContextMode::Text)),
            [Microphone, WindowTitles, Accessibility]
        );
        assert_eq!(
            permissions(&draft(true, ScreenContextMode::TextAndVisual)),
            [
                Microphone,
                WindowTitles,
                Accessibility,
                Screenshots,
                CredentialStore
            ]
        );
    }

    #[test]
    fn a_found_microphone_counts_as_allowed_only_on_linux() {
        let probe = Probe::default();
        let choice = draft(false, ScreenContextMode::ActivityOnly);
        assert_eq!(
            rows(&choice, &probe, true, true)[0].state,
            RowState::Allowed
        );
        assert_eq!(
            rows(&choice, &probe, false, true)[0].state,
            RowState::Unchecked
        );
        // Windows lists microphones its privacy switch keeps apps away from.
        assert_eq!(
            rows(&choice, &probe, true, false)[0].state,
            RowState::Unchecked
        );
        let off = Probe {
            microphone: Check::TurnedOff,
            ..Probe::default()
        };
        assert_eq!(
            rows(&choice, &off, true, false)[0].state,
            RowState::TurnedOff
        );
    }

    #[test]
    fn rows_carry_what_the_desktop_reports() {
        let probe = Probe {
            microphone: Check::Ready,
            window_titles: Check::Missing(Gap::GnomeWindowExtension),
            screen_text: Check::Ready,
            screenshots: Check::Unknown,
            credential_store: Check::Missing(Gap::CredentialStore),
        };
        let states: Vec<RowState> = rows(
            &draft(true, ScreenContextMode::TextAndVisual),
            &probe,
            false,
            true,
        )
        .into_iter()
        .map(|row| row.state)
        .collect();
        assert_eq!(
            states,
            [
                RowState::Allowed,
                RowState::Missing(Gap::GnomeWindowExtension),
                RowState::Allowed,
                RowState::Unchecked,
                RowState::Missing(Gap::CredentialStore),
            ]
        );
        // The unknown screenshot row counts neither way.
        let rows = rows(
            &draft(true, ScreenContextMode::TextAndVisual),
            &probe,
            false,
            true,
        );
        assert_eq!(allowed_count(&rows), Some((2, 4)));
    }

    #[test]
    fn no_count_when_nothing_can_be_checked() {
        let rows = rows(
            &draft(false, ScreenContextMode::ActivityOnly),
            &Probe::default(),
            false,
            true,
        );
        assert_eq!(allowed_count(&rows), None);
    }
}
