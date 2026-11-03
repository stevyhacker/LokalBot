//! The floating dictation status: a pill at the bottom of the screen while
//! listening, transcribing or composing, or a panel with the live transcript,
//! then a short notice (`DictationOverlayView.swift`,
//! `DictationOverlayContent.swift`). It never takes focus, so text still lands
//! in the app the user is typing in. On Wayland it is a layer surface, which
//! tiling compositors leave out of their layout.

use std::time::Duration;

use crate::i18n::h_flex;
use gpui_kit::component::button::Button;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AnyWindowHandle, App, AppContext as _, Bounds, Context, Entity, FontWeight,
    HighlightStyle, InteractiveElement as _, IntoElement, ParentElement as _, Pixels, Render,
    SharedString, StatefulInteractiveElement as _, Styled as _, StyledText, Subscription, Window,
    WindowBackgroundAppearance, WindowBounds, WindowKind, WindowOptions, div, point, px, size,
};
use lokalbot_engine::{Command, DictationCommand};

use crate::state::{AppData, DictationHud};
use crate::theme::{LbThemeExt as _, Palette, ty};
use crate::ui::{self, Ico};

const PILL: (f32, f32) = (196., 40.);
const STATUS: (f32, f32) = (320., 40.);
const NOTICE: (f32, f32) = (400., 40.);
/// A delivery message too long for one line.
const LONG_NOTICE: (f32, f32) = (460., 64.);
const LONG_NOTICE_CHARACTERS: usize = 56;
const TRANSCRIPT: (f32, f32) = (540., 172.);
const PREPARATION: (f32, f32) = (380., 76.);
/// Space between the pill and the bottom of the screen.
const BOTTOM_MARGIN: f32 = 64.;

/// Opens, resizes or closes the overlay to match `AppData.dictation`.
pub fn sync(cx: &mut App) {
    let data = AppData::global(cx);
    let (state, live_panel, show_overlay) = {
        let data = data.read(cx);
        (
            data.dictation.clone(),
            data.settings.dictation_live_preview,
            data.settings.dictation_show_overlay,
        )
    };
    let existing = cx
        .try_global::<HudWindow>()
        .map(|window| (window.handle, window.dimensions));
    if state == DictationHud::Idle {
        if let Some((window, _)) = existing {
            let _ = window.update(cx, |_, window, _| window.remove_window());
            cx.remove_global::<HudWindow>();
        }
        return;
    }
    let dimensions = dimensions(&state, live_panel);
    match existing {
        Some((_, open)) if open == dimensions => {}
        // Layer surfaces and popups keep the size they opened with.
        Some((window, _)) => {
            let _ = window.update(cx, |_, window, _| window.remove_window());
            cx.remove_global::<HudWindow>();
            if let Some(handle) = open(dimensions, cx) {
                cx.set_global(HudWindow { handle, dimensions });
            }
        }
        None => {
            // The panel with Retry and the notice with Copy are the only way
            // to those, so they show even with the floating status off.
            let essential = matches!(
                state,
                DictationHud::PreparationFailed(_) | DictationHud::Undelivered { .. }
            );
            if !show_overlay && !essential {
                return;
            }
            if let Some(handle) = open(dimensions, cx) {
                cx.set_global(HudWindow { handle, dimensions });
            }
        }
    }
}

struct HudWindow {
    handle: AnyWindowHandle,
    dimensions: (f32, f32),
}

impl gpui_kit::Global for HudWindow {}

