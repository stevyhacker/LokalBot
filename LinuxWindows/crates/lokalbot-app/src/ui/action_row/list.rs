//! The action row as the Actions page draws it (`ActionThreadRow` with an
//! `ActionListRowStyle` in `OutcomeOverviewViews.swift`): the page's own
//! source and due wording, a selection the page owns, and status changes the
//! page confirms and keeps in view. The links a row has on other pages live
//! in that page's details pane, so the meta line is plain text here.
//!
//! ```ignore
//! let row = action_row::list_row(
//!     format!("actions-row-{ix}").into(),
//!     thread,
//!     ListRowStyle { source, due, selected, batch, hint, on_click, on_status, on_edit, on_not_mine },
//!     &data,
//!     cx,
//! );
//! ```

use std::rc::Rc;

use crate::i18n::h_flex;
use chrono::Local;
use gpui_kit::component::menu::{ContextMenuExt as _, PopupMenu, PopupMenuItem};
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, ClickEvent, Context, Entity, FontWeight, InteractiveElement as _, IntoElement,
    MouseButton, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _,
    Window, div, px,
};
use lokalbot_core::{ActionStatus, ActionThread};

use super::DueTone;
use super::thread::{open_meeting, set_excluded};
use crate::state::AppData;
use crate::theme::{LbThemeExt as _, metric, ty};

/// A click on a row, with the modifier keys held.
pub(crate) type OnRowClick = Rc<dyn Fn(&ClickEvent, &mut Window, &mut App)>;
/// A status the row asks for.
pub(crate) type OnStatus = Rc<dyn Fn(ActionStatus, &mut Window, &mut App)>;
/// A menu entry that needs the page ("Edit…", "Not mine").
pub(crate) type OnRowAction = Rc<dyn Fn(&mut Window, &mut App)>;

/// What a page passes for each row (`ActionListRowStyle`).
#[derive(Clone)]
pub(crate) struct ListRowStyle {
    /// The meeting it came from, as the page words it; empty for none.
    pub source: String,
    /// The due words and their tone.
    pub due: Option<(String, DueTone)>,
    pub selected: bool,
    /// Several rows are selected: a row's menu shows only under the pointer.
    pub batch: bool,
    /// The evidence beside "Looks done?" ("Mail showed “Message sent” · Mon
    /// 5:48 PM"), when a later screen suggests the action is done.
    pub hint: Option<String>,
    pub on_click: OnRowClick,
    pub on_status: OnStatus,
    pub on_edit: OnRowAction,
    pub on_not_mine: OnRowAction,
}

/// Agent, then each coding agent installed on this computer, by name: the
/// Actions page's "Hand off" (`ActionThreadRow.handOffItems`).
pub(crate) fn hand_off_items(
    menu: PopupMenu,
    thread: &ActionThread,
    data: &Entity<AppData>,
) -> PopupMenu {
    let prompt = lokalbot_core::agent_handoff::agent_prompt_for_thread(thread);
    let agent_data = data.clone();
    let mut menu = menu.item(PopupMenuItem::new(lokalbot_i18n::tr("Agent")).on_click(
        move |_, _, cx| {
            let prompt = prompt.clone();
            agent_data.update(cx, |data, cx| data.open_agent(prompt, cx));
        },
    ));
    for target in crate::agent_handoff::for_actions() {
        let data = data.clone();
        let thread = thread.clone();
        menu = menu.item(PopupMenuItem::new(target.name()).on_click(move |_, _, cx| {
            crate::agent_handoff::hand_off_thread(&data, &thread, target, cx)
        }));
    }
    menu
}

