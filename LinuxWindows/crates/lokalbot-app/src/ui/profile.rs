//! Pieces shared by People and Projects: section cards with a teal icon,
//! name tints, monograms, relative days and open-work rows.

use crate::i18n::h_flex;
use chrono::{DateTime, Local, NaiveDate, Utc};
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Div, ElementId, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, Pixels, SharedString, Stateful, StatefulInteractiveElement as _,
    Styled as _, Window, div, px,
};
use lokalbot_core::ActionThread;

use super::{Ico, icon};
use crate::theme::{LbThemeExt as _, metric, ty};

/// `WorkspaceSection` with its symbol: teal icon and bold title over a panel.
pub fn section(
    icon_name: Ico,
    title: impl Into<SharedString>,
    content: impl IntoElement,
    cx: &App,
) -> Div {
    let lb = cx.lb();
    v_flex()
        .w_full()
        .gap(metric::HEADER_TO_CONTENT)
        .child(
            h_flex()
                .gap(px(7.))
                .items_center()
                .child(icon(icon_name, px(14.), lb.accent_text))
                .child(
                    div()
                        .text_size(ty::SECTION)
                        .font_weight(FontWeight::BOLD)
                        .text_color(lb.text)
                        .child(title.into()),
                ),
        )
        .child(
            div()
                .w_full()
                .p(metric::PANEL_PADDING)
                .rounded(metric::GROUP_RADIUS)
                .bg(lb.group_fill)
                .border_1()
                .border_color(lb.group_stroke)
                .child(content),
        )
}

/// A quiet line inside an empty section (`EmptyWorkspaceRow`).
pub fn empty_row(text: impl Into<SharedString>, cx: &App) -> Div {
    div()
        .text_size(ty::BODY)
        .text_color(cx.lb().text_secondary)
        .child(text.into())
}

/// A stable color per name, from the speaker palette.
pub fn name_tint(name: &str, cx: &App) -> Hsla {
    let mut hash: u32 = 5381;
    for byte in name.to_lowercase().bytes() {
        hash = hash.wrapping_mul(33).wrapping_add(u32::from(byte));
    }
    cx.lb().speaker(hash as usize % 8)
}

/// Up to two initials.
pub fn initials(name: &str) -> String {
    name.split_whitespace()
        .filter_map(|w| w.chars().next())
        .take(2)
        .collect::<String>()
        .to_uppercase()
}

/// A project's rounded-square monogram (`ProjectMonogram`, radius 0.26× size).
pub fn monogram(name: &str, size: Pixels, cx: &App) -> Div {
    let tint = name_tint(name, cx);
    div()
        .size(size)
        .flex_none()
        .rounded(size * 0.26)
        .bg(tint.opacity(0.16))
        .border_1()
        .border_color(tint.opacity(0.28))
        .flex()
        .items_center()
        .justify_center()
        .text_size(size * 0.38)
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(tint)
        .child(initials(name))
}

/// "today", "yesterday", "3 days ago", then "Oct 3" (`PersonDetailView.relativeDay`).
pub fn relative_day(at: DateTime<Utc>, now: DateTime<Local>) -> String {
    let days = (now.date_naive() - at.with_timezone(&Local).date_naive()).num_days();
    match days {
        ..=0 => lokalbot_i18n::tr("today").into(),
        1 => lokalbot_i18n::tr("yesterday").into(),
        2..=6 => lokalbot_i18n::format("{days} days ago", &[("days", format!("{}", days))]),
        _ => at
            .with_timezone(&Local)
            .format_localized(
                lokalbot_i18n::date_pattern("%b %-d"),
                lokalbot_i18n::date_locale(),
            )
            .to_string(),
    }
}

/// "Oct 8, 2026".
pub fn short_date(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local)
        .format_localized(
            lokalbot_i18n::date_pattern("%b %-d, %Y"),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}

/// "1 meeting" / "3 meetings".
pub fn count(n: usize, noun: &str) -> String {
    lokalbot_i18n::count(n, noun)
}

/// "3h 10m" or "48m" (`ProjectDetailView.duration`).
pub fn duration(seconds: f64) -> String {
    crate::i18n::compact_duration(seconds.max(60.0))
}

/// A link styled like `.workspaceLink`.
pub fn link(
    id: impl Into<ElementId>,
    label: impl Into<SharedString>,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let color = cx.lb().accent_text;
    div()
        .id(id)
        .cursor_pointer()
        .text_size(ty::SECONDARY)
        .text_color(color)
        .hover(|s| s.underline())
        .child(label.into())
        .on_click(move |_, window, cx| on_click(window, cx))
}