fn open((width, height): (f32, f32), cx: &mut App) -> Option<AnyWindowHandle> {
    let size = size(px(width), px(height));
    // On Wayland the pill is a layer surface on the bottom edge: a tiling
    // compositor would otherwise tile it and give it the keyboard, and the
    // dictated text would land in the pill.
    #[cfg(target_os = "linux")]
    if let Some(kind) = crate::windows::layer_surface(
        "lokalbot-dictation",
        gpui_kit::layer_shell::Anchor::BOTTOM,
        Some((px(0.), px(0.), px(BOTTOM_MARGIN), px(0.))),
        gpui_kit::layer_shell::KeyboardInteractivity::None,
    ) {
        let bounds = Bounds {
            origin: point(px(0.), px(0.)),
            size,
        };
        match cx.open_window(options(bounds, kind), |_, cx| cx.new(Hud::new)) {
            Ok(handle) => return Some(handle.into()),
            Err(err) => log::debug!("dictation pill: no layer shell, opening a window: {err:#}"),
        }
    }
    let visible = cx.primary_display()?.bounds();
    let origin = point(
        visible.origin.x + (visible.size.width - size.width) / 2.,
        visible.origin.y + visible.size.height - size.height - px(BOTTOM_MARGIN),
    );
    cx.open_window(
        options(Bounds { origin, size }, WindowKind::PopUp),
        |_, cx| cx.new(Hud::new),
    )
    .ok()
    .map(Into::into)
}

fn options(bounds: Bounds<Pixels>, kind: WindowKind) -> WindowOptions {
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        kind,
        focus: false,
        show: true,
        is_movable: false,
        is_resizable: false,
        window_background: WindowBackgroundAppearance::Transparent,
        app_id: Some(lokalbot_platform::APP_ID.into()),
        ..Default::default()
    }
}

/// The shape for this state. Starting already has the shape recording keeps,
/// so the overlay does not jump when the microphone comes up.
fn dimensions(state: &DictationHud, live_panel: bool) -> (f32, f32) {
    match state {
        DictationHud::Failed(text) | DictationHud::Notice(text)
            if text.chars().count() > LONG_NOTICE_CHARACTERS =>
        {
            LONG_NOTICE
        }
        DictationHud::Notice(_) | DictationHud::Failed(_) | DictationHud::Undelivered { .. } => {
            NOTICE
        }
        DictationHud::Preparing(_) | DictationHud::PreparationFailed(_) => PREPARATION,
        DictationHud::Starting
        | DictationHud::Listening { .. }
        | DictationHud::Transcribing
        | DictationHud::Composing
            if live_panel =>
        {
            TRANSCRIPT
        }
        DictationHud::Transcribing | DictationHud::Composing => STATUS,
        DictationHud::Listening { capture_status, .. } if !capture_status.is_empty() => STATUS,
        _ => PILL,
    }
}

fn close_button(id: &'static str, lb: &Palette, data: Entity<AppData>) -> impl IntoElement + use<> {
    div()
        .id(id)
        .size(px(22.))
        .flex_none()
        .rounded_full()
        .flex()
        .items_center()
        .justify_center()
        .cursor_pointer()
        .hover(|s| s.bg(lb.hover))
        .child(ui::icon(Ico::X, px(12.), lb.text_secondary))
        .on_click(move |_, _, cx| {
            data.update(cx, |data, cx| {
                data.request(crate::state::AppEvent::CancelDictation, cx)
            })
        })
}

fn level_bars(level: f32, count: usize, lb: &Palette) -> impl IntoElement + use<> {
    let accent = lb.accent_text;
    h_flex()
        .h(px(18.))
        .gap(px(3.))
        .items_center()
        .children((0..count).map(move |i| {
            // A gentle shape so the middle bars move more than the edges.
            let center =
                1.0 - ((i as f32 - (count as f32 - 1.0) / 2.0).abs() / (count as f32 / 2.0));
            let height = 3.0 + 15.0 * (level * (0.45 + 0.55 * center)).clamp(0.0, 1.0);
            div().w(px(3.)).h(px(height)).rounded_full().bg(accent)
        }))
}

fn timer_label(elapsed: f64) -> String {
    let seconds = elapsed.max(0.0) as u64;
    format!("{:02}:{:02}", seconds / 60, seconds % 60)
}

struct Hud {
    data: Entity<AppData>,
    _subscription: Subscription,
}

