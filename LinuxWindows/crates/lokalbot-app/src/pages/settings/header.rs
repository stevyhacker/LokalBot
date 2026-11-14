//! How every Settings page opens (`SettingsPageHeader.swift`): the page's
//! icon, name and one-line description, "Try it…" where the feature has
//! something to try, the page's own control and its main switch where it has
//! them, and under them one status line for each thing to know, with the
//! button that fixes it. Overview has no header: it opens with what needs you.
//!
//! A page fills in a [`HeaderSpec`] in `SettingsPage::header_spec`; the
//! window draws the header above the page's sections.

use std::rc::Rc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::progress::Progress;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Entity, FontWeight, IntoElement, ParentElement as _, SharedString,
    Styled as _, Window, div, px,
};

use super::status::{StatusAction, StatusLine, Tone};
use crate::i18n::h_flex;
use crate::state::{AppData, AppEvent, SettingsCategory};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, settings_row};
use lokalbot_i18n::directional;

/// Opens a Settings page, revealing a setting on it when one is named (a
/// catalog id such as "settings.permissions"): what a status line's `Open`
/// does. Make one with [`opener`].
pub type Opener = Rc<dyn Fn(SettingsCategory, Option<&'static str>, &mut Window, &mut App)>;

/// Opens a page's "Try it…".
pub type TryIt = Rc<dyn Fn(&mut Window, &mut App)>;

/// What a page's main switch does when flipped.
pub type SwitchChange = Rc<dyn Fn(bool, &mut Window, &mut App)>;

/// What a page adds to its header. Every field is optional: a page with
/// nothing to try and no main switch leaves it at `HeaderSpec::default()`.
#[derive(Default)]
pub struct HeaderSpec {
    /// Opens the page's "Try it…" (a sheet over the page on the Mac).
    pub try_it: Option<TryIt>,
    /// The page's main switch.
    pub switch: Option<HeaderSwitch>,
    /// A page's own leading control, such as Models' "Download all". Drawn
    /// before "Try it…" and the switch.
    pub accessory: Option<AnyElement>,
    /// The page's line under its name, when it is not the category's own
    /// (Dictation names its shortcut).
    pub summary: Option<String>,
}

/// The switch at the right of a page's header (`isOn`, `switchLabel`,
/// `switchSettingID`).
pub struct HeaderSwitch {
    /// The setting it stands for, so search and links land on it, such as
    /// "settings.cotypingEnabled". Highlighted while it is the found setting.
    pub setting_id: &'static str,
    pub on: bool,
    /// Runs on every flip. It must do exactly what the page's own switch did
    /// before, confirmations included: moving a control never skips one.
    pub on_change: SwitchChange,
}

/// Runs a status line's fix, an Overview row's or a permission row's, the
/// same way everywhere (`SettingsStatusActions.perform`). `open` selects a
/// page and reveals a setting on it.
pub fn perform(
    action: &StatusAction,
    data: &Entity<AppData>,
    open: &Opener,
    window: &mut Window,
    cx: &mut App,
) {
    match action {
        StatusAction::Permission(name) => crate::control::permissions::request(name, data, cx),
        StatusAction::Download => start_downloads(data, cx),
        StatusAction::Open(page, focus) => open(*page, *focus, window, cx),
    }
}

/// Downloads what Transcribe and Think are missing, one at a time, and
/// Autocomplete's model while Autocomplete is on
/// (`startCoreModelDownloads(includeAutocomplete:)`).
pub fn start_downloads(data: &Entity<AppData>, cx: &mut App) {
    data.update(cx, |data, cx| {
        let settings = data.settings.clone();
        if !(data.models.transcription_ready && data.models.think_ready) {
            data.request(AppEvent::PrepareModels, cx);
        }
        if settings.cotyping_enabled {
            for id in super::models::autocomplete_needs(&settings) {
                let here = data.models.installed.contains(&id);
                let running = data.downloads.get(&id).is_some_and(|d| d.error.is_none());
                if !here && !running {
                    data.request(AppEvent::DownloadModel(id), cx);
                }
            }
        }
    });
}

/// Stops the downloads "Download all" started: every model of the three
/// roles that is on its way (`cancelCoreModelDownloads`).
pub fn cancel_downloads(data: &Entity<AppData>, cx: &mut App) {
    data.update(cx, |data, cx| {
        let settings = data.settings.clone();
        let mut ids: Vec<String> = Vec::new();
        for role in [
            super::status::Role::Transcribe,
            super::status::Role::Think,
            super::status::Role::Autocomplete,
        ] {
            for id in super::status::role_ids(role, &settings).0 {
                if !ids.contains(&id) {
                    ids.push(id);
                }
            }
        }
        for id in ids {
            if data.downloads.get(&id).is_some_and(|d| d.error.is_none()) {
                data.request(AppEvent::CancelDownload(id), cx);
            }
        }
    });
}

/// Models' own header control (`ModelsView.downloadControl`): Cancel while
/// models arrive, "Download all · 5.9 GB" while some are missing, nothing
/// once they are all here.
pub fn download_control(
    status: &super::status::SettingsStatus,
    data: &Entity<AppData>,
) -> Option<AnyElement> {
    if !status.models_downloading().is_empty() {
        let data = data.clone();
        return Some(
            Button::new("settings-models-cancel-downloads")
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Cancel"))
                .tooltip(lokalbot_i18n::tr("Cancel the download"))
                .on_click(move |_, _, cx| cancel_downloads(&data, cx))
                .into_any_element(),
        );
    }
    if status.models_to_download().is_empty() {
        return None;
    }
    let label = match status.bytes_to_download() {
        Some(bytes) => lokalbot_i18n::fill(
            lokalbot_i18n::tr("Download all · %@"),
            &[&super::status::size(bytes)],
        ),
        None => lokalbot_i18n::tr("Download all").to_string(),
    };
    let data = data.clone();
    Some(
        Button::new("settings-models-download-all")
            .primary()
            .small()
            .label(directional(label))
            .on_click(move |_, _, cx| start_downloads(&data, cx))
            .into_any_element(),
    )
}

/// The header: a card with the page's name and controls, then its status
/// lines under hairlines.
#[allow(clippy::too_many_arguments)]
pub fn page_header(
    category: SettingsCategory,
    summary: String,
    lines: Vec<StatusLine>,
    spec: HeaderSpec,
    switch_highlighted: bool,
    data: &Entity<AppData>,
    open: Opener,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb().clone();
    let key = category.key();
    let title = super::catalog::category_title(category);
    let mut top = h_flex()
        .w_full()
        .gap(px(12.))
        .items_center()
        .py(px(4.))
        .child(ui::icon_tile(
            super::category_icon(category),
            lb.accent_text,
            px(38.),
        ))
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(2.))
                .child(
                    div()
                        .text_size(ty::COLUMN_TITLE + px(4.))
                        .font_weight(FontWeight::BOLD)
                        .text_color(lb.text)
                        .child(ui::text::paragraph(title)),
                )
                .child(settings_row::help(spec.summary.unwrap_or(summary), cx)),
        )
        .children(spec.accessory);
    if let Some(try_it) = spec.try_it {
        top = top.child(
            Button::new(SharedString::from(format!("settings-header-{key}-try")))
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Try it…"))
                .on_click(move |_, window, cx| try_it(window, cx)),
        );
    }
    if let Some(switch) = spec.switch {
        let on_change = switch.on_change.clone();
        top = top.child(
            div()
                .flex_none()
                .p(px(4.))
                .rounded(metric::ROW_RADIUS)
                .when(switch_highlighted, |this| {
                    this.bg(lb.accent_fill.opacity(0.14))
                })
                .child(settings_row::switch(
                    switch.setting_id,
                    switch.on,
                    move |on, window, cx| on_change(on, window, cx),
                )),
        );
    }
    let mut card = v_flex().w_full().child(top);
    for line in lines {
        card = card
            .child(div().mt(px(8.)).mb(px(2.)).h(px(1.)).bg(lb.separator))
            .child(status_line(category, line, data, open.clone(), cx));
    }
    ui::grouped_surface(cx)
        .w_full()
        .px(px(14.))
        .py(px(10.))
        .child(card)
        .into_any_element()
}

