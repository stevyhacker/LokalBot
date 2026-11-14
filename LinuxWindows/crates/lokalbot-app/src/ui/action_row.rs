//! The action row as the Mac draws it everywhere (`ActionThreadRow`,
//! `OutcomeActionRow`, `EvidencePill`, `MeetingPlayTimeButton`): an 18px
//! completion circle, the action, a meta line and the "…" menu.
//!
//! Pages that list action threads use [`thread_row`], which builds the whole
//! row from an `ActionThread` with the Mac's meta line and menu:
//!
//! ```ignore
//! use crate::ui::action_row::{self, ThreadRowOptions};
//!
//! let row = action_row::thread_row(
//!     format!("today-thread-{ix}").into(), // unique on the page
//!     thread,
//!     ThreadRowOptions { hint: hints.get(&thread.id), ..Default::default() },
//!     &data, // Entity<AppData>
//!     cx,
//! );
//! ```
//!
//! Rows of a single meeting's actions (a meeting's Summary) compose the
//! primitives instead: [`status_toggle`], [`meta_link`], [`due_text`] with a
//! [`DueTone`], [`evidence_pill`] or [`play_time`], [`options_menu`] and
//! [`action_row_with`].
//!
//! The Actions page draws the row in its list style with [`list_row`]
//! (`ActionListRowStyle`): its own wording, selection and status handling.

mod list;
mod thread;

pub(crate) use list::{ListRowStyle, OnRowAction, OnRowClick, OnStatus, hand_off_items, list_row};

pub(crate) use thread::{
    ThreadRowOptions, open_in_label, open_meeting, suggests_completion, thread_row,
};

use crate::i18n::h_flex;
use chrono::NaiveDate;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu};
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Div, ElementId, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, Stateful, StatefulInteractiveElement as _, Styled as _,
    Window, div, px, white,
};
use lokalbot_core::{ActionStatus, ActionThread};

use super::{Ico, icon};
use crate::theme::{LbThemeExt as _, metric, ty};

/// The round toggle: open circle, filled teal check when done, minus for a
/// thread whose meetings disagree.
pub fn status_toggle(
    id: impl Into<ElementId>,
    status: ActionStatus,
    mixed: bool,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let lb = cx.lb();
    let size = metric::ACTION_TOGGLE;
    let done = status == ActionStatus::Done && !mixed;
    let tooltip: SharedString = if done {
        lokalbot_i18n::tr("Reopen action").into()
    } else {
        lokalbot_i18n::tr("Mark action done").into()
    };
    let hover_ring = lb.accent_text;
    div()
        .id(id)
        .flex_none()
        .size(size)
        .mt(px(1.))
        .rounded_full()
        .flex()
        .items_center()
        .justify_center()
        .cursor_pointer()
        .when(done, |this| {
            this.bg(lb.accent_fill)
                .child(icon(Ico::Check, px(12.), white()))
        })
        .when(!done, |this| {
            this.border_color(lb.text_secondary)
                .border(px(1.5))
                .hover(move |s| s.border_color(hover_ring))
                .when(mixed, |this| {
                    this.child(
                        div()
                            .w(px(8.))
                            .h(px(1.5))
                            .rounded_full()
                            .bg(lb.text_secondary),
                    )
                })
        })
        .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
        .on_click(move |_, window, cx| on_click(window, cx))
}

/// `EvidencePill`: quote bubble + "00:00:26" in teal; the tooltip is the excerpt.
pub fn evidence_pill(
    id: impl Into<ElementId>,
    seconds: f64,
    excerpt: Option<SharedString>,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let lb = cx.lb();
    let hover = lb.accent_wash;
    let stamp = lokalbot_core::time::stamp(seconds);
    let tooltip: SharedString = excerpt
        .filter(|e| !e.trim().is_empty())
        .map(|e| SharedString::from(format!("“{}”", e.trim())))
        .unwrap_or_else(|| {
            lokalbot_i18n::format(
                "Jump to evidence at {stamp}",
                &[("stamp", stamp.to_string())],
            )
            .into()
        });
    h_flex()
        .id(id)
        .flex_none()
        .gap(px(5.))
        .items_center()
        .px(px(4.))
        .py(px(1.))
        .rounded(px(5.))
        .cursor_pointer()
        .hover(move |style| style.bg(hover))
        .text_size(ty::SECONDARY)
        .text_color(lb.accent_text)
        .child(icon(Ico::MessageSquareQuote, px(14.), lb.accent_text))
        .child(stamp)
        .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
        .on_click(move |_, window, cx| on_click(window, cx))
}

