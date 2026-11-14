//! Deletes the screen captures retained in a time range of one day
//! (`CaptureRangeDeletionView.swift`). Times snap to captured scenes, and a
//! review lists exactly what will be removed before anything is deleted.

use chrono::{DateTime, Duration, Local, Utc};
use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Disableable as _, Icon, Selectable as _, WindowExt as _, v_flex};
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, IntoElement as _,
    ParentElement as _, Styled as _, Window, div, px,
};
use lokalbot_core::retention::CaptureDeletionReview;
use lokalbot_core::{Library, ScreenMoment};

use super::TimelinePage;
use crate::i18n::h_flex;
use crate::state::AppData;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{Ico, controls, settings_row};

/// The range being chosen, as positions in the day's moments.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct RangeDeletion {
    pub first: usize,
    pub last: usize,
    pub include_saved: bool,
    pub failures: Vec<String>,
}

impl RangeDeletion {
    pub fn new(count: usize) -> Self {
        Self {
            first: 0,
            last: count.saturating_sub(1),
            include_saved: false,
            failures: Vec::new(),
        }
    }

    /// Keeps both ends on a capture that still exists, in order.
    pub fn clamp(&mut self, count: usize) {
        let last = count.saturating_sub(1);
        self.first = self.first.min(last);
        self.last = self.last.min(last).max(self.first);
    }

    /// `[first.ts, last.ts + 1 ms)` (`ScreenRewindSequence.deletionInterval`).
    pub fn interval(&self, moments: &[ScreenMoment]) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
        let first = moments.get(self.first)?.ts;
        let last = moments.get(self.last.max(self.first))?.ts;
        Some((first, last + Duration::milliseconds(1)))
    }

    pub fn selected_count(&self, moments: &[ScreenMoment]) -> usize {
        let Some((start, end)) = self.interval(moments) else {
            return 0;
        };
        moments
            .iter()
            .filter(|m| m.ts >= start && m.ts < end && (self.include_saved || !m.is_saved))
            .count()
    }
}

fn clock(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local)
        .format_localized(
            lokalbot_i18n::date_pattern("%-I:%M:%S %p"),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}