/// One status line: a sign for its tone, the sentence, and its fix
/// (`SettingsStatusLineRow`).
pub fn status_line(
    category: SettingsCategory,
    line: StatusLine,
    data: &Entity<AppData>,
    open: Opener,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb().clone();
    let sign = match line.tone {
        Tone::Need => ui::icon(Ico::TriangleAlert, px(14.), lb.attention_text).into_any_element(),
        Tone::Online => ui::icon(Ico::Globe, px(14.), lb.attention_text).into_any_element(),
        Tone::Ok => ui::status_dot(lb.success, px(8.)).into_any_element(),
        Tone::Quiet => ui::status_dot(lb.text_tertiary, px(8.)).into_any_element(),
        Tone::Progress(_) => {
            ui::icon(Ico::CircleArrowDown, px(14.), lb.accent_text).into_any_element()
        }
    };
    let progress = match line.tone {
        Tone::Progress(Some(fraction)) => Some(
            div()
                .w(px(140.))
                .flex_none()
                .child(
                    Progress::new(SharedString::from(format!(
                        "settings-status-{}-{}-progress",
                        category.key(),
                        line.id
                    )))
                    .value(fraction * 100.),
                )
                .into_any_element(),
        ),
        _ => None,
    };
    let button = line
        .button_title()
        .zip(line.action.clone())
        .map(|(title, action)| {
            let id = SharedString::from(format!("settings-status-{}-{}", category.key(), line.id));
            let data = data.clone();
            let run =
                move |window: &mut Window, cx: &mut App| perform(&action, &data, &open, window, cx);
            if line.is_link() {
                settings_row::link_button(id, title, run, cx).into_any_element()
            } else {
                Button::new(id)
                    .outline()
                    .small()
                    .label(title)
                    .on_click(move |_, window, cx| run(window, cx))
                    .into_any_element()
            }
        });
    h_flex()
        .w_full()
        .min_h(px(26.))
        .gap(px(9.))
        .items_center()
        .child(
            div()
                .w(px(16.))
                .flex_none()
                .flex()
                .justify_center()
                .child(sign),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(ty::SECONDARY)
                .line_height(px(18.))
                .text_color(if line.tone == Tone::Quiet {
                    lb.text_secondary
                } else {
                    lb.text
                })
                .child(ui::text::paragraph(directional(line.text))),
        )
        .children(progress)
        .children(button)
        .into_any_element()
}

/// A page's open action for the header and Overview rows: select the page
/// and reveal the setting.
pub fn opener(page: &Entity<super::SettingsPage>) -> Opener {
    let page = page.downgrade();
    Rc::new(move |category, focus, window, cx| {
        let Some(page) = page.upgrade() else {
            return;
        };
        page.update(cx, |page, cx| match focus {
            Some(id) if super::catalog::ENTRIES.iter().any(|e| e.id == id) => {
                page.reveal(id, window, cx)
            }
            _ => page.select_category(category, window, cx),
        });
    })
}
