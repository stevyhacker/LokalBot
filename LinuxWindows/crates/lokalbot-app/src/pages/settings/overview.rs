//! Settings → Overview, opened from the LokalBot row at the top of the list
//! (`SettingsOverview.swift`). A status page: what needs you, each with its
//! own fix, then where your data is, the keyboard shortcuts and the version.
//! Features are turned on and off on their own pages, beside what explains
//! them and asks for consent, so nothing here turns anything on.

use gpui_kit::component::button::Button;
use gpui_kit::component::progress::Progress;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};
use lokalbot_core::Settings;
use lokalbot_core::settings::CotypingAcceptKey;

use super::header::{self, Opener, perform};
use super::status::{Need, SettingsStatus, StatusAction};
use super::{SettingsPage, category_icon};
use crate::i18n::h_flex;
use crate::pages::people::model::{directional, fill};
use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, settings_row};

/// The label of the key that accepts a suggestion.
fn accept_key_label(settings: &Settings) -> String {
    match settings.cotyping_accept_key {
        CotypingAcceptKey::Tab => lokalbot_i18n::tr("Tab").to_string(),
        CotypingAcceptKey::RightArrow => lokalbot_i18n::tr("Right Arrow").to_string(),
    }
}

/// One keyboard shortcut Overview lists: its name, keys, whether it is on,
/// and the page that sets it.
type ShortcutRow = (&'static str, String, bool, Option<SettingsCategory>);

/// The keyboard shortcuts Overview lists: each opens the page that sets it,
/// and one that is off says so. Quick Recall inside LokalBot (Ctrl+K) has
/// no page.
fn shortcut_rows(settings: &Settings) -> Vec<ShortcutRow> {
    vec![
        (
            "Quick Recall",
            settings.quick_recall_shortcut.clone(),
            settings.quick_recall_enabled,
            Some(SettingsCategory::Ask),
        ),
        (
            "Selection actions",
            settings.selection_actions_shortcut.clone(),
            settings.selection_actions_enabled,
            Some(SettingsCategory::Ask),
        ),
        (
            "Dictation",
            settings.dictation_shortcut.clone(),
            settings.dictation_enabled,
            Some(SettingsCategory::Dictation),
        ),
        (
            "Accept a suggestion",
            accept_key_label(settings),
            settings.cotyping_enabled,
            Some(SettingsCategory::Writing),
        ),
        ("Quick Recall in LokalBot", "Ctrl+K".to_string(), true, None),
    ]
}

/// Where things go: each AI server, then phones and tablets.
pub(super) fn leaving(status: &SettingsStatus) -> String {
    let mut places = status.remote_hosts();
    if status.shares_with_devices() {
        places.push(lokalbot_i18n::tr("Phones & tablets").to_string());
    }
    places.join(", ")
}

impl SettingsPage {
    pub(super) fn render_overview(
        &mut self,
        status: &SettingsStatus,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        self.reload_personal(cx);
        self.refresh_library_size(cx);
        let open = header::opener(&cx.entity());
        let settings = self.data.read(cx).settings.clone();
        let (learned, _) = self.personal_counts();

        // What needs you.
        let mut first: Vec<AnyElement> = vec![self.headline(status, cx)];
        for (index, need) in status.needs().iter().enumerate() {
            first.push(self.need_row(index, need, status, open.clone(), cx));
        }
        if !status.models_downloading().is_empty() {
            first.push(self.downloading_row(status, cx));
        }
        if learned > 0 {
            first.push(self.learned_row(learned, open.clone(), cx));
        }

        // Your data.
        let data_rows = vec![
            self.data_row(status, open.clone(), cx),
            self.library_row(false, cx),
            self.models_row(status, open.clone(), cx),
        ];
        let shortcuts = self.shortcut_rows(&settings, open, cx);

        let lb = cx.lb().clone();
        v_flex()
            .id("settings-overview")
            .size_full()
            .items_center()
            .overflow_y_scroll()
            .pt(px(20.))
            .pb(metric::DETAIL_PADDING)
            .child(
                v_flex()
                    .w_full()
                    .max_w(metric::READING_MAX_WIDTH + px(56.))
                    .px(metric::DETAIL_PADDING)
                    .gap(metric::SECTION_SPACING)
                    .child(settings_row::section(None, first, cx))
                    .child(settings_row::section(
                        Some(lokalbot_i18n::tr("Your data").into()),
                        data_rows,
                        cx,
                    ))
                    .child(settings_row::section(
                        Some(lokalbot_i18n::tr("Keyboard shortcuts").into()),
                        shortcuts,
                        cx,
                    ))
                    .child(
                        div()
                            .w_full()
                            .flex()
                            .justify_center()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(lokalbot_i18n::format(
                                "LokalBot {0}",
                                &[("0", env!("CARGO_PKG_VERSION").to_string())],
                            )),
                    ),
            )
            .into_any_element()
    }

    /// The big line on top: how many things need you, or that nothing does.
    fn headline(&self, status: &SettingsStatus, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let (title, detail) = status.headline();
        let attention = status.needs_attention();
        let tint = if attention {
            lb.attention_text
        } else {
            lb.accent_text
        };
        settings_row::content_row(
            "settings-overview-headline",
            h_flex()
                .gap(px(14.))
                .items_center()
                .py(px(4.))
                .child(
                    div()
                        .size(px(42.))
                        .flex_none()
                        .rounded_full()
                        .bg(tint.opacity(0.12))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(ui::icon(
                            if attention {
                                Ico::TriangleAlert
                            } else {
                                Ico::Check
                            },
                            px(19.),
                            tint,
                        )),
                )
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
                                .child(directional(title)),
                        )
                        .child(settings_row::help(directional(detail), cx)),
                ),
            false,
            cx,
        )
        .into_any_element()
    }

    /// A row with a tile, a title over a detail, and something at the right.
    #[allow(clippy::too_many_arguments)]
    fn status_row(
        id: impl Into<gpui_kit::ElementId>,
        icon: Ico,
        tint: Hsla,
        title: String,
        detail: Option<(String, Hsla)>,
        trailing: Option<AnyElement>,
        cx: &App,
    ) -> AnyElement {
        let lb = cx.lb();
        settings_row::content_row(
            id,
            h_flex()
                .gap(px(12.))
                .items_center()
                .child(ui::icon_tile(icon, tint, px(28.)))
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(ui::text::paragraph(title)),
                        )
                        .when_some(detail, |this, (detail, color)| {
                            this.child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .line_height(px(18.))
                                    .text_color(color)
                                    .child(ui::text::paragraph(detail)),
                            )
                        }),
                )
                .children(trailing),
            false,
            cx,
        )
        .into_any_element()
    }

    /// The button of a row's fix, run the same way as a header's.
    fn fix_button(
        id: SharedString,
        title: &'static str,
        action: StatusAction,
        data: &gpui_kit::Entity<crate::state::AppData>,
        open: Opener,
    ) -> AnyElement {
        let data = data.clone();
        Button::new(id)
            .outline()
            .small()
            .label(lokalbot_i18n::tr(title))
            .on_click(move |_, window, cx| perform(&action, &data, &open, window, cx))
            .into_any_element()
    }

    fn need_row(
        &self,
        index: usize,
        need: &Need,
        status: &SettingsStatus,
        open: Opener,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let icon = match need {
            Need::Permission(permission) => permission_icon(permission.name),
            Need::Download { .. } => Ico::CircleArrowDown,
            Need::ModelAttention(_) => Ico::TriangleAlert,
        };
        let (title, action) = status.need_fix(need);
        let button = Self::fix_button(
            SharedString::from(format!("settings-overview-need-{index}")),
            title,
            action,
            &self.data,
            open,
        );
        Self::status_row(
            ("settings-overview-need", index),
            icon,
            lb.attention_text,
            status.need_title(need),
            Some((directional(status.need_detail(need)), lb.text_secondary)),
            Some(button),
            cx,
        )
    }

    fn downloading_row(&self, status: &SettingsStatus, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let names = status
            .models_downloading()
            .iter()
            .map(|m| m.name.clone())
            .collect::<Vec<_>>()
            .join(", ");
        let progress = status.download_fraction().map(|fraction| {
            div()
                .w(px(160.))
                .flex_none()
                .child(Progress::new("settings-overview-progress").value(fraction * 100.))
                .into_any_element()
        });
        Self::status_row(
            "settings-overview-downloading",
            Ico::CircleArrowDown,
            lb.accent_text,
            lokalbot_i18n::tr("Downloading the models").into(),
            Some((names, lb.text_secondary)),
            progress,
            cx,
        )
    }

    /// What LokalBot learned waits for a look, but stops nothing from working.
    fn learned_row(&self, learned: usize, open: Opener, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let button = Self::fix_button(
            "settings-overview-learned".into(),
            "Review…",
            StatusAction::Open(SettingsCategory::PersonalContext, None),
            &self.data,
            open,
        );
        Self::status_row(
            "settings-overview-learned-row",
            category_icon(SettingsCategory::PersonalContext),
            lb.accent_text,
            directional(fill(
                lokalbot_i18n::tr("%lld things LokalBot learned about you are waiting for review."),
                &[&learned.to_string()],
            )),
            None,
            Some(button),
            cx,
        )
    }

    /// Whether everything stays here, or where things go.
    fn data_row(
        &self,
        status: &SettingsStatus,
        open: Opener,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let here = status.everything_stays_here();
        let (title, detail, color) = if here {
            (
                lokalbot_i18n::tr("Everything stays on this PC"),
                lokalbot_i18n::tr("Audio, transcripts and screen text are never uploaded.")
                    .to_string(),
                lb.text_secondary,
            )
        } else {
            (
                lokalbot_i18n::tr("Some things leave this PC"),
                leaving(status),
                lb.attention_text,
            )
        };
        let button = Self::fix_button(
            "settings-overview-privacy".into(),
            if here { "Details…" } else { "Review…" },
            StatusAction::Open(SettingsCategory::Privacy, None),
            &self.data,
            open,
        );
        settings_row::content_row(
            "settings-overview-data",
            h_flex()
                .gap(px(12.))
                .items_center()
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(ui::text::paragraph(title)),
                        )
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .line_height(px(18.))
                                .text_color(color)
                                .child(ui::text::paragraph(detail)),
                        ),
                )
                .child(button),
            false,
            cx,
        )
        .into_any_element()
    }

    /// Where the library is and how much it holds, with a way to open it.
    /// Overview says what is in it; Privacy & permissions names the folder
    /// (`SettingsLibraryRow`).
    pub(super) fn library_row(&self, shows_path: bool, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let root = self.data.read(cx).library.paths().root().to_path_buf();
        let what = if shows_path {
            root.display().to_string()
        } else {
            lokalbot_i18n::tr("Meetings, day memory, and the search index.").to_string()
        };
        let detail = match self.library_size {
            Some(bytes) => format!("{what} · {}", super::files::bytes_label(bytes as f64)),
            None => what,
        };
        let open_root = root.clone();
        settings_row::content_row(
            if shows_path {
                "settings.libraryLocation"
            } else {
                "settings-overview-library"
            },
            h_flex()
                .gap(px(12.))
                .items_center()
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(lokalbot_i18n::tr("Library")),
                        )
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .when(shows_path, |this| this.truncate())
                                .child(detail),
                        ),
                )
                .child(
                    Button::new(if shows_path {
                        "settings-library-open"
                    } else {
                        "settings-overview-library-open"
                    })
                    .outline()
                    .small()
                    .label(lokalbot_i18n::tr("Open Folder"))
                    .on_click(move |_, _, cx| cx.open_with_system(&open_root)),
                ),
            shows_path && self.is_focused("settings.libraryLocation"),
            cx,
        )
        .into_any_element()
    }

    /// Models and their first status line; the row opens Models.
    fn models_row(
        &self,
        status: &SettingsStatus,
        open: Opener,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let line = status
            .lines(SettingsCategory::Models)
            .into_iter()
            .next()
            .map(|line| line.text);
        settings_row::content_row(
            "settings-overview-models",
            h_flex()
                .id("settings-overview-models-open")
                .gap(px(12.))
                .items_center()
                .cursor_pointer()
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(lokalbot_i18n::tr("Models")),
                        )
                        .when_some(line, |this, line| this.child(settings_row::help(line, cx))),
                )
                .child(ui::icon(chevron(), px(12.), lb.text_secondary))
                .on_click(move |_, window, cx| open(SettingsCategory::Models, None, window, cx)),
            false,
            cx,
        )
        .into_any_element()
    }

    /// A shortcut opens the page that sets it. One that is off says so.
    fn shortcut_rows(
        &self,
        settings: &Settings,
        open: Opener,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let lb = cx.lb().clone();
        shortcut_rows(settings)
            .into_iter()
            .enumerate()
            .map(|(index, (title, keys, on, page))| {
                let open = open.clone();
                let row = h_flex()
                    .id(("settings-overview-shortcut", index))
                    .gap(px(10.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::BODY)
                            .text_color(if on { lb.text } else { lb.text_secondary })
                            .child(lokalbot_i18n::tr(title)),
                    )
                    .when(!on, |this| {
                        this.child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(lokalbot_i18n::tr("Off")),
                        )
                    })
                    .child(
                        div()
                            .px(px(7.))
                            .py(px(2.))
                            .rounded(px(5.))
                            .bg(lb.chip_fill)
                            .border_1()
                            .border_color(lb.group_stroke)
                            .text_size(ty::SECONDARY)
                            .text_color(if on { lb.text } else { lb.text_secondary })
                            .child(keys),
                    )
                    .when_some(page, |this, page| {
                        this.cursor_pointer()
                            .on_click(move |_, window, cx| open(page, None, window, cx))
                    });
                settings_row::content_row(("settings-overview-shortcut-row", index), row, false, cx)
                    .into_any_element()
            })
            .collect()
    }
}