/// The row's "…" menu and its context menu: the same entries (`listMenu`).
/// "Draft next steps…" is left out: this app has no Follow Through.
fn list_menu(
    menu: PopupMenu,
    thread: &ActionThread,
    style: &ListRowStyle,
    data: &Entity<AppData>,
    window: &mut Window,
    cx: &mut Context<PopupMenu>,
) -> PopupMenu {
    let status = thread.status();
    let (done_label, done_next) = if status == ActionStatus::Done {
        (lokalbot_i18n::tr("Mark open"), ActionStatus::Open)
    } else {
        (lokalbot_i18n::tr("Mark Done"), ActionStatus::Done)
    };
    let (defer_label, defer_next) = if status == ActionStatus::Deferred {
        (lokalbot_i18n::tr("Move back to open"), ActionStatus::Open)
    } else {
        (lokalbot_i18n::tr("Defer"), ActionStatus::Deferred)
    };
    let (on_done, on_defer) = (style.on_status.clone(), style.on_status.clone());
    let on_edit = style.on_edit.clone();
    let on_not_mine = style.on_not_mine.clone();
    let open_data = data.clone();
    let meeting_id = thread.latest().meeting_id;
    let menu = menu
        .item(
            PopupMenuItem::new(done_label)
                .on_click(move |_, window, cx| on_done(done_next, window, cx)),
        )
        .item(
            PopupMenuItem::new(defer_label)
                .on_click(move |_, window, cx| on_defer(defer_next, window, cx)),
        )
        .separator()
        .item(
            PopupMenuItem::new(lokalbot_i18n::tr("Edit…"))
                .on_click(move |_, window, cx| on_edit(window, cx)),
        )
        .item(
            PopupMenuItem::new(lokalbot_i18n::tr("Not mine"))
                .on_click(move |_, window, cx| on_not_mine(window, cx)),
        )
        .item(
            PopupMenuItem::new(lokalbot_i18n::tr("Open meeting"))
                .on_click(move |_, _, cx| open_meeting(&open_data, meeting_id, None, cx)),
        );
    let menu = if thread.meeting_count() > 1 {
        let references = thread.references.clone();
        let data = data.clone();
        menu.submenu(
            lokalbot_i18n::tr("Keep as separate action"),
            window,
            cx,
            move |mut menu, _, _| {
                for reference in &references {
                    let day = reference_day(reference.meeting_started_at);
                    let data = data.clone();
                    let (meeting_id, action_id) =
                        (reference.meeting_id, reference.action_id.clone());
                    menu = menu.item(
                        PopupMenuItem::new(format!("{} · {day}", reference.meeting_title))
                            .on_click(move |_, _, cx| {
                                set_excluded(data.clone(), meeting_id, action_id.clone(), true, cx)
                            }),
                    );
                }
                menu
            },
        )
    } else {
        let latest = thread.latest().clone();
        let excluded = latest.is_thread_excluded;
        let label = if excluded {
            lokalbot_i18n::tr("Allow matching across meetings")
        } else {
            lokalbot_i18n::tr("Keep as separate action")
        };
        let data = data.clone();
        menu.item(PopupMenuItem::new(label).on_click(move |_, _, cx| {
            set_excluded(
                data.clone(),
                latest.meeting_id,
                latest.action_id.clone(),
                !excluded,
                cx,
            )
        }))
    };
    let thread = thread.clone();
    let data = data.clone();
    menu.separator().submenu(
        lokalbot_i18n::tr("Hand off"),
        window,
        cx,
        move |menu, _, _| hand_off_items(menu, &thread, &data),
    )
}

