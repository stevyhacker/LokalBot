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
use lokalbot_platform::access::Gap;

use crate::access::{Observed, Probe, WINDOW_CALLS_URL};
pub(super) use crate::access::{Permission, State as RowState};

use super::{Draft, Onboarding, card, done_label, heading, quiet, row, row_title};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Row {
    pub permission: Permission,
    pub state: RowState,
}

/// The rows for `draft`, each in the state Settings shows for it too
/// (`crate::access`).
pub(super) fn rows(draft: &Draft, probe: &Probe, observed: &Observed, linux: bool) -> Vec<Row> {
    permissions(draft)
        .into_iter()
        .map(|permission| Row {
            permission,
            state: permission.state(probe, observed, linux),
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

fn symbol(permission: Permission) -> Ico {
    match permission {
        Permission::Microphone => Ico::Mic,
        Permission::WindowTitles => Ico::AppWindow,
        Permission::Accessibility => Ico::Accessibility,
        Permission::Screenshots => Ico::Camera,
        Permission::CredentialStore => Ico::KeyRound,
    }
}

/// The setup choice it serves, shown as a tag on its row.
fn feature(permission: Permission) -> &'static str {
    match permission {
        Permission::Microphone => lokalbot_i18n::tr("Meeting notes"),
        _ => lokalbot_i18n::tr("Your workday"),
    }
}

impl Onboarding {
    /// The rows, from the reading Settings shows too (`AppData::access`).
    pub(super) fn access_rows(&self, cx: &App) -> Vec<Row> {
        let data = self.data.read(cx);
        rows(
            &self.draft,
            &data.access,
            &data.access_observed(),
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
            .child(row_title(permission.title(), Some(feature(permission)), cx))
            .child(quiet(permission.reason(), cx))
            .map(|this| match item.state {
                RowState::Allowed => this,
                RowState::TurnedOff => this.child(warning(
                    lokalbot_i18n::tr("Turned off earlier. Switch it on in System Settings."),
                    cx,
                )),
                RowState::Missing(gap) => this.child(warning(crate::access::gap_text(gap), cx)),
                RowState::Unchecked => this.children(permission.note(item.state).map(|text| {
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
        row(symbol(permission), false, detail, trailing, cx)
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
    use lokalbot_platform::access::Check;

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
    fn rows_carry_what_the_desktop_reports() {
        let probe = Probe {
            microphone: Check::Ready,
            window_titles: Check::Missing(Gap::GnomeWindowExtension),
            screen_text: Check::Ready,
            screenshots: Check::Unknown,
            credential_store: Check::Missing(Gap::CredentialStore),
        };
        let choice = draft(true, ScreenContextMode::TextAndVisual);
        let rows = rows(&choice, &probe, &Observed::default(), true);
        let states: Vec<RowState> = rows.iter().map(|row| row.state).collect();
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
        assert_eq!(allowed_count(&rows), Some((2, 4)));
    }

    #[test]
    fn no_count_when_nothing_can_be_checked() {
        let rows = rows(
            &draft(false, ScreenContextMode::ActivityOnly),
            &Probe::default(),
            &Observed::default(),
            true,
        );
        assert_eq!(allowed_count(&rows), None);
    }
}