/// How a due date reads in a row: red once it has passed, amber within the
/// week ahead, quiet after that (`ActionThreadRow.dueColor`). Only open work
/// is overdue or due soon; done and deferred work reads quiet.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DueTone {
    Overdue,
    Soon,
    Calm,
}

impl DueTone {
    /// The tone of work due on `due` (its resolved day), seen on `today`.
    /// The week is `DUE_SOON_WINDOW_DAYS`: today through seven days ahead,
    /// the window the attention order uses.
    pub fn of(due: Option<NaiveDate>, open: bool, today: NaiveDate) -> DueTone {
        let Some(due) = due.filter(|_| open) else {
            return DueTone::Calm;
        };
        let soon = today
            .checked_add_days(chrono::Days::new(
                lokalbot_core::actions::DUE_SOON_WINDOW_DAYS,
            ))
            .unwrap_or(today);
        if due < today {
            DueTone::Overdue
        } else if due <= soon {
            DueTone::Soon
        } else {
            DueTone::Calm
        }
    }

    /// A thread is open when any of its meetings still has it open.
    pub fn of_thread(thread: &ActionThread, today: NaiveDate) -> DueTone {
        Self::of(
            thread.resolved_due_date,
            thread.status() == ActionStatus::Open,
            today,
        )
    }

    pub fn color(self, cx: &App) -> gpui_kit::Hsla {
        let lb = cx.lb();
        match self {
            DueTone::Overdue => lb.overdue_text,
            DueTone::Soon => lb.due_soon_text,
            DueTone::Calm => lb.text_secondary,
        }
    }
}

/// The due words in a row's meta line ("Due Thu, Nov 19 · said “Thursday”"),
/// coloured by `tone`. Overdue work also says so to a tooltip, since colour
/// alone carries it.
pub fn due_text(
    id: impl Into<ElementId>,
    text: impl Into<SharedString>,
    tone: DueTone,
    cx: &App,
) -> Stateful<Div> {
    let text: SharedString = text.into();
    let tooltip: Option<SharedString> = (tone == DueTone::Overdue)
        .then(|| format!("{}. {text}", lokalbot_i18n::tr("Overdue")).into());
    div()
        .id(id)
        .flex_none()
        .text_size(ty::SECONDARY)
        .text_color(tone.color(cx))
        .child(text)
        .when_some(tooltip, |this, tooltip| {
            this.tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
        })
}

/// "0:24", or "1:05:03" past an hour (`Transcript.shortStamp`).
pub fn short_stamp(seconds: f64) -> String {
    let total = if seconds.is_finite() {
        seconds.max(0.0) as u64
    } else {
        0
    };
    if total >= 3600 {
        format!(
            "{}:{:02}:{:02}",
            total / 3600,
            (total % 3600) / 60,
            total % 60
        )
    } else {
        format!("{}:{:02}", total / 60, total % 60)
    }
}

/// `MeetingPlayTimeButton`: "▶ 0:24" in teal, opening the meeting playing
/// from there; the tooltip is what was said.
pub fn play_time(
    id: impl Into<ElementId>,
    seconds: f64,
    excerpt: Option<SharedString>,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let lb = cx.lb();
    let hover = lb.accent_wash;
    let stamp = short_stamp(seconds);
    let tooltip: SharedString = excerpt
        .filter(|e| !e.trim().is_empty())
        .map(|e| SharedString::from(format!("“{}”", e.trim())))
        .unwrap_or_else(|| {
            lokalbot_i18n::tr("Play from %@")
                .replace("%@", &stamp)
                .into()
        });
    h_flex()
        .id(id)
        .flex_none()
        .gap(px(4.))
        .items_center()
        .px(px(4.))
        .py(px(1.))
        .rounded(px(5.))
        .cursor_pointer()
        .hover(move |style| style.bg(hover))
        .text_size(ty::SECONDARY)
        .text_color(lb.accent_text)
        .child(icon(Ico::Play, px(9.), lb.accent_text))
        .child(stamp)
        .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
        .on_click(move |_, window, cx| on_click(window, cx))
}

/// Plain metadata text in the row's second line.
pub fn meta_text(text: impl Into<SharedString>, color: gpui_kit::Hsla) -> Div {
    div()
        .flex_none()
        .text_size(ty::SECONDARY)
        .text_color(color)
        .child(text.into())
}

/// A teal metadata link (meeting title, "Mentioned in 3 meetings").
pub fn meta_link(
    id: impl Into<ElementId>,
    text: impl Into<SharedString>,
    leading: Option<Ico>,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let color = cx.lb().accent_text;
    h_flex()
        .id(id)
        .min_w_0()
        .gap(px(4.))
        .items_center()
        .text_size(ty::SECONDARY)
        .text_color(color)
        .cursor_pointer()
        .hover(|style| style.underline())
        .when_some(leading, |this, name| this.child(icon(name, px(13.), color)))
        .child(div().min_w_0().truncate().child(text.into()))
        .on_click(move |_, window, cx| on_click(window, cx))
}

