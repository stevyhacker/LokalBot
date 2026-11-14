//! The recording in progress, at the top of Today (`TodayLiveCard.swift`):
//! what is being recorded, for how long, whether sound is arriving, and the
//! only Stop on the page.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, Hsla, IntoElement, ParentElement as _, SharedString,
    Styled as _, div, px,
};
use lokalbot_core::Meeting;

use super::{CARD_TITLE, TodayPage, card_surface};
use crate::i18n::h_flex;
use crate::state::RecordingState;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, action_row};

/// Bars in the system-audio meter.
const METER_BARS: usize = 10;

impl TodayPage {
    pub(super) fn render_live_card(
        &self,
        live: Option<&Meeting>,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let meeting = live?;
        let lb = cx.lb().clone();
        let data = self.data.read(cx);
        let RecordingState::Recording {
            started,
            has_system_audio,
            mic_level,
            system_level,
            ..
        } = &data.recording
        else {
            return None;
        };
        let elapsed = started.elapsed().as_secs_f64();
        let has_system = *has_system_audio;
        let (mic_level, system_level) = (*mic_level, *system_level);
        // The engine reports each track's state (Mac words, looked up here);
        // levels fill in until its first report arrives.
        let (mic_status, system_status): (SharedString, SharedString) =
            match data.recording_statuses.clone() {
                Some((mic, system)) => (
                    lokalbot_i18n::tr(&mic).to_string().into(),
                    lokalbot_i18n::tr(&system).to_string().into(),
                ),
                None => (
                    if mic_level > 0.01 {
                        lokalbot_i18n::tr("Receiving audio")
                    } else {
                        lokalbot_i18n::tr("Waiting for audio")
                    }
                    .into(),
                    if !has_system {
                        lokalbot_i18n::tr("Not attached")
                    } else if system_level > 0.01 {
                        lokalbot_i18n::tr("Receiving audio")
                    } else {
                        lokalbot_i18n::tr("Waiting for audio")
                    }
                    .into(),
                ),
            };
        let warnings = data.capture_warnings.clone();
        let id = meeting.id;
        let notes = self.data.clone();
        let stop = self.data.clone();

        let levels = v_flex()
            .gap(px(4.))
            .pt(px(4.))
            .text_size(ty::SECONDARY)
            .child(
                h_flex()
                    .flex_wrap()
                    .gap_x(px(14.))
                    .gap_y(px(4.))
                    .text_color(lb.text_secondary)
                    .child(
                        h_flex()
                            .gap(px(5.))
                            .items_center()
                            .child(ui::icon(Ico::Mic, px(13.), lb.text_secondary))
                            .child(lokalbot_i18n::fill(
                                lokalbot_i18n::tr("Mic · %@"),
                                &[&mic_status],
                            )),
                    )
                    .child(
                        h_flex()
                            .gap(px(5.))
                            .items_center()
                            .child(ui::icon(Ico::Volume2, px(13.), lb.text_secondary))
                            .child(lokalbot_i18n::fill(
                                lokalbot_i18n::tr("System · %@"),
                                &[&system_status],
                            ))
                            .when(has_system, |this| {
                                this.child(meter(system_level, lb.accent_fill, lb.text_secondary))
                            }),
                    ),
            )
            .children(warnings.into_iter().map(|warning| {
                h_flex()
                    .gap(px(6.))
                    .items_start()
                    .child(div().pt(px(2.)).child(ui::icon(
                        Ico::TriangleAlert,
                        px(13.),
                        lb.attention_text,
                    )))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_color(lb.attention_text)
                            .child(ui::text::paragraph(warning)),
                    )
            }));

        let summary = v_flex()
            .flex_1()
            .min_w(px(260.))
            .gap(px(3.))
            .child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.recording_text)
                    .child(ui::status_dot(lb.recording, px(7.)))
                    .child(lokalbot_i18n::tr("Recording"))
                    .child("·")
                    .child(lokalbot_core::time::timer(elapsed)),
            )
            .child(
                div()
                    .w_full()
                    .truncate()
                    .text_size(CARD_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(meeting.display_title()),
            )
            .child(levels);

        let actions = h_flex()
            .flex_none()
            .gap(px(8.))
            .items_center()
            .child(
                ui::controls::bordered("today-live-notes", lokalbot_i18n::tr("Open live notes"))
                    .on_click(move |_, _, cx| action_row::open_meeting(&notes, id, None, cx)),
            )
            .child(
                Button::new("today-live-stop")
                    .secondary()
                    .tooltip(lokalbot_i18n::tr("Stop Recording"))
                    .child(
                        h_flex()
                            .gap(px(6.))
                            .items_center()
                            .child(
                                div()
                                    .flex_none()
                                    .size(px(9.))
                                    .rounded(px(2.))
                                    .bg(lb.recording),
                            )
                            .child(lokalbot_i18n::tr("Stop")),
                    )
                    .on_click(move |_, _, cx| stop.update(cx, |data, cx| data.stop_recording(cx))),
            );

        Some(
            card_surface(Some(lb.recording), cx)
                .child(
                    h_flex()
                        .relative()
                        .w_full()
                        .flex_wrap()
                        .items_center()
                        .gap(px(12.))
                        .px(px(18.))
                        .py(px(16.))
                        .child(summary)
                        .child(actions),
                )
                .into_any_element(),
        )
    }
}

/// Ten small bars, lit up to the system audio's level (`TodayRecordingLevels`).
fn meter(level: f32, on: Hsla, off: Hsla) -> impl IntoElement {
    let level = level.clamp(0., 1.);
    h_flex()
        .gap(px(2.))
        .items_center()
        .children((0..METER_BARS).map(move |index| {
            let lit = (index as f32) / (METER_BARS as f32) < level;
            div()
                .w(px(4.))
                .h(px(9.))
                .rounded(px(1.))
                .bg(if lit { on } else { off.opacity(0.2) })
        }))
}