impl TimelinePage {
    /// "Delete screen moments…": a toggle, so it keeps its name while the
    /// range controls are open and reads as on. `None` with nothing kept.
    pub(super) fn range_deletion_toggle(
        &self,
        moments: &[ScreenMoment],
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if moments.is_empty() {
            return None;
        }
        let count = moments.len();
        Some(
            Button::new("timeline-delete-range")
                .outline()
                .small()
                .icon(Icon::new(Ico::Trash))
                .label(lokalbot_i18n::tr("Delete screen moments…"))
                .selected(self.range_deletion.is_some())
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.range_deletion = match this.range_deletion {
                        Some(_) => None,
                        None => Some(RangeDeletion::new(count)),
                    };
                    cx.notify();
                }))
                .into_any_element(),
        )
    }

    /// The range to delete while the toggle is on. Nothing is deleted before
    /// the review lists what goes.
    pub(super) fn render_range_deletion(
        &self,
        moments: &[ScreenMoment],
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if moments.is_empty() {
            return None;
        }
        // The moments can shrink under an open range.
        self.range_deletion.clone().map(|mut range| {
            range.clamp(moments.len());
            self.render_range_controls(&range, moments, cx)
        })
    }

    fn render_range_controls(
        &self,
        range: &RangeDeletion,
        moments: &[ScreenMoment],
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let count = moments.len();
        let selected = range.selected_count(moments);
        let edge = |id: &'static str, position: usize, is_first: bool, cx: &mut Context<Self>| {
            let page = cx.entity();
            let time = moments
                .get(position)
                .map_or_else(String::new, |m| clock(m.ts));
            let (lowest, highest) = if is_first {
                (0, range.last)
            } else {
                (range.first, count - 1)
            };
            settings_row::stepper(
                id,
                time,
                position > lowest,
                position < highest,
                move |step, _, cx| {
                    page.update(cx, |this, cx| {
                        if let Some(range) = this.range_deletion.as_mut() {
                            let next = (position as i64 + i64::from(step))
                                .clamp(lowest as i64, highest as i64)
                                as usize;
                            if is_first {
                                range.first = next;
                            } else {
                                range.last = next;
                            }
                            cx.notify();
                        }
                    })
                },
                cx,
            )
        };
        let from = edge("timeline-range-from", range.first, true, cx);
        let to = edge("timeline-range-to", range.last, false, cx);
        let label = |text: &'static str| {
            div()
                .text_size(ty::CAPTION)
                .text_color(lb.text_secondary)
                .child(lokalbot_i18n::tr(text))
        };
        let interval = range.interval(moments);
        let include_saved = range.include_saved;
        v_flex()
            .gap(px(6.))
            .p(px(8.))
            .rounded(px(8.))
            .bg(lb.attention_text.opacity(0.06))
            .child(
                h_flex()
                    .flex_wrap()
                    .gap(px(7.))
                    .items_center()
                    .child(label("From"))
                    .child(from)
                    .child(label("To"))
                    .child(to)
                    .child(div().flex_1())
                    .child(
                        div()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(super::agent_work::counted(
                                selected,
                                "{count} capture",
                                "{count} captures",
                            )),
                    ),
            )
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(Switch::new("timeline-range-saved").checked(include_saved).on_click(
                        cx.listener(|this, on: &bool, _, cx| {
                            if let Some(range) = this.range_deletion.as_mut() {
                                range.include_saved = *on;
                                cx.notify();
                            }
                        }),
                    ))
                    .child(label("Include saved moments")),
            )
            .child(label(
                "Times snap to the nearest captured scene. Review shows the exact affected moments.",
            ))
            .children(range.failures.iter().map(|failure| {
                div()
                    .text_size(ty::CAPTION)
                    .text_color(lb.attention_text)
                    .child(crate::ui::text::paragraph(failure.clone()))
            }))
            .child(
                h_flex().justify_end().child(
                    Button::new("timeline-range-review")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Review Deletion"))
                        .disabled(selected == 0)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            if let Some((start, end)) = interval {
                                this.load_range_review(start, end, include_saved, window, cx);
                            }
                        })),
                ),
            )
            .into_any_element()
    }

    fn load_range_review(
        &mut self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        include_saved: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let library = self.data.read(cx).library.clone();
        cx.spawn_in(window, async move |this, cx| {
            let review = cx
                .background_spawn(async move {
                    library.capture_deletion_review(start, end, include_saved)
                })
                .await;
            let _ = this.update_in(cx, |this, window, cx| match review {
                Ok(review) => open_review(cx.entity(), this.data.clone(), review, window, cx),
                Err(err) => {
                    if let Some(range) = this.range_deletion.as_mut() {
                        range.failures = vec![lokalbot_i18n::format(
                            "Could not prepare review: {err}",
                            &[("err", format!("{err:#}"))],
                        )];
                    }
                    cx.notify();
                }
            });
        })
        .detach();
    }

    /// Failures stay on screen, with the moments that didn't go still there.
    fn range_deleted(&mut self, failures: Vec<String>, cx: &mut Context<Self>) {
        if failures.is_empty() {
            self.range_deletion = None;
        } else if let Some(range) = self.range_deletion.as_mut() {
            range.failures = failures;
        }
        self.select(Some(super::Selection::RawCapture), cx);
        self.data
            .update(cx, |data, cx| data.mark_library_changed(cx));
        cx.notify();
    }
}

fn run_deletion(library: Library, review: CaptureDeletionReview) -> Vec<String> {
    match library.apply_capture_deletion_review(&review) {
        Ok(failures) => failures,
        Err(err) => vec![format!("{err:#}")],
    }
}

