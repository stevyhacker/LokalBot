//! The reviewed cleanup behind retention (`RetentionSettingsControls.swift`):
//! shortening how long screen context lasts, or stopping keeping screen text
//! forever, opens this review first. The policy stays unchanged until it is
//! applied, and what it lists is exactly what goes.

use chrono::{Local, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{WindowExt as _, v_flex};
use gpui_kit::{
    AppContext as _, Context, Entity, FontWeight, ParentElement as _, SharedString, Styled as _,
    Window, div, px,
};
use lokalbot_core::retention::{RetentionReport, RetentionReview, RetentionReviewError};

use super::models::size_label;
use super::{SettingsPage, sync_slider};
use crate::i18n::h_flex;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::controls;

/// A change that deletes something needs a review; one that keeps more doesn't.
pub fn needs_review(current_days: u32, current_forever: bool, days: u32, forever: bool) -> bool {
    days < current_days || (current_forever && !forever)
}

fn local_date_time(at: chrono::DateTime<Utc>) -> String {
    at.with_timezone(&Local)
        .format_localized(
            lokalbot_i18n::date_pattern("%b %-d, %Y, %-I:%M %p"),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}

fn outcome_text(report: &RetentionReport) -> (Option<String>, Option<String>) {
    if report.failures.is_empty() {
        (
            Some(lokalbot_i18n::tr("Retention updated. Reviewed cleanup completed.").to_string()),
            None,
        )
    } else {
        (
            None,
            Some(format!(
                "{}\n{}",
                lokalbot_i18n::format(
                    "Retention updated; {0} moments could not be fully cleaned up.",
                    &[("0", format!("{}", report.failures.len()))],
                ),
                report.failures.join("\n")
            )),
        )
    }
}

impl SettingsPage {
    /// Applies a change that keeps more straight away; any other opens the review.
    pub(super) fn propose_retention(
        &mut self,
        days: u32,
        forever: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let settings = self.data.read(cx).settings.clone();
        if needs_review(
            settings.retention_days,
            settings.keep_ocr_text_forever,
            days,
            forever,
        ) {
            self.load_retention_review(days, forever, None, window, cx);
        } else {
            self.retention_draft = None;
            self.update_settings(
                move |s| {
                    s.retention_days = days;
                    s.keep_ocr_text_forever = forever;
                },
                cx,
            );
        }
    }

    pub(super) fn load_retention_review(
        &mut self,
        days: u32,
        forever: bool,
        error: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let library = self.data.read(cx).library.clone();
        cx.spawn_in(window, async move |this, cx| {
            let review = cx
                .background_spawn(async move {
                    library.retention_review(days, forever, Utc::now(), true)
                })
                .await;
            let _ = this.update_in(cx, |this, window, cx| match review {
                Ok(review) => {
                    this.retention_error = None;
                    this.retention_completion = None;
                    open_sheet(cx.entity(), review, error, window, cx);
                }
                Err(err) => {
                    this.retention_error = Some(format!("{err:#}"));
                    this.reset_retention_draft(window, cx);
                }
            });
        })
        .detach();
    }

    /// Back to the policy in force: the slider only ever previewed a change.
    pub(super) fn reset_retention_draft(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.retention_draft = None;
        let days = self.data.read(cx).settings.retention_days;
        sync_slider(&self.retention_slider, days as f32, window, cx);
        cx.notify();
    }

    fn apply_retention_review(
        &mut self,
        review: RetentionReview,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let library = self.data.read(cx).library.clone();
        let (days, forever) = (review.days, review.keep_text_forever);
        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(
                    async move { library.apply_retention_review(&review, Utc::now()) },
                )
                .await;
            let _ = this.update_in(cx, |this, window, cx| match result {
                Ok(report) => {
                    let (completion, error) = outcome_text(&report);
                    this.retention_completion = completion;
                    this.retention_error = error;
                    this.retention_draft = None;
                    // The policy is set only once its cleanup has run.
                    this.update_settings(
                        move |s| {
                            s.retention_days = days;
                            s.keep_ocr_text_forever = forever;
                        },
                        cx,
                    );
                    this.data
                        .update(cx, |data, cx| data.mark_library_changed(cx));
                    cx.notify();
                }
                Err(err) if err.downcast_ref::<RetentionReviewError>().is_some() => {
                    let message = lokalbot_i18n::tr(
                        "The cleanup scope changed. Review the updated counts before applying it.",
                    );
                    this.load_retention_review(
                        days,
                        forever,
                        Some(message.to_string()),
                        window,
                        cx,
                    );
                }
                Err(err) => {
                    this.retention_error = Some(format!("{err:#}"));
                    this.reset_retention_draft(window, cx);
                }
            });
        })
        .detach();
    }
}