/// One row of the Actions list: completion circle, the action, a quiet line
/// with its source and due words, a "Looks done?" line when a later screen
/// suggests it, and the "…" menu on the selected row and under the pointer.
/// A click goes to `style.on_click`; the circle and the menu keep their
/// clicks to themselves. `id` must be unique on the page.
pub(crate) fn list_row(
    id: SharedString,
    thread: &ActionThread,
    style: ListRowStyle,
    data: &Entity<AppData>,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb().clone();
    let status = thread.status();
    let mixed = thread.is_mixed();
    let done = status == ActionStatus::Done && !mixed;

    let toggle = {
        let on_status = style.on_status.clone();
        let next = if status == ActionStatus::Done {
            ActionStatus::Open
        } else {
            ActionStatus::Done
        };
        div()
            .flex_none()
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(super::status_toggle(
                SharedString::from(format!("{id}-toggle")),
                status,
                mixed,
                move |window, cx| on_status(next, window, cx),
                cx,
            ))
    };

    let mut meta: Vec<AnyElement> = Vec::new();
    if !style.source.is_empty() {
        meta.push(
            div()
                .min_w_0()
                .truncate()
                .text_color(lb.text_secondary)
                .child(style.source.clone())
                .into_any_element(),
        );
    }
    if let Some((text, tone)) = style.due.clone() {
        meta.push(
            div()
                .flex_none()
                .text_color(tone.color(cx))
                .child(text)
                .into_any_element(),
        );
    }
    if mixed {
        meta.push(
            div()
                .flex_none()
                .text_color(lb.text_secondary)
                .child(lokalbot_i18n::tr("Mixed status"))
                .into_any_element(),
        );
    }

    let hint = style.hint.clone().map(|evidence| {
        h_flex()
            .min_w_0()
            .gap(px(6.))
            .text_size(ty::SECONDARY)
            .line_height(px(18.))
            .child(
                div()
                    .flex_none()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.accent_text)
                    .child(lokalbot_i18n::tr("Looks done?")),
            )
            .child(
                div()
                    .min_w_0()
                    .flex_1()
                    .truncate()
                    .text_color(lb.text_secondary)
                    .child(evidence),
            )
    });

    // The menu shows on the selected row and under the pointer. It stays in
    // the tree either way, so an open menu is not taken away when the pointer
    // moves onto its items.
    let shows_menu = style.selected && !style.batch;
    let menu = {
        let thread = thread.clone();
        let style = style.clone();
        let data = data.clone();
        let group = id.clone();
        div()
            .flex_none()
            .mt(px(-3.))
            .when(!shows_menu, |this| {
                this.opacity(0.)
                    .group_hover(group, |style| style.opacity(1.))
            })
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(super::options_menu(
                SharedString::from(format!("{id}-menu")),
                move |menu, window, cx| list_menu(menu, &thread, &style, &data, window, cx),
            ))
    };

    let on_click = style.on_click.clone();
    let context_thread = thread.clone();
    let context_style = style.clone();
    let context_data = data.clone();
    h_flex()
        .id(id.clone())
        .group(id)
        .w_full()
        .items_start()
        .gap(px(10.))
        .px(px(10.))
        .py(px(7.))
        .rounded(metric::ROW_RADIUS)
        .cursor_pointer()
        .when(style.selected, |this| this.bg(lb.accent_wash))
        .when(!style.selected, |this| {
            let hover = lb.hover;
            this.hover(move |s| s.bg(hover))
        })
        .child(toggle)
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(2.))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .line_height(px(20.))
                        .text_color(if done { lb.text_secondary } else { lb.text })
                        .when(done, |this| this.line_through())
                        .child(crate::ui::text::paragraph(thread.text.clone())),
                )
                .when(!meta.is_empty(), |this| {
                    this.child(
                        h_flex()
                            .min_w_0()
                            .gap(px(8.))
                            .text_size(ty::SECONDARY)
                            .line_height(px(18.))
                            .children(meta),
                    )
                })
                .children(hint),
        )
        .child(menu)
        .on_click(move |event, window, cx| on_click(event, window, cx))
        .context_menu(move |menu, window, cx| {
            list_menu(
                menu,
                &context_thread,
                &context_style,
                &context_data,
                window,
                cx,
            )
        })
        .into_any_element()
}

/// "Nov 12, 2026" for a moment, on its local day, as a reference's menu entry
/// names it.
fn reference_day(at: chrono::DateTime<chrono::Utc>) -> String {
    at.with_timezone(&Local)
        .format_localized(
            lokalbot_i18n::date_pattern("%b %-d, %Y"),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}
