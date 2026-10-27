//! One captured screen moment (`ScreenMomentDetailView.swift`): its image
//! (decrypted in memory, or why it cannot be shown), the window title and
//! captured text, Save Moment and Ask About This, the saved note, capture
//! details, and Delete Moment.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariant};
use gpui_kit::component::input::Input;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, InteractiveElement as _, IntoElement as _,
    ObjectFit, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _,
    StyledImage as _, Window, div, img, px,
};
use lokalbot_core::ScreenMoment;

use super::TimelinePage;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};
use crate::windows::screen_image::{self, ScreenImage};

/// The inspector's image: longest side in pixels.
const THUMBNAIL_PIXELS: u32 = 960;

/// The image of the moment the inspector shows.
pub(super) struct MomentImage {
    pub id: i64,
    /// `None` while it is being decrypted.
    pub image: Option<ScreenImage>,
}

impl TimelinePage {
    /// Decrypts the selected moment's image off the UI thread.
    pub(super) fn load_moment_image(&mut self, moment: &ScreenMoment, cx: &mut Context<Self>) {
        if self
            .moment_image
            .as_ref()
            .is_some_and(|m| m.id == moment.id)
        {
            return;
        }
        self.release_moment_image();
        if moment.path.is_empty() {
            return;
        }
        self.moment_image = Some(MomentImage {
            id: moment.id,
            image: None,
        });
        let library = self.data.read(cx).library.clone();
        let loading = moment.clone();
        let id = moment.id;
        cx.spawn(async move |this, cx| {
            let image = cx
                .background_spawn(async move {
                    screen_image::load(&library, &loading, THUMBNAIL_PIXELS)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if let Some(current) = this.moment_image.as_mut()
                    && current.id == id
                {
                    current.image = Some(image);
                    cx.notify();
                }
            });
        })
        .detach();
    }

    /// Forgets the inspector's image; its texture is freed on the next frame.
    pub(super) fn release_moment_image(&mut self) {
        if let Some(MomentImage {
            image: Some(ScreenImage::Ready(image)),
            ..
        }) = self.moment_image.take()
        {
            self.released_images.push(image);
        }
    }

