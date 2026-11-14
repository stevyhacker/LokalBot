//! "Try it…" on Autocomplete and Dictation (`AutocompleteTrySheet`,
//! `DictationTrySheet`): the try-out opens over its page as a sheet, so the
//! page leads with its settings. Opening one turns nothing on; Done closes it.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Sizable as _, WindowExt as _, v_flex};
use gpui_kit::{
    AppContext as _, Context, Entity, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _, Subscription, Window,
    div, px,
};

use super::SettingsPage;
use crate::state::AppData;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::settings_row;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TryKind {
    Autocomplete,
    Dictation,
}

/// Opens the sheet over the Settings window.
pub fn open(
    page: Entity<SettingsPage>,
    kind: TryKind,
    window: &mut Window,
    cx: &mut gpui_kit::App,
) {
    let sheet = cx.new(|cx| TrySheet::new(page, kind, cx));
    window.open_dialog(cx, move |dialog, _, _| {
        dialog.w(px(600.)).close_button(false).child(sheet.clone())
    });
}

struct TrySheet {
    page: Entity<SettingsPage>,
    kind: TryKind,
    _subscriptions: Vec<Subscription>,
}

impl TrySheet {
    fn new(page: Entity<SettingsPage>, kind: TryKind, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let mut subscriptions = vec![
            cx.observe(&page, |_, _, cx| cx.notify()),
            cx.observe(&data, |_, _, cx| cx.notify()),
        ];
        // The suggestion in the editor comes from the autocomplete engine.
        if let Some(autocomplete) = crate::autocomplete::global(cx) {
            subscriptions.push(cx.observe(&autocomplete, |_, _, cx| cx.notify()));
        }
        Self {
            page,
            kind,
            _subscriptions: subscriptions,
        }
    }
}

impl Render for TrySheet {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let kind = self.kind;
        let (title, explanation, body) = self.page.update(cx, |page, cx| match kind {
            TryKind::Autocomplete => (
                lokalbot_i18n::tr("Try autocomplete"),
                page.autocomplete_try_explanation(cx),
                page.autocomplete_try(cx),
            ),
            TryKind::Dictation => (
                lokalbot_i18n::tr("Try dictation"),
                lokalbot_i18n::tr("The result shows here. Nothing is pasted into another app, and your clipboard is left alone.").to_string(),
                page.dictation_try(cx),
            ),
        });
        let footer_note = (kind == TryKind::Autocomplete).then(|| {
            settings_row::help(
                lokalbot_i18n::tr("Uses the same settings and model as in other apps."),
                cx,
            )
        });
        v_flex()
            .w_full()
            .max_h(px(560.))
            .gap(px(12.))
            .child(
                v_flex()
                    .gap(px(4.))
                    .child(
                        div()
                            .text_size(ty::COLUMN_TITLE + px(4.))
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(title),
                    )
                    .child(settings_row::help(explanation, cx)),
            )
            .child(
                div()
                    .id(match kind {
                        TryKind::Autocomplete => "settings-try-autocomplete-body",
                        TryKind::Dictation => "settings-try-dictation-body",
                    })
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .child(body),
            )
            .child(div().h(px(1.)).w_full().bg(lb.separator))
            .child(
                h_flex()
                    .w_full()
                    .gap(px(12.))
                    .items_center()
                    .child(div().flex_1().min_w_0().children(footer_note))
                    .child(
                        Button::new("settings-try-done")
                            .primary()
                            .small()
                            .label(lokalbot_i18n::tr("Done"))
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    ),
            )
    }
}