impl Hud {
    fn new(cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let subscription = cx.observe(&data, |_, _, cx| cx.notify());
        // Keep the level bars moving even if no new state arrives.
        cx.spawn(async move |this, cx| {
            loop {
                smol::Timer::after(Duration::from_millis(80)).await;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        })
        .detach();
        Self {
            data,
            _subscription: subscription,
        }
    }

    /// The panel with the live transcript (`transcriptPanel`).
    fn transcript_panel(&self, state: &DictationHud, lb: &Palette, cx: &App) -> AnyElement {
        let transcript = self.data.read(cx).dictation_transcript.clone();
        let (title, placeholder): (&str, &str) = match state {
            DictationHud::Transcribing => ("Finalizing", "Transcribing…"),
            DictationHud::Composing => ("Composing", "Composing…"),
            DictationHud::Listening {
                microphone_live: true,
                ..
            } => ("Dictating", "Listening…"),
            _ => ("Dictating", "Starting the microphone…"),
        };
        let listening = match state {
            DictationHud::Listening {
                level,
                elapsed,
                microphone_live,
                ..
            } => Some((*level, *elapsed, *microphone_live)),
            _ => None,
        };
        let capture_status = match state {
            DictationHud::Listening { capture_status, .. } if !capture_status.is_empty() => {
                Some(capture_status.clone())
            }
            _ => None,
        };
        let dot = match listening {
            Some((_, _, true)) => lb.recording,
            Some(_) | None if matches!(state, DictationHud::Starting) => lb.text_secondary,
            _ => lb.accent_fill,
        };
        let mut body = v_flex()
            .id("hud-transcript")
            .flex_1()
            .min_h_0()
            .w_full()
            .px(px(16.))
            .py(px(12.))
            .overflow_hidden()
            // The newest words stay in view; earlier lines leave at the top.
            .justify_end()
            .text_size(px(16.))
            .line_height(px(22.));
        if transcript.is_empty() {
            body = body.justify_start().child(
                div()
                    .text_color(lb.text_secondary)
                    .child(lokalbot_i18n::tr(placeholder).to_string()),
            );
        } else {
            let (text, ranges) = transcript_text(&transcript);
            let tentative = HighlightStyle {
                color: Some(lb.text_secondary),
                ..HighlightStyle::default()
            };
            let highlights = ranges
                .map(|range| (range, tentative))
                .into_iter()
                .collect::<Vec<_>>();
            body = body.child(
                div()
                    .text_color(lb.text)
                    .child(StyledText::new(text).with_highlights(highlights)),
            );
        }
        v_flex()
            .size_full()
            .rounded(px(16.))
            .bg(lb.elevated)
            .border_1()
            .border_color(lb.separator)
            .font_family(crate::theme::FONT_FAMILY)
            .overflow_hidden()
            .child(
                h_flex()
                    .h(px(44.))
                    .flex_none()
                    .px(px(14.))
                    .gap(px(10.))
                    .items_center()
                    .child(ui::status_dot(dot, px(9.)))
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(if capture_status.is_some() {
                                lb.attention_text
                            } else {
                                lb.text
                            })
                            .child(
                                capture_status
                                    .clone()
                                    .unwrap_or_else(|| lokalbot_i18n::tr(title).to_string().into()),
                            ),
                    )
                    .when_some(listening, |this, (_, elapsed, _)| {
                        this.child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(timer_label(elapsed)),
                        )
                    })
                    .child(div().flex_1().min_w_0())
                    .when_some(
                        listening.filter(|_| capture_status.is_none()),
                        |this, (level, _, live)| {
                            this.child(level_bars(if live { level } else { 0.0 }, 9, lb))
                        },
                    )
                    .child(close_button("hud-close", lb, self.data.clone())),
            )
            .child(div().h(px(1.)).mx(px(14.)).bg(lb.separator))
            .child(body)
            .into_any_element()
    }

    /// The model is loading, or did not load (`preparationPanel`).
    fn preparation_panel(
        &self,
        failure: Option<SharedString>,
        progress: Option<f32>,
        lb: &Palette,
    ) -> AnyElement {
        let failed = failure.is_some();
        let (title, status): (&str, SharedString) = match failure {
            Some(message) => ("Dictation model needs attention", message),
            None => (
                "Preparing the dictation model",
                if progress.is_some() {
                    lokalbot_i18n::tr("Downloading…")
                } else {
                    lokalbot_i18n::tr("Checking the selected speech model…")
                }
                .to_string()
                .into(),
            ),
        };
        h_flex()
            .size_full()
            .pl(px(16.))
            .pr(px(14.))
            .gap(px(10.))
            .items_center()
            .rounded(px(16.))
            .bg(lb.elevated)
            .border_1()
            .border_color(lb.separator)
            .font_family(crate::theme::FONT_FAMILY)
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::SECONDARY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(if failed { lb.attention_text } else { lb.text })
                            .child(lokalbot_i18n::tr(title).to_string()),
                    )
                    .child(
                        div()
                            .line_clamp(2)
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(status),
                    )
                    .when_some(progress, |this, progress| {
                        this.child(
                            gpui_kit::component::progress::Progress::new("hud-preparation")
                                .value(progress * 100.),
                        )
                    }),
            )
            .when(failed, |this| {
                this.child(
                    Button::new("hud-retry")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Retry").to_string())
                        .on_click(|_, _, cx| {
                            crate::bridge::send(
                                Command::Dictation(DictationCommand::RetryPreparation),
                                cx,
                            )
                        }),
                )
            })
            .child(close_button("hud-close", lb, self.data.clone()))
            .into_any_element()
    }

    /// Pasted text the field did not show: offer it again instead of losing it.
    fn undelivered_row(&self, copied: bool, lb: &Palette) -> AnyElement {
        h_flex()
            .size_full()
            .px(px(14.))
            .gap(px(10.))
            .items_center()
            .rounded(px(20.))
            .bg(lb.elevated)
            .border_1()
            .border_color(lb.separator)
            .font_family(crate::theme::FONT_FAMILY)
            .child(ui::icon(
                if copied {
                    Ico::CircleCheck
                } else {
                    Ico::TriangleAlert
                },
                px(14.),
                if copied { lb.accent_text } else { lb.attention },
            ))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(lb.text)
                    .child(
                        lokalbot_i18n::tr(if copied {
                            "Copied to the clipboard"
                        } else {
                            "The text may not have been inserted"
                        })
                        .to_string(),
                    ),
            )
            .when(!copied, |this| {
                this.child(
                    Button::new("hud-copy-notice")
                        .outline()
                        .xsmall()
                        .label(lokalbot_i18n::tr("Copy").to_string())
                        .on_click(|_, _, cx| {
                            crate::bridge::send(
                                Command::Dictation(DictationCommand::CopyNotice),
                                cx,
                            )
                        }),
                )
            })
            .child(
                div()
                    .id("hud-dismiss")
                    .size(px(22.))
                    .flex_none()
                    .rounded_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .hover(|s| s.bg(lb.hover))
                    .child(ui::icon(Ico::X, px(12.), lb.text_secondary))
                    .on_click(|_, _, cx| {
                        crate::bridge::send(Command::Dictation(DictationCommand::DismissNotice), cx)
                    }),
            )
            .into_any_element()
    }
}