/// Compact due chip with a calendar symbol ("by Thursday").
pub fn due_chip(text: impl Into<SharedString>, overdue: bool, cx: &App) -> Div {
    let lb = cx.lb();
    let color = if overdue {
        lb.attention_text
    } else {
        lb.supporting
    };
    h_flex()
        .flex_none()
        .gap(px(4.))
        .items_center()
        .px(px(7.))
        .py(px(1.))
        .rounded_full()
        .bg(lb.chip_fill)
        .text_size(ty::CAPTION)
        .font_weight(FontWeight::MEDIUM)
        .text_color(color)
        .child(icon(Ico::Calendar, px(12.), color))
        .child(text.into())
}

/// The trailing `ellipsis` menu.
pub fn options_menu(
    id: impl Into<ElementId>,
    build: impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static,
) -> impl IntoElement {
    Button::new(id)
        .ghost()
        .small()
        .icon(Ico::Ellipsis)
        .tooltip(lokalbot_i18n::tr("Options"))
        .dropdown_menu(build)
}

/// One row: toggle, text with its metadata line and optional hint, menu.
pub fn action_row(
    toggle: impl IntoElement,
    text: impl Into<SharedString>,
    done: bool,
    meta: Vec<AnyElement>,
    extra: Option<AnyElement>,
    menu: impl IntoElement,
    cx: &App,
) -> Div {
    action_row_with(
        toggle,
        div().child(text.into()).into_any_element(),
        done,
        meta,
        extra,
        menu,
        cx,
    )
}

/// `action_row` with its text already built (Find marks matches in it).
pub fn action_row_with(
    toggle: impl IntoElement,
    text: AnyElement,
    done: bool,
    meta: Vec<AnyElement>,
    extra: Option<AnyElement>,
    menu: impl IntoElement,
    cx: &App,
) -> Div {
    let lb = cx.lb();
    h_flex()
        .w_full()
        .items_start()
        .gap(px(10.))
        .py(metric::ROW_VERTICAL_PADDING)
        .child(toggle)
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(4.))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .line_height(px(20.))
                        .text_color(if done { lb.text_secondary } else { lb.text })
                        .when(done, |this| this.line_through())
                        .child(text),
                )
                .when(!meta.is_empty(), |this| {
                    this.child(
                        h_flex()
                            .flex_wrap()
                            .gap_x(px(8.))
                            .gap_y(px(2.))
                            .items_center()
                            .children(meta),
                    )
                })
                .children(extra),
        )
        .child(div().flex_none().mt(px(-2.)).child(menu))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{reference, thread};

    fn day(d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 10, d).unwrap()
    }

    #[test]
    fn due_dates_read_red_when_passed_and_amber_within_the_week() {
        let today = day(20);
        assert_eq!(DueTone::of(Some(day(19)), true, today), DueTone::Overdue);
        assert_eq!(DueTone::of(Some(day(20)), true, today), DueTone::Soon);
        assert_eq!(DueTone::of(Some(day(27)), true, today), DueTone::Soon);
        assert_eq!(DueTone::of(Some(day(28)), true, today), DueTone::Calm);
        assert_eq!(DueTone::of(None, true, today), DueTone::Calm);
        // Done and deferred work is never late.
        assert_eq!(DueTone::of(Some(day(1)), false, today), DueTone::Calm);
    }

    #[test]
    fn a_thread_is_late_while_any_meeting_still_has_it_open() {
        let today = day(20);
        let open = thread(vec![
            reference("a", ActionStatus::Done, true, Some(day(10)), 12),
            reference("a", ActionStatus::Open, true, Some(day(10)), 11),
        ]);
        assert_eq!(DueTone::of_thread(&open, today), DueTone::Overdue);
        let deferred = thread(vec![reference(
            "b",
            ActionStatus::Deferred,
            true,
            Some(day(10)),
            11,
        )]);
        assert_eq!(DueTone::of_thread(&deferred, today), DueTone::Calm);
    }

    #[test]
    fn play_times_drop_the_hour_until_there_is_one() {
        assert_eq!(short_stamp(24.9), "0:24");
        assert_eq!(short_stamp(605.0), "10:05");
        assert_eq!(short_stamp(3903.0), "1:05:03");
        assert_eq!(short_stamp(-3.0), "0:00");
        assert_eq!(short_stamp(f64::NAN), "0:00");
    }
}