fn open_sheet(
    page: Entity<SettingsPage>,
    review: RetentionReview,
    error: Option<String>,
    window: &mut Window,
    cx: &mut Context<SettingsPage>,
) {
    let bytes = size_label(review.bytes);
    window.open_dialog(cx, move |dialog, _, cx| {
        let lb = cx.lb().clone();
        let policy = lokalbot_i18n::format(
            "Keep images and activity titles for {0} days. {1}",
            &[
                ("0", format!("{}", review.days)),
                (
                    "1",
                    if review.keep_text_forever {
                        lokalbot_i18n::tr("Keep unsaved screen text and metadata indefinitely.")
                    } else {
                        lokalbot_i18n::tr(
                            "Delete unsaved screen text, metadata, and search vectors on the same schedule.",
                        )
                    }
                    .to_string(),
                ),
            ],
        );
        let mut rows: Vec<(&'static str, String)> = vec![
            ("Images to remove", review.pixel_count().to_string()),
            ("Text records to remove", review.text_count().to_string()),
            ("Search vectors to remove", review.vector_count().to_string()),
            ("Screen metadata records to clear", review.metadata_count().to_string()),
            ("Activity titles to clear", review.activity_titles.len().to_string()),
        ];
        if !review.coding_agent_bursts.is_empty() {
            rows.push((
                "Coding agent records to remove",
                review.coding_agent_bursts.len().to_string(),
            ));
        }
        rows.push(("Saved moments preserved", review.saved_count.to_string()));
        rows.push(("Image space recovered", bytes.clone()));
        let range = review.oldest().zip(review.newest()).map(|(first, last)| {
            lokalbot_i18n::format(
                "Affected captures: {0} – {1}",
                &[("0", local_date_time(first)), ("1", local_date_time(last))],
            )
        });
        let apply_page = page.clone();
        let cancel_page = page.clone();
        let approved = review.clone();
        dialog
            .w(px(520.))
            // Only Cancel and Apply end the review: Cancel puts the slider
            // back, which Esc, the X and a click outside would skip.
            .close_button(false)
            .overlay_closable(false)
            .keyboard(false)
            .title(
                div()
                    .text_size(ty::COLUMN_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .child(lokalbot_i18n::tr("Review retention change")),
            )
            .child(
                v_flex()
                    .gap(px(12.))
                    .text_size(ty::BODY)
                    .child(crate::ui::text::paragraph(policy))
                    .child(v_flex().gap(px(6.)).children(rows.into_iter().map(|(label, value)| {
                        h_flex()
                            .gap(px(28.))
                            .child(
                                div()
                                    .flex_1()
                                    .text_color(lb.text)
                                    .child(lokalbot_i18n::tr(label)),
                            )
                            .child(div().text_color(lb.text_secondary).child(value))
                    })))
                    .children(range.map(|range| {
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(range))
                    }))
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Cleanup cannot be undone. The policy stays unchanged until you apply this review. Failed deletions remain visible and can be retried.",
                            ))),
                    )
                    .children(error.clone().map(|error| {
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.attention_text)
                            .child(crate::ui::text::paragraph(SharedString::from(error)))
                    })),
            )
            .footer(
                h_flex()
                    .w_full()
                    .gap_2()
                    .justify_end()
                    .child(
                        controls::bordered("retention-cancel", lokalbot_i18n::tr("Cancel"))
                            .on_click(move |_, window, cx| {
                                window.close_dialog(cx);
                                cancel_page.update(cx, |page, cx| {
                                    page.reset_retention_draft(window, cx)
                                });
                            }),
                    )
                    .child(
                        Button::new("retention-apply")
                            .danger()
                            .label(lokalbot_i18n::tr("Apply policy and cleanup"))
                            .on_click(move |_, window, cx| {
                            window.close_dialog(cx);
                            let approved = approved.clone();
                            apply_page.update(cx, |page, cx| {
                                page.apply_retention_review(approved, window, cx)
                            });
                        }),
                    ),
            )
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_change_that_deletes_needs_a_review() {
        assert!(needs_review(14, false, 7, false));
        assert!(needs_review(14, true, 14, false));
        assert!(!needs_review(14, false, 30, false));
        assert!(!needs_review(14, false, 14, true));
        assert!(!needs_review(14, true, 30, true));
    }

    #[test]
    fn failures_keep_the_policy_message_and_list_what_stayed() {
        let (completion, error) = outcome_text(&RetentionReport::default());
        assert!(completion.is_some() && error.is_none());
        let (completion, error) = outcome_text(&RetentionReport {
            failures: vec!["Moment 4: gone".into()],
            ..RetentionReport::default()
        });
        assert!(completion.is_none());
        assert!(error.unwrap().contains("Moment 4: gone"));
    }
}
