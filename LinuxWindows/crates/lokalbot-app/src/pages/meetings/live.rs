//! The meeting being recorded right now (`LiveMeetingDetailView.swift`,
//! `RecordingHealthStrip.swift`): recording pill, capture health with level
//! meters, the live transcript preview and a notes pad.

use crate::i18n::h_flex;
use gpui_kit::component::input::Textarea;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px,
};

use lokalbot_engine::{LivePreviewCommand, LivePreviewState};

use super::{MeetingsPage, NotesStatus, status_text};
use crate::state::{AppEvent, RecordingState};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

impl MeetingsPage {
    pub(super) fn render_live(
        &mut self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let data = self.data.read(cx);
        let RecordingState::Recording {
            meeting,
            started,
            has_system_audio,
            mic_level,
            system_level,
        } = &data.recording
        else {
            return div().into_any_element();
        };
        let meeting = meeting.clone();
        let elapsed = started.elapsed().as_secs_f64();
        let (has_system, mic, system) = (*has_system_audio, *mic_level, *system_level);
        let phase = (elapsed * 4.).floor() as usize;

        let pill = ui::status_surface(lb.recording, cx)
            .rounded_full()
            .px(px(10.))
            .py(px(4.))
            .flex()
            .items_center()
            .gap(px(6.))
            .child(ui::status_dot(
                lb.recording
                    .opacity(if phase.is_multiple_of(2) { 1. } else { 0.55 }),
                px(7.),
            ))
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.recording_text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Recording"))),
            )
            .child(live_bars(mic.max(system), elapsed, lb.recording_text))
            .child(
                div()
                    .text_size(ty::CAPTION)
                    .text_color(lb.text_secondary)
                    .child(lokalbot_core::time::timer(elapsed)),
            );