/// The transcript's text and the range of its tentative tail.
fn transcript_text(
    transcript: &lokalbot_ai::dictation_preview::LiveTranscript,
) -> (String, Option<std::ops::Range<usize>>) {
    let committed = transcript.committed.as_str();
    let tentative = transcript.tentative.as_str();
    if tentative.is_empty() {
        return (committed.to_string(), None);
    }
    if committed.is_empty() {
        return (tentative.to_string(), Some(0..tentative.len()));
    }
    let start = committed.len() + 1;
    (
        format!("{committed} {tentative}"),
        Some(start..start + tentative.len()),
    )
}

impl Render for Hud {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let (state, live_panel) = {
            let data = self.data.read(cx);
            (data.dictation.clone(), data.settings.dictation_live_preview)
        };
        if dimensions(&state, live_panel) == TRANSCRIPT {
            return self.transcript_panel(&state, &lb, cx);
        }
        match &state {
            DictationHud::Preparing(progress) => {
                return self.preparation_panel(None, *progress, &lb);
            }
            DictationHud::PreparationFailed(message) => {
                return self.preparation_panel(Some(message.clone()), None, &lb);
            }
            DictationHud::Undelivered { copied } => return self.undelivered_row(*copied, &lb),
            _ => {}
        }
        let data = self.data.clone();
        let (label, level): (Option<SharedString>, f32) = match &state {
            DictationHud::Starting => (
                Some(lokalbot_i18n::tr("Starting the microphone…").into()),
                0.0,
            ),
            DictationHud::Listening {
                level,
                capture_status,
                ..
            } => (
                Some(capture_status.clone()).filter(|status| !status.is_empty()),
                *level,
            ),
            DictationHud::Transcribing => (Some(lokalbot_i18n::tr("Transcribing").into()), 0.0),
            DictationHud::Composing => (Some(lokalbot_i18n::tr("Composing").into()), 0.0),
            DictationHud::Notice(text) | DictationHud::Failed(text) => (Some(text.clone()), 0.0),
            _ => (None, 0.0),
        };
        let listening = matches!(state, DictationHud::Listening { .. });
        // A microphone problem replaces the bars with words: the overlay must
        // not look healthy while no audio arrives.
        let mic_problem = listening && label.is_some();
        let failed = matches!(state, DictationHud::Failed(_)) || mic_problem;
        let wrapped = dimensions(&state, live_panel) == LONG_NOTICE;
        h_flex()
            .size_full()
            .px(px(14.))
            .gap(px(10.))
            .items_center()
            .rounded(px(20.))
            .bg(lb.elevated)
            .border_1()
            .border_color(lb.separator)
            .font_family(crate::theme::FONT_FAMILY)
            .child(if listening && !mic_problem {
                ui::status_dot(lb.recording, px(9.))
            } else if failed {
                ui::status_dot(lb.attention, px(9.))
            } else {
                ui::status_dot(lb.accent_fill, px(9.))
            })
            .when(listening && !mic_problem, |this| {
                this.child(div().flex_1().child(level_bars(level, 11, &lb)))
            })
            .when_some(label, |this, label| {
                let text = div()
                    .flex_1()
                    .min_w_0()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(if failed { lb.attention_text } else { lb.text });
                this.child(if wrapped {
                    text.line_clamp(2).child(label)
                } else {
                    text.truncate().child(label)
                })
            })
            .child(close_button("hud-close", &lb, data))
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shape_follows_the_state() {
        let starting = DictationHud::Starting;
        assert_eq!(dimensions(&starting, true), TRANSCRIPT);
        assert_eq!(dimensions(&starting, false), PILL);
        assert_eq!(dimensions(&DictationHud::Transcribing, true), TRANSCRIPT);
        assert_eq!(dimensions(&DictationHud::Transcribing, false), STATUS);
        assert_eq!(
            dimensions(&DictationHud::Preparing(None), true),
            PREPARATION
        );
        assert_eq!(
            dimensions(&DictationHud::Preparing(Some(0.4)), false),
            PREPARATION
        );
        assert_eq!(
            dimensions(
                &DictationHud::Listening {
                    level: 0.0,
                    elapsed: 3.0,
                    microphone_live: false,
                    capture_status: "Waiting for the microphone".into(),
                },
                false
            ),
            STATUS
        );
        assert_eq!(
            dimensions(&DictationHud::Undelivered { copied: false }, true),
            NOTICE
        );
        assert_eq!(
            dimensions(
                &DictationHud::Notice("Copied to the clipboard".into()),
                true
            ),
            NOTICE
        );
        assert_eq!(
            dimensions(
                &DictationHud::Notice(
                    "Dictation finished after focus moved, so the text was copied to the clipboard instead."
                        .into()
                ),
                true
            ),
            LONG_NOTICE
        );
    }

    #[test]
    fn only_the_tentative_tail_is_dimmed() {
        use lokalbot_ai::dictation_preview::LiveTranscript;
        let (text, range) = transcript_text(&LiveTranscript {
            committed: "Hello.".into(),
            tentative: "And then".into(),
        });
        assert_eq!(text, "Hello. And then");
        assert_eq!(&text[range.unwrap()], "And then");
        let (_, range) = transcript_text(&LiveTranscript::final_text("Done."));
        assert_eq!(range, None);
    }

    #[test]
    fn the_timer_reads_minutes_and_seconds() {
        assert_eq!(timer_label(0.4), "00:00");
        assert_eq!(timer_label(75.2), "01:15");
    }
}