    pub(super) fn render_moment(
        &self,
        moment: Option<&ScreenMoment>,
        drawer: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let Some(moment) = moment else {
            return v_flex()
                .gap(px(14.))
                .child(self.panel_header(
                    Ico::ScanText,
                    lokalbot_i18n::tr("Screen moment").into(),
                    String::new(),
                    drawer,
                    cx,
                ))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "This moment is no longer kept. It may have been deleted or expired.",
                        ))),
                )
                .into_any_element();
        };
        let when = moment
            .ts
            .with_timezone(&chrono::Local)
            .format_localized(
                lokalbot_i18n::date_pattern("%b %-d, %Y at %-I:%M %p"),
                lokalbot_i18n::date_locale(),
            )
            .to_string();
        let has_pixels = !moment.path.is_empty();
        let header = self.panel_header(
            if has_pixels {
                Ico::Camera
            } else {
                Ico::ScanText
            },
            moment.app.clone().into(),
            when,
            drawer,
            cx,
        );

        let visual: AnyElement = if has_pixels {
            let image = self
                .moment_image
                .as_ref()
                .filter(|m| m.id == moment.id)
                .and_then(|m| m.image.clone());
            let frame = div()
                .w_full()
                .h(px(200.))
                .rounded(metric::GROUP_RADIUS)
                .bg(gpui_kit::black().opacity(0.82))
                .overflow_hidden()
                .flex()
                .items_center()
                .justify_center();
            let ready = matches!(image, Some(ScreenImage::Ready(_)));
            let frame = match image {
                None => frame.child(Spinner::new().color(gpui_kit::white())),
                Some(ScreenImage::Ready(image)) => {
                    frame.child(img(image).size_full().object_fit(ObjectFit::Contain))
                }
                Some(ScreenImage::Unavailable(reason)) => frame.child(
                    v_flex()
                        .w_full()
                        .items_center()
                        .gap(px(6.))
                        .px(px(24.))
                        .child(ui::icon(
                            Ico::ImageOff,
                            px(22.),
                            gpui_kit::white().opacity(0.7),
                        ))
                        .child(
                            div()
                                .w_full()
                                .text_center()
                                .text_size(ty::SECONDARY)
                                .text_color(gpui_kit::white().opacity(0.8))
                                .child(reason),
                        ),
                ),
            };
            let full = moment.clone();
            v_flex()
                .gap(px(8.))
                .child(frame)
                .when(ready, |this| {
                    this.child(
                        h_flex().child(
                            Button::new("moment-full-size")
                                .outline()
                                .small()
                                .icon(Icon::new(Ico::Expand))
                                .label(lokalbot_i18n::tr("View Full Size"))
                                .on_click(move |_, _, cx| screen_image::open(full.clone(), cx)),
                        ),
                    )
                })
                .into_any_element()
        } else {
            h_flex()
                .gap(px(8.))
                .items_center()
                .p(metric::PANEL_PADDING)
                .rounded(metric::GROUP_RADIUS)
                .bg(lb.chip_fill.opacity(0.5))
                .child(ui::icon(Ico::ScanText, px(15.), lb.text_secondary))
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "This moment retained text context without screen pixels.",
                        ))),
                )
                .into_any_element()
        };

        let text = moment.text.clone().unwrap_or_default();
        let long_text = text.chars().count() > 280;
        let shown: String = if self.moment_text_expanded || !long_text {
            text.clone()
        } else {
            let without_title = text
                .strip_prefix(moment.window_title.as_str())
                .map(str::trim_start)
                .filter(|_| !moment.window_title.is_empty())
                .unwrap_or(&text);
            without_title.lines().take(6).collect::<Vec<_>>().join("\n")
        };
        let text_section = (!text.trim().is_empty()).then(|| {
            v_flex()
                .gap(px(6.))
                .p(px(10.))
                .rounded(metric::GROUP_RADIUS)
                .bg(lb.group_fill)
                .border_1()
                .border_color(lb.group_stroke)
                .child(
                    h_flex()
                        .gap(px(6.))
                        .items_center()
                        .child(ui::icon(Ico::TextQuote, px(14.), lb.text))
                        .child(
                            div()
                                .text_size(ty::SECTION)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                    "Text Context",
                                ))),
                        ),
                )
                .child(div().text_size(ty::BODY).text_color(lb.text).child(shown))
                .when(long_text, |this| {
                    let expanded = self.moment_text_expanded;
                    this.child(
                        div()
                            .id("moment-text-toggle")
                            .cursor_pointer()
                            .text_size(ty::SECONDARY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.accent_text)
                            .child(if expanded {
                                lokalbot_i18n::tr("Show Less")
                            } else {
                                lokalbot_i18n::tr("Show Full Captured Text")
                            })
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.moment_text_expanded = !this.moment_text_expanded;
                                cx.notify();
                            })),
                    )
                })
        });

        let id = moment.id;
        let saved = moment.is_saved;
        let save_data = self.data.clone();
        let note_input = self.moment_note.clone();
        let ask_data = self.data.clone();
        let ask_question = lokalbot_i18n::format(
            "What was I looking at in “{0}” at {1}?",
            &[
                (
                    "0",
                    (if moment.window_title.is_empty() {
                        moment.app.as_str()
                    } else {
                        moment.window_title.as_str()
                    })
                    .to_string(),
                ),
                ("1", lokalbot_core::time::clock_time(moment.ts).to_string()),
            ],
        );
        let actions = h_flex()
            .gap(px(8.))
            .flex_wrap()
            .child(
                Button::new("moment-save")
                    .outline()
                    .small()
                    .icon(Icon::new(if saved {
                        Ico::BookmarkCheck
                    } else {
                        Ico::Bookmark
                    }))
                    .label(if saved {
                        lokalbot_i18n::tr("Saved")
                    } else {
                        lokalbot_i18n::tr("Save Moment")
                    })
                    .on_click(move |_, _, cx| {
                        let note = note_input.read(cx).value().to_string();
                        save_data.update(cx, |data, cx| {
                            if saved {
                                data.unsave_screen_moment(id, cx)
                            } else {
                                data.save_screen_moment(id, note, cx)
                            }
                        })
                    }),
            )
            .child(
                Button::new("moment-ask")
                    .outline()
                    .small()
                    .icon(Icon::new(Ico::Sparkles))
                    .label(lokalbot_i18n::tr("Ask About This…"))
                    .on_click(move |_, _, cx| {
                        let question = ask_question.clone();
                        ask_data.update(cx, |data, cx| {
                            data.ask(
                                crate::state::AskRequest {
                                    question,
                                    meeting_ids: Vec::new(),
                                    submit: false,
                                },
                                cx,
                            )
                        })
                    }),
            );

        let saved_note = saved.then(|| {
            let data = self.data.clone();
            let input = self.moment_note.clone();
            let unchanged = self.moment_note.read(cx).value().trim()
                == moment.saved_note.as_deref().unwrap_or_default().trim();
            v_flex()
                .gap(px(6.))
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.supporting)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "Saved until you unsave or delete it.",
                        ))),
                )
                .child(
                    div()
                        .text_size(ty::SECTION)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "Saved Moment Note",
                        ))),
                )
                .child(Input::new(&self.moment_note))
                .child(
                    h_flex().justify_end().child(
                        Button::new("moment-save-note")
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Save Note"))
                            .disabled(unchanged)
                            .on_click(move |_, _, cx| {
                                let note = input.read(cx).value().to_string();
                                data.update(cx, |data, cx| data.save_screen_moment(id, note, cx))
                            }),
                    ),
                )
        });

        let details = self.render_moment_details(moment, cx);
        let delete_data = self.data.clone();
        let delete = h_flex().child(
            Button::new("moment-delete")
                .outline()
                .small()
                .icon(Icon::new(Ico::Trash))
                .label(lokalbot_i18n::tr("Delete Moment…"))
                .on_click(cx.listener(move |_, _, window, cx| {
                    confirm_delete(delete_data.clone(), id, window, cx)
                })),
        );

        v_flex()
            .gap(px(14.))
            .child(header)
            .child(visual)
            .when(!moment.window_title.is_empty(), |this| {
                this.child(
                    div()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .line_clamp(3)
                        .child(moment.window_title.clone()),
                )
            })
            .children(text_section)
            .child(actions)
            .children(saved_note)
            .child(details)
            .child(delete)
            .into_any_element()
    }

    /// "Capture Details": window, trigger, what was kept, provenance.
    fn render_moment_details(&self, moment: &ScreenMoment, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let open = self.moment_details_open;
        let mut rows: Vec<(&'static str, String)> = Vec::new();
        if !moment.window_title.is_empty() {
            rows.push((lokalbot_i18n::tr("Window"), moment.window_title.clone()));
        }
        rows.push((
            lokalbot_i18n::tr("Captured"),
            trigger_label(&moment.capture_trigger),
        ));
        rows.push((
            lokalbot_i18n::tr("Context"),
            if moment.path.is_empty() {
                lokalbot_i18n::tr("Accessible text only").into()
            } else {
                lokalbot_i18n::tr("Accessible text + pixels").into()
            },
        ));
        if !moment.document_name.is_empty() {
            rows.push((lokalbot_i18n::tr("Document"), moment.document_name.clone()));
        }
        if !moment.source_url.is_empty() {
            rows.push((lokalbot_i18n::tr("Source"), moment.source_url.clone()));
        }
        if moment.meeting_id.is_some() {
            rows.push((
                lokalbot_i18n::tr("Meeting"),
                lokalbot_i18n::tr("Linked recording").into(),
            ));
        }
        if moment.privacy_redactions > 0 {
            let count = moment.privacy_redactions;
            rows.push((
                lokalbot_i18n::tr("Privacy"),
                lokalbot_i18n::format("Secrets redacted: {count}", &[("count", count.to_string())]),
            ));
        }
        v_flex()
            .gap(px(8.))
            .child(
                h_flex()
                    .id("moment-details")
                    .gap(px(6.))
                    .items_center()
                    .cursor_pointer()
                    .child(ui::icon(
                        if open {
                            Ico::ChevronDown
                        } else {
                            Ico::ChevronRight
                        },
                        px(12.),
                        lb.text_secondary,
                    ))
                    .child(ui::icon(Ico::Info, px(14.), lb.text))
                    .child(
                        div()
                            .text_size(ty::SECTION)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Capture Details",
                            ))),
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.moment_details_open = !this.moment_details_open;
                        cx.notify();
                    })),
            )
            .when(open, |this| {
                this.child(
                    v_flex()
                        .gap(px(7.))
                        .pl(px(18.))
                        .children(rows.into_iter().map(|(label, value)| {
                            h_flex()
                                .gap(px(12.))
                                .items_start()
                                .child(
                                    div()
                                        .w(px(84.))
                                        .flex_none()
                                        .text_size(ty::BODY)
                                        .text_color(lb.text_secondary)
                                        .child(label),
                                )
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .text_size(ty::BODY)
                                        .text_color(lb.text)
                                        .child(SharedString::from(value)),
                                )
                        })),
                )
            })
            .into_any_element()
    }
}