/// One open action: text, then owner, due date and where it was said.
/// `open` receives the meeting and transcript moment to show.
pub fn action_row(
    id: impl Into<ElementId>,
    thread: &ActionThread,
    open: impl Fn(uuid::Uuid, Option<f64>, &mut Window, &mut App) + 'static,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let latest = thread.latest();
    let today = Local::now().date_naive();
    let mut meta: Vec<String> = Vec::new();
    if let Some(owner) = thread.owner.as_deref().filter(|o| !o.trim().is_empty()) {
        meta.push(owner.to_string());
    }
    if let Some(due) = thread.due.as_deref().filter(|d| !d.trim().is_empty()) {
        meta.push(lokalbot_i18n::format(
            "due {due}",
            &[("due", due.to_string())],
        ));
    }
    meta.push(latest.meeting_title.clone());
    if thread.meeting_count() > 1 {
        meta.push(count(thread.meeting_count(), "meeting"));
    }
    let overdue = thread.is_overdue(today);
    let meeting_id = latest.meeting_id;
    let at = latest.first_citation().map(|c| c.start);
    h_flex()
        .id(id)
        .w_full()
        .gap(px(10.))
        .items_start()
        .py(px(8.))
        .cursor_pointer()
        .child(
            div()
                .pt(px(2.))
                .child(icon(Ico::Circle, px(15.), lb.text_tertiary)),
        )
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(3.))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .text_color(lb.text)
                        .child(thread.text.clone()),
                )
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(if overdue {
                            lb.attention_text
                        } else {
                            lb.text_secondary
                        })
                        .child(meta.join(" · ")),
                ),
        )
        .on_click(move |_, window, cx| open(meeting_id, at, window, cx))
        .into_any_element()
}

/// Rows separated by hairlines.
pub fn divided(rows: Vec<AnyElement>, cx: &App) -> Div {
    let separator = cx.lb().separator;
    let count = rows.len();
    let mut column = v_flex().w_full();
    for (index, row) in rows.into_iter().enumerate() {
        column = column.child(row);
        if index + 1 < count {
            column = column.child(div().h(px(1.)).w_full().bg(separator));
        }
    }
    column
}

/// The day a project or person was last active, as a key like "Mon, Oct 12".
pub fn day_key_label(key: &str) -> String {
    NaiveDate::parse_from_str(key, "%Y-%m-%d")
        .map(|d| {
            d.format_localized(
                lokalbot_i18n::date_pattern("%a, %b %-d"),
                lokalbot_i18n::date_locale(),
            )
            .to_string()
        })
        .unwrap_or_else(|_| key.to_string())
}

/// A count pill for open work: ↗2 waiting on you, ↙1 waiting on them.
pub fn open_work_pills(you_owe: usize, they_owe: usize, cx: &App) -> Option<Div> {
    if you_owe + they_owe == 0 {
        return None;
    }
    let lb = cx.lb();
    let pill = |n: usize, glyph: Ico, attention: bool| {
        let color = if attention {
            lb.attention_text
        } else {
            lb.text_secondary
        };
        let fill = if attention {
            lb.attention.opacity(0.15)
        } else {
            lb.text_secondary.opacity(0.12)
        };
        h_flex()
            .gap(px(2.))
            .items_center()
            .px(px(6.))
            .py(px(1.))
            .rounded_full()
            .bg(fill)
            .text_size(ty::CAPTION)
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(color)
            .child(icon(glyph, px(10.), color))
            .child(n.to_string())
    };
    Some(
        h_flex()
            .gap(px(4.))
            .flex_none()
            .when(you_owe > 0, |this| {
                this.child(pill(you_owe, Ico::ArrowUpRight, true))
            })
            .when(they_owe > 0, |this| {
                this.child(pill(they_owe, Ico::ArrowDownLeft, false))
            }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    #[test]
    fn relative_days() {
        let now = Local.with_ymd_and_hms(2026, 10, 18, 12, 0, 0).unwrap();
        let at = |d: u32| {
            Local
                .with_ymd_and_hms(2026, 10, d, 9, 0, 0)
                .unwrap()
                .with_timezone(&Utc)
        };
        assert_eq!(relative_day(at(18), now), "today");
        assert_eq!(relative_day(at(17), now), "yesterday");
        assert_eq!(relative_day(at(15), now), "3 days ago");
        assert_eq!(relative_day(at(3), now), "Oct 3");
        assert_eq!(initials("Maya van Dijk"), "MV");
        assert_eq!(duration(3.0 * 3600.0 + 600.0), "3h 10m");
        assert_eq!(duration(20.0), "1m");
    }
}