fn open_review(
    page: Entity<TimelinePage>,
    data: Entity<AppData>,
    review: CaptureDeletionReview,
    window: &mut Window,
    cx: &mut App,
) {
    window.open_dialog(cx, move |dialog, _, cx| {
        let lb = cx.lb().clone();
        let page = page.clone();
        let data = data.clone();
        let approved = review.clone();
        let span = format!(
            "{} – {}",
            review
                .start
                .with_timezone(&Local)
                .format_localized(
                    lokalbot_i18n::date_pattern("%b %-d, %Y, %-I:%M:%S %p"),
                    lokalbot_i18n::date_locale(),
                ),
            clock(review.end - Duration::milliseconds(1))
        );
        dialog
            .w(px(470.))
            .title(
                div()
                    .text_size(ty::COLUMN_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .child(lokalbot_i18n::tr("Review capture deletion")),
            )
            .child(
                v_flex()
                    .gap(px(10.))
                    .text_size(ty::BODY)
                    .child(span)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                        "{0} moments, including {1} image records. Their captured text, search vectors and saved notes will also be removed permanently.",
                        &[
                            ("0", format!("{}", review.captures.len())),
                            ("1", format!("{}", review.pixel_count())),
                        ],
                    )))
                    .child(lokalbot_i18n::format(
                        "{0} saved moments excluded · {1} saved moments included",
                        &[
                            ("0", format!("{}", review.saved_excluded)),
                            ("1", format!("{}", review.saved_included())),
                        ],
                    ))
                    .child(
                        div()
                            .text_color(lb.attention_text)
                            .child(lokalbot_i18n::tr("This cannot be undone.")),
                    ),
            )
            .footer(
                h_flex()
                    .w_full()
                    .gap_2()
                    .justify_between()
                    .child(
                        controls::bordered("range-cancel", lokalbot_i18n::tr("Cancel"))
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(
                        Button::new("range-delete")
                            .danger()
                            .label(lokalbot_i18n::tr("Delete reviewed moments"))
                            .disabled(approved.captures.is_empty())
                        .on_click(move |_, window, cx| {
                            window.close_dialog(cx);
                            let library = data.read(cx).library.clone();
                            let review = approved.clone();
                            let page = page.clone();
                            cx.spawn(async move |cx| {
                                let failures = cx
                                    .background_spawn(async move { run_deletion(library, review) })
                                    .await;
                                page.update(cx, |page, cx| page.range_deleted(failures, cx));
                            })
                            .detach();
                        }),
                    ),
            )
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    fn moment(id: i64, second: i64, saved: bool) -> ScreenMoment {
        serde_json::from_value::<ScreenMoment>(serde_json::json!({
            "id": id,
            "ts": Utc.timestamp_opt(1_800_000_000 + second, 0).unwrap(),
            "app": "Editor",
            "window_title": "",
            "capture_trigger": "",
            "text_source": "",
            "path": "",
            "source_url": "",
            "document_name": "",
            "meeting_id": null,
            "privacy_redactions": 0,
            "text": null,
            "saved_note": null,
            "is_saved": saved,
        }))
        .unwrap()
    }

    #[test]
    fn the_range_snaps_to_moments_and_counts_only_what_goes() {
        let moments = vec![
            moment(1, 0, false),
            moment(2, 60, true),
            moment(3, 120, false),
            moment(4, 180, false),
        ];
        let mut range = RangeDeletion::new(moments.len());
        assert_eq!((range.first, range.last), (0, 3));
        assert_eq!(range.selected_count(&moments), 3);
        range.include_saved = true;
        assert_eq!(range.selected_count(&moments), 4);
        range.first = 2;
        range.last = 2;
        let (start, end) = range.interval(&moments).unwrap();
        assert_eq!(start, moments[2].ts);
        assert_eq!(end, moments[2].ts + Duration::milliseconds(1));
        assert_eq!(range.selected_count(&moments), 1);
        range.clamp(1);
        assert_eq!((range.first, range.last), (0, 0));
        assert_eq!(RangeDeletion::new(0).selected_count(&[]), 0);
    }
}