/// The glyph of a permission, on Overview and Privacy & permissions.
pub(super) fn permission_icon(name: &str) -> Ico {
    match name {
        "microphone" => Ico::Mic,
        "accessibility" => Ico::AppWindow,
        "screen-recording" => Ico::Monitor,
        "input-monitoring" => Ico::Keyboard,
        "calendar" => Ico::Calendar,
        "credential-store" => Ico::Lock,
        _ => Ico::ShieldCheck,
    }
}

/// The chevron that points into a row, the way the interface reads.
pub(super) fn chevron() -> Ico {
    if lokalbot_i18n::current().rtl {
        Ico::ChevronLeft
    } else {
        Ico::ChevronRight
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shortcuts_open_the_page_that_sets_them_and_say_when_they_are_off() {
        let settings = Settings::default();
        let rows = shortcut_rows(&settings);
        let titles: Vec<&str> = rows.iter().map(|row| row.0).collect();
        assert_eq!(
            titles,
            [
                "Quick Recall",
                "Selection actions",
                "Dictation",
                "Accept a suggestion",
                "Quick Recall in LokalBot"
            ]
        );
        assert_eq!(rows[0].3, Some(SettingsCategory::Ask));
        assert_eq!(rows[2].2, settings.dictation_enabled);
        assert_eq!(rows[4].3, None, "Quick Recall in LokalBot has no page");
    }

    #[test]
    fn what_leaves_names_each_server_then_phones() {
        let settings = Settings {
            companion_sharing_enabled: true,
            ..Default::default()
        };
        let status = SettingsStatus::new(super::super::status::StatusInput {
            settings,
            ..Default::default()
        });
        assert_eq!(leaving(&status), "Phones & tablets");
        assert!(!status.everything_stays_here());
    }
}
