//! Pieces shared by People and Projects: name tints, the project monogram,
//! relative days, durations and links.

use chrono::{DateTime, Local, Utc};
use gpui_kit::component::v_flex;
use gpui_kit::{
    AnyElement, App, Div, ElementId, FontWeight, Hsla, InteractiveElement as _, ParentElement as _,
    Pixels, SharedString, Stateful, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};

use crate::theme::{LbThemeExt as _, ty};

/// A stable color per name, from the speaker palette.
pub fn name_tint(name: &str, cx: &App) -> Hsla {
    let mut hash: u32 = 5381;
    for byte in name.to_lowercase().bytes() {
        hash = hash.wrapping_mul(33).wrapping_add(u32::from(byte));
    }
    cx.lb().speaker(hash as usize % 8)
}

/// A project's first letter on a rounded square tinted from its name
/// (`ProjectMonogram`, radius 0.26× size). A suggestion, which nobody tracks
/// yet, is a dashed outline.
pub fn monogram(name: &str, size: Pixels, suggestion: bool, cx: &App) -> Div {
    let lb = cx.lb();
    let tint = name_tint(name, cx);
    let letter: String = name
        .trim()
        .chars()
        .next()
        .map(|c| c.to_uppercase().collect())
        .unwrap_or_default();
    let tile = div()
        .size(size)
        .flex_none()
        .rounded(size * 0.26)
        .border_1()
        .flex()
        .items_center()
        .justify_center()
        .text_size(size * 0.46)
        .font_weight(FontWeight::SEMIBOLD)
        .child(letter);
    if suggestion {
        tile.border_dashed()
            .border_color(lb.text_secondary.opacity(0.7))
            .text_color(lb.text_secondary)
    } else {
        tile.bg(tint.opacity(0.16))
            .border_color(tint.opacity(0.28))
            .text_color(tint)
    }
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
        assert_eq!(duration(3.0 * 3600.0 + 600.0), "3h 10m");
        assert_eq!(duration(20.0), "1m");
    }
}