        let chip = |icon: Ico, text: String, color: Hsla| {
            h_flex()
                .flex_none()
                .gap(px(5.))
                .items_center()
                .px(px(10.))
                .py(px(4.))
                .rounded_full()
                .bg(lb.chip_fill)
                .text_size(ty::SECONDARY)
                .text_color(color)
                .child(ui::icon(icon, px(13.), color))
                .child(text)
        };
        let header = v_flex()
            .gap(px(14.))
            .child(
                div()
                    .text_size(ty::PAGE_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(meeting.display_title()),
            )
            .child(
                h_flex()
                    .flex_wrap()
                    .gap(px(6.))
                    .items_center()
                    .child(pill)
                    .child(chip(
                        Ico::Calendar,
                        lokalbot_core::time::clock_time(meeting.started_at),
                        lb.supporting,
                    ))
                    .child(chip(Ico::Video, meeting.app_name.clone(), lb.supporting))
                    .child(if has_system {
                        chip(
                            Ico::Volume2,
                            lokalbot_i18n::tr("Mic + system").into(),
                            lb.supporting,
                        )
                    } else {
                        chip(
                            Ico::TriangleAlert,
                            lokalbot_i18n::tr("Mic only").into(),
                            lb.attention_text,
                        )
                    }),
            )
            .child(self.render_health(has_system, mic, system, cx));

        let status = self.live_notes.status.clone();
        let transcript_column = self.render_live_transcript(cx);
        let notes_column = v_flex()
            .w(px(340.))
            .min_w(px(220.))
            .flex_none()
            .min_h_0()
            .gap(px(6.))
            .child(
                div()
                    .text_size(ty::SECTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Meeting Notes",
                    ))),
            )
            .child(
                ui::grouped_surface(cx)
                    .flex_1()
                    .min_h(px(160.))
                    .p(px(6.))
                    .child(
                        Textarea::new(&self.live_notes.input)
                            .large()
                            .appearance(false)
                            .h_full(),
                    ),
            )
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(if matches!(status, NotesStatus::Failed(_)) {
                        lb.attention_text
                    } else {
                        lb.text_secondary
                    })
                    .child(match &status {
                        NotesStatus::Failed(message) => lokalbot_i18n::format(
                            "Not saved: {message}",
                            &[("message", format!("{}", message))],
                        )
                        .into(),
                        other => status_text(other),
                    }),
            );

        v_flex()
            .size_full()
            .px(metric::DETAIL_PADDING)
            .pt(px(8.))
            .pb(px(20.))
            .gap(px(14.))
            .child(header)
            .child(
                h_flex()
                    .flex_1()
                    .min_h_0()
                    .w_full()
                    .gap(px(24.))
                    .items_stretch()
                    .child(transcript_column)
                    .child(notes_column),
            )
            .into_any_element()
    }

    /// `LiveMeetingDetailView.transcriptColumn`: the opt-in preview, its
    /// controls and the rolling, undiarized lines.
    fn render_live_transcript(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let preview = self.data.read(cx).live_preview.clone();
        if preview.lines.len() != self.live_seen_lines {
            if preview.lines.len() > self.live_seen_lines && self.live_follow {
                self.live_scroll.scroll_to_bottom();
            }
            self.live_seen_lines = preview.lines.len();
        }
        let data = self.data.clone();
        let send = move |command: LivePreviewCommand| {
            let data = data.clone();
            move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut gpui_kit::App| {
                data.update(cx, |data, cx| {
                    data.request(AppEvent::LivePreview(command), cx)
                });
            }
        };
        let controls = match &preview.state {
            LivePreviewState::Off => h_flex()
                .gap(px(8.))
                .child(
                    ui::controls::bordered(
                        "live-start-preview",
                        lokalbot_i18n::tr("Start Live Transcript Preview"),
                    )
                    .on_click(send(LivePreviewCommand::Start {
                        from_beginning: false,
                    })),
                )
                .child(
                    ui::controls::bordered(
                        "live-preview-beginning",
                        lokalbot_i18n::tr("From Beginning"),
                    )
                    .on_click(send(LivePreviewCommand::Start {
                        from_beginning: true,
                    })),
                ),
            LivePreviewState::Running => h_flex().child(
                ui::controls::bordered("live-pause-preview", lokalbot_i18n::tr("Pause Preview"))
                    .on_click(send(LivePreviewCommand::Pause)),
            ),
            LivePreviewState::Paused => h_flex().child(
                ui::controls::bordered("live-resume-preview", lokalbot_i18n::tr("Resume Preview"))
                    .on_click(send(LivePreviewCommand::Start {
                        from_beginning: false,
                    })),
            ),
            LivePreviewState::Failed(_) => h_flex().child(
                ui::controls::bordered("live-retry-preview", lokalbot_i18n::tr("Retry Preview"))
                    .on_click(send(LivePreviewCommand::Start {
                        from_beginning: false,
                    })),
            ),
        };
        let note: Option<SharedString> = match &preview.state {
            LivePreviewState::Off => Some(
                lokalbot_i18n::tr("Preview starts with the latest 12 seconds. The full transcript covers the whole recording.")
                    .into(),
            ),
            LivePreviewState::Paused => Some(
                lokalbot_i18n::tr("Preview paused. Recording continues; resume picks up where you left off.").into(),
            ),
            _ => preview.start.filter(|start| *start > 0.).map(|start| {
                lokalbot_i18n::format("Preview starts at {0}. Earlier audio remains in the full recording.", &[("0", clock(start).to_string())])
                .into()
            }),
        };
        let error = match &preview.state {
            LivePreviewState::Failed(message) if !preview.lines.is_empty() => Some(message.clone()),
            _ => None,
        };

        let body = if preview.lines.is_empty() {
            let (icon, title, message): (Ico, &str, SharedString) = match &preview.state {
                LivePreviewState::Off => (
                    Ico::MessageSquareQuote,
                    lokalbot_i18n::tr("Preview is off"),
                    lokalbot_i18n::tr("Start live transcript preview to read along. Recording continues independently.")
                        .into(),
                ),
                LivePreviewState::Paused => (
                    Ico::Pause,
                    lokalbot_i18n::tr("Preview paused"),
                    lokalbot_i18n::tr("Resume preview when you want to read along. Recording continues.").into(),
                ),
                LivePreviewState::Failed(message) => (
                    Ico::TriangleAlert,
                    lokalbot_i18n::tr("Preview interrupted"),
                    message.clone().into(),
                ),
                LivePreviewState::Running => (
                    Ico::AudioLines,
                    lokalbot_i18n::tr("Listening…"),
                    preview
                        .status
                        .clone()
                        .unwrap_or_else(|| lokalbot_i18n::tr("New lines appear as people speak.").into())
                        .into(),
                ),
            };
            div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .child(ui::empty_state(icon, title, message, cx).w_full())
                .into_any_element()
        } else {
            let lines = preview.lines.iter().enumerate().map(|(ix, line)| {
                h_flex()
                    .id(("live-line", ix))
                    .w_full()
                    .gap(px(8.))
                    .items_start()
                    .child(
                        div()
                            .flex_none()
                            .min_w(px(40.))
                            .text_size(ty::SECONDARY)
                            .text_color(lb.accent_text)
                            .child(clock(line.time)),
                    )
                    .child(
                        div()
                            .flex_none()
                            .text_size(ty::CAPTION)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text_secondary)
                            .pt(px(1.))
                            .child(if line.mine {
                                lokalbot_i18n::tr("Me")
                            } else {
                                lokalbot_i18n::tr("Remote speaker")
                            }),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(line.text.clone()),
                    )
            });
            let near_bottom = {
                let offset = self.live_scroll.offset();
                let max = self.live_scroll.max_offset();
                max.y + offset.y < px(80.)
            };
            div()
                .relative()
                .size_full()
                .child(
                    div()
                        .id("live-transcript")
                        .size_full()
                        .overflow_y_scroll()
                        .track_scroll(&self.live_scroll)
                        .on_scroll_wheel(cx.listener(|this, _, _, cx| {
                            let offset = this.live_scroll.offset();
                            let max = this.live_scroll.max_offset();
                            this.live_follow = max.y + offset.y < px(80.);
                            cx.notify();
                        }))
                        .child(v_flex().w_full().p(px(12.)).gap(px(6.)).children(lines)),
                )
                .when(!near_bottom && !self.live_follow, |this| {
                    this.child(
                        div().absolute().bottom(px(8.)).right(px(8.)).child(
                            ui::controls::bordered("live-follow", lokalbot_i18n::tr("Follow Live"))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.live_follow = true;
                                    this.live_scroll.scroll_to_bottom();
                                    cx.notify();
                                })),
                        ),
                    )
                })
                .into_any_element()
        };

        v_flex()
            .flex_1()
            .min_w(px(240.))
            .min_h_0()
            .gap(px(6.))
            .child(
                div()
                    .text_size(ty::SECTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Live Transcript",
                    ))),
            )
            .child(controls)
            .children(note.map(|note| {
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(note)
            }))
            .children(error.map(|error| {
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.attention_text)
                    .child(ui::icon(Ico::TriangleAlert, px(13.), lb.attention_text))
                    .child(error)
            }))
            .child(ui::grouped_surface(cx).flex_1().min_h(px(160.)).child(body))
            .child(
                div()
                    .text_size(ty::CAPTION)
                    .text_color(lb.text_tertiary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Preview — the full transcript and summary arrive after the meeting.",
                    ))),
            )
            .into_any_element()
    }

    fn render_health(
        &self,
        has_system: bool,
        mic: f32,
        system: f32,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let lb = cx.lb().clone();
        // The engine reports each track's state; levels only fill in until
        // its first update arrives.
        let statuses = self
            .data
            .read(cx)
            .recording_statuses
            .clone()
            .map(|(mic, system)| {
                (
                    lokalbot_i18n::tr(&mic).to_string().into(),
                    lokalbot_i18n::tr(&system).to_string().into(),
                )
            });
        let (mic_status, system_status): (SharedString, SharedString) =
            statuses.unwrap_or_else(|| {
                (
                    if mic > 0.01 {
                        lokalbot_i18n::tr("Receiving audio")
                    } else {
                        lokalbot_i18n::tr("Waiting for audio")
                    }
                    .into(),
                    if !has_system {
                        lokalbot_i18n::tr("Not attached")
                    } else if system > 0.01 {
                        lokalbot_i18n::tr("Receiving audio")
                    } else {
                        lokalbot_i18n::tr("Waiting for audio")
                    }
                    .into(),
                )
            });
        let line = |icon: Ico, label: String, level: Option<f32>| {
            h_flex()
                .gap(px(8.))
                .items_center()
                .child(ui::icon(icon, px(14.), lb.text_secondary))
                .child(
                    div()
                        .w(px(220.))
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text)
                        .child(label),
                )
                .when_some(level, |this, level| {
                    this.child(level_meter(level, lb.accent_text, lb.text_secondary))
                })
        };
        ui::grouped_surface(cx)
            .p(px(12.))
            .flex()
            .flex_col()
            .gap(px(6.))
            .child(line(
                Ico::Mic,
                lokalbot_i18n::format(
                    "Mic · {mic_status}",
                    &[("mic_status", format!("{}", mic_status))],
                ),
                Some(mic),
            ))
            .child(line(
                Ico::Volume2,
                lokalbot_i18n::format(
                    "System · {system_status}",
                    &[("system_status", format!("{}", system_status))],
                ),
                has_system.then_some(system),
            ))
    }
}