/// "app_switch" → "App Switch", as the Mac shows `capture_trigger`.
pub(super) fn trigger_label(trigger: &str) -> String {
    trigger
        .split('_')
        .filter(|word| !word.is_empty())
        .map(|word| {
            let mut chars = word.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().chain(chars).collect::<String>())
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn confirm_delete(
    data: gpui_kit::Entity<crate::state::AppData>,
    id: i64,
    window: &mut Window,
    cx: &mut Context<TimelinePage>,
) {
    let timeline = cx.entity().downgrade();
    window.open_alert_dialog(cx, move |alert, _, _| {
        let data = data.clone();
        let timeline = timeline.clone();
        alert
            .title(lokalbot_i18n::tr("Delete this context moment?"))
            .description(lokalbot_i18n::tr(
                "This permanently removes its pixels, captured text, and metadata.",
            ))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Delete context moment"))
            .ok_variant(ButtonVariant::Danger)
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                data.update(cx, |data, cx| data.delete_screen_moment(id, cx));
                let _ = timeline.update(cx, |page, cx| {
                    page.release_moment_image();
                    page.select(None, cx);
                });
                true
            })
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn triggers_read_like_the_mac() {
        assert_eq!(trigger_label("app_switch"), "App Switch");
        assert_eq!(trigger_label("typing_pause"), "Typing Pause");
        assert_eq!(trigger_label("manual"), "Manual");
        assert_eq!(trigger_label(""), "");
    }
}