/// 20 segments, 5×10 each: teal up to the level, faint grey after.
fn level_meter(level: f32, on: Hsla, off: Hsla) -> impl IntoElement {
    let level = level.clamp(0., 1.);
    h_flex().gap(px(3.)).children((0..20).map(move |index| {
        let lit = (index as f32) / 20. < level;
        div()
            .w(px(5.))
            .h(px(10.))
            .rounded(px(2.))
            .bg(if lit { on } else { off.opacity(0.25) })
    }))
}

/// Five small bars that move with the input level (`LiveWaveform`).
pub(super) fn live_bars(level: f32, elapsed: f64, color: Hsla) -> impl IntoElement {
    let level = level.clamp(0.15, 1.);
    h_flex()
        .gap(px(1.5))
        .items_center()
        .h(px(10.))
        .children((0..5).map(move |index| {
            let wave = ((elapsed * 5. + index as f64 * 1.3).sin() * 0.5 + 0.5) as f32;
            let height = 3. + 7. * wave * level;
            div().w(px(2.5)).h(px(height)).rounded_full().bg(color)
        }))
}

/// "4:05", as the macOS preview stamps lines.
fn clock(seconds: f64) -> String {
    let total = seconds.max(0.) as u64;
    format!("{}:{:02}", total / 60, total % 60)
}
