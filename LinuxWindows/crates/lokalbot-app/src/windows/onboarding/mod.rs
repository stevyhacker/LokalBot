//! First-run setup (`OnboardingView.swift`): three steps under a labelled
//! stepper. Choices stay a draft until setup finishes. The access step only
//! reads what this computer allows, and nothing downloads until Download is
//! pressed. An unfinished setup reopens where it was on the next launch.

mod access;
mod choose;
mod download;
mod resume;

use std::time::Duration;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{TitleBar, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Animation, AnimationExt as _, AnyElement, App, AppContext as _, Bounds, Context, Div, Entity,
    FontWeight, InteractiveElement as _, IntoElement, ParentElement as _, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window, WindowBounds, WindowKind,
    WindowOptions, div, px, size,
};
use lokalbot_core::ScreenContextMode;
use lokalbot_core::settings::{AutoRecordMode, Settings};
use serde::{Deserialize, Serialize};

use crate::state::AppData;
use crate::theme::{LbThemeExt as _, UiFont as _, ty};
use crate::ui::{self, Ico};

/// The Mac's setup window (`OnboardingView.size`).
const WIDTH: f32 = 650.;
const HEIGHT: f32 = 668.;
/// With client decorations on Linux the window's bounds include the shadow
/// GPUI Kit draws around it (20 px a side), so the content gets the Mac's size.
const FRAME: f32 = if cfg!(target_os = "linux") { 40. } else { 0. };

/// Opens the welcome window, or brings it forward.
pub fn open(cx: &mut App) {
    let existing = super::secondary(cx).onboarding;
    if super::activate(existing, cx) {
        return;
    }
    let kind = window_kind(&lokalbot_platform::session::desktop());
    // A floating window's parent is the focused window, and on first launch
    // the main window has only just opened.
    #[cfg(target_os = "linux")]
    if kind == WindowKind::Floating {
        super::when_focused(cx, move |cx| open_window(kind, cx));
        return;
    }
    open_window(kind, cx);
}

/// Hyprland and Sway would tile the welcome window beside the main window.
/// Opened as `Floating`, it gets the main window as its parent, so they
/// float it, centered, at its own size. Other desktops place a normal window
/// themselves.
fn window_kind(desktop: &lokalbot_platform::session::Desktop) -> WindowKind {
    if desktop.tiles_windows() {
        WindowKind::Floating
    } else {
        WindowKind::Normal
    }
}

fn open_window(kind: WindowKind, cx: &mut App) {
    // It may have opened while `open` waited for the main window.
    let existing = super::secondary(cx).onboarding;
    if super::activate(existing, cx) {
        return;
    }
    let bounds = Bounds::centered(None, size(px(WIDTH + FRAME), px(HEIGHT + FRAME)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        kind,
        is_resizable: false,
        is_minimizable: false,
        app_id: Some("com.lokalbot.LokalBot".into()),
        #[cfg(target_os = "linux")]
        window_decorations: Some(gpui_kit::WindowDecorations::Client),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        window.set_window_title(lokalbot_i18n::tr("Welcome to LokalBot"));
        cx.new(|cx| Onboarding::new(window, cx))
    }) {
        Ok((handle, _)) => super::secondary(cx).onboarding = Some(handle),
        Err(err) => log::error!("could not open onboarding: {err:#}"),
    }
}

/// Setup's three steps, in order (`OnboardingStep`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Step {
    Choose,
    Access,
    Download,
}

impl Step {
    const ALL: [Step; 3] = [Step::Choose, Step::Access, Step::Download];

    fn index(self) -> usize {
        Self::ALL.iter().position(|s| *s == self).unwrap_or(0)
    }

    /// The label in the window's stepper.
    fn title(self) -> &'static str {
        match self {
            Step::Choose => lokalbot_i18n::tr("Choose"),
            Step::Access => lokalbot_i18n::tr("Allow access"),
            Step::Download => lokalbot_i18n::tr("Download"),
        }
    }

    fn previous(self) -> Option<Step> {
        self.index().checked_sub(1).map(|ix| Self::ALL[ix])
    }

    fn next(self) -> Option<Step> {
        Self::ALL.get(self.index() + 1).copied()
    }
}

/// `CaptureSetupDraft`: the choices, applied only when setup finishes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Draft {
    meeting_mode: AutoRecordMode,
    day_memory: bool,
    context_mode: ScreenContextMode,
    /// The master switch for reading Claude Code and Codex sessions. The
    /// per-agent switches and folder exclusions stay with Settings.
    coding_agent_sessions: bool,
    /// What a detected call does while Meeting notes is on. The switch
    /// returns to it, so turning it off and on keeps the choice.
    detected_call_mode: AutoRecordMode,
}

/// The two ways a detected call can start a recording.
const DETECTED_CALL_MODES: [AutoRecordMode; 2] = [AutoRecordMode::Automatic, AutoRecordMode::Ask];

impl Draft {
    fn new(settings: &Settings) -> Self {
        Self {
            meeting_mode: settings.auto_record_mode,
            day_memory: settings.tracking_enabled,
            context_mode: settings.screen_context_capture_mode,
            coding_agent_sessions: settings.coding_agent_evidence_enabled,
            detected_call_mode: match settings.auto_record_mode {
                AutoRecordMode::Manual => Self::default_detected_call_mode(),
                mode => mode,
            },
        }
    }

    /// A new install's own choice; setup never picks a different one.
    fn default_detected_call_mode() -> AutoRecordMode {
        match Settings::default().auto_record_mode {
            AutoRecordMode::Manual => AutoRecordMode::Ask,
            mode => mode,
        }
    }

    /// Setup's Meeting notes switch. Off records only on Record.
    fn records_detected_calls(&self) -> bool {
        self.meeting_mode != AutoRecordMode::Manual
    }

    fn set_records_detected_calls(&mut self, on: bool) {
        self.meeting_mode = if on {
            self.detected_call_mode
        } else {
            AutoRecordMode::Manual
        };
    }

    fn set_meeting_mode(&mut self, mode: AutoRecordMode) {
        self.meeting_mode = mode;
        if mode != AutoRecordMode::Manual {
            self.detected_call_mode = mode;
        }
    }

    /// Screen context the draft would turn on.
    fn screen_context(&self) -> ScreenContextMode {
        if self.day_memory {
            self.context_mode
        } else {
            ScreenContextMode::ActivityOnly
        }
    }

    fn reads_screen_text(&self) -> bool {
        self.screen_context() != ScreenContextMode::ActivityOnly
    }

    fn takes_screenshots(&self) -> bool {
        self.screen_context() == ScreenContextMode::TextAndVisual
    }

    /// Writes the fields this window owns.
    fn apply(&self, settings: &mut Settings) {
        settings.auto_record_mode = self.meeting_mode;
        settings.tracking_enabled = self.day_memory;
        settings.screen_context_capture_mode = self.screen_context();
        // Setup shows this choice, so finishing it is the person's answer.
        crate::pages::settings::choose_coding_agents(settings, self.coding_agent_sessions);
    }
}

pub struct Onboarding {
    data: Entity<AppData>,
    step: Step,
    /// Direction of the last step change, so the page arrives from that side.
    forward: bool,
    draft: Draft,
    /// The choices the settings held when this draft was started.
    baseline: Draft,
    download: download::Session,
    /// The access checks are running in the background.
    checking: bool,
    /// False once setup has finished, so nothing more is saved for it.
    saves: bool,
    _subscriptions: Vec<Subscription>,
}

impl Onboarding {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let (settings, root) = {
            let data = data.read(cx);
            (
                data.settings.clone(),
                data.library.paths().root().to_path_buf(),
            )
        };
        let subscriptions = vec![cx.observe_in(&data, window, |this, _, _, cx| {
            this.download_changed(cx);
            cx.notify();
        })];
        let baseline = Draft::new(&settings);
        // A finished setup has nothing to resume: the port never reopens one
        // after a restart it asked for.
        let saved = if settings.onboarding_completed {
            resume::clear(&root);
            None
        } else {
            resume::load(&root, &baseline)
        };
        let mut download = download::Session::default();
        let (step, draft) = match saved {
            Some(saved) => {
                download.include_autocomplete = saved.include_autocomplete;
                download.opens_sample_meeting = saved.opens_sample_meeting;
                (saved.step, saved.draft)
            }
            None => (Step::Choose, baseline),
        };
        let mut this = Self {
            data,
            step,
            forward: true,
            draft,
            baseline,
            download,
            checking: false,
            saves: true,
            _subscriptions: subscriptions,
        };
        this.start_checks(cx);
        this
    }

    fn library_root(&self, cx: &App) -> std::path::PathBuf {
        self.data.read(cx).library.paths().root().to_path_buf()
    }

    fn go(&mut self, step: Step, cx: &mut Context<Self>) {
        self.forward = step > self.step;
        self.step = step;
        self.start_checks(cx);
        self.save(cx);
        cx.notify();
    }

    fn set_draft(&mut self, change: impl FnOnce(&mut Draft), cx: &mut Context<Self>) {
        change(&mut self.draft);
        self.save(cx);
        cx.notify();
    }

    /// Saves where setup is, so a relaunch reopens it here.
    fn save(&self, cx: &App) {
        if !self.saves {
            return;
        }
        resume::save(
            &self.library_root(cx),
            &resume::ResumeState {
                step: self.step,
                draft: self.draft,
                baseline: self.baseline,
                include_autocomplete: self.download.include_autocomplete,
                opens_sample_meeting: self.download.opens_sample_meeting,
            },
        );
    }

    /// Reads what this computer allows, away from the UI thread, and again
    /// every few seconds while the access step shows (`startPolling`). The
    /// reading is `AppData`'s, the one Settings shows.
    fn start_checks(&mut self, cx: &mut Context<Self>) {
        if self.checking {
            return;
        }
        self.checking = true;
        cx.spawn(async move |this, cx| {
            loop {
                let again = this
                    .update(cx, |this, cx| {
                        this.data.update(cx, |data, cx| data.refresh_access(cx));
                        let again = this.step == Step::Access;
                        if again {
                            this.data
                                .update(cx, |data, cx| data.refresh_audio_inputs(cx));
                        } else {
                            this.checking = false;
                        }
                        again
                    })
                    .unwrap_or(false);
                if !again {
                    return;
                }
                cx.background_executor().timer(Duration::from_secs(3)).await;
            }
        })
        .detach();
    }

    /// Applies the choices and ends setup. The sample meeting opens only
    /// when the person saw that option, which is once a download exists.
    fn finish(&mut self, opens_sample_meeting: bool, window: &mut Window, cx: &mut Context<Self>) {
        self.saves = false;
        let draft = self.draft;
        resume::clear(&self.library_root(cx));
        self.data.update(cx, |data, cx| {
            data.update_settings(
                |s| {
                    draft.apply(s);
                    s.onboarding_completed = true;
                },
                cx,
            );
            if opens_sample_meeting {
                download::open_sample_when_ready(data, cx);
            }
        });
        super::secondary(cx).onboarding = None;
        window.remove_window();
    }

    fn render_stepper(&self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let current = self.step;
        let mut row = h_flex().gap(px(9.)).items_center();
        for step in Step::ALL {
            if step != Step::Choose {
                row = row.child(
                    div()
                        .w(px(26.))
                        .h(px(1.5))
                        .flex_none()
                        .bg(if step <= current {
                            lb.accent_fill
                        } else {
                            lb.separator
                        }),
                );
            }
            let number = SharedString::from(lokalbot_i18n::number(step.index() + 1));
            let marker = if step < current {
                div()
                    .size(px(18.))
                    .flex_none()
                    .rounded_full()
                    .bg(lb.accent_text.opacity(0.14))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(ui::icon(Ico::Check, px(11.), lb.accent_text))
            } else if step == current {
                div()
                    .size(px(18.))
                    .flex_none()
                    .rounded_full()
                    .bg(lb.accent_fill)
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(10.5))
                    .font_weight(FontWeight::BOLD)
                    .text_color(gpui_kit::white())
                    .child(number)
            } else {
                div()
                    .size(px(18.))
                    .flex_none()
                    .rounded_full()
                    .border_1()
                    .border_color(lb.text_tertiary)
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(10.5))
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text_secondary)
                    .child(number)
            };
            let item = h_flex().gap(px(6.)).items_center().child(marker).child(
                div()
                    .text_size(ty::SECONDARY)
                    .whitespace_nowrap()
                    .font_weight(if step == current {
                        FontWeight::SEMIBOLD
                    } else {
                        FontWeight::NORMAL
                    })
                    .text_color(if step == current {
                        lb.text
                    } else {
                        lb.text_secondary
                    })
                    .child(step.title()),
            );
            // A finished step goes back to it.
            row = row.child(if step < current {
                div()
                    .id(SharedString::from(format!(
                        "onboarding-step-{}",
                        step.index() + 1
                    )))
                    .cursor_pointer()
                    .rounded(px(6.))
                    .px(px(4.))
                    .py(px(2.))
                    .hover(|style| style.bg(lb.hover))
                    .child(item)
                    .on_click(cx.listener(move |this, _, _, cx| this.go(step, cx)))
                    .into_any_element()
            } else {
                div().px(px(4.)).py(px(2.)).child(item).into_any_element()
            });
        }
        row
    }

    fn render_footer(&mut self, plan: Option<&download::Plan>, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let step = self.step;
        let mut footer = h_flex()
            .h(px(56.))
            .flex_none()
            .px(px(20.))
            .gap(px(10.))
            .items_center();
        let back = Button::new("onboarding-back")
            .outline()
            .label(lokalbot_i18n::tr("Back"))
            .on_click(cx.listener(move |this, _, _, cx| {
                if let Some(previous) = step.previous() {
                    this.go(previous, cx);
                }
            }));
        let continue_button = Button::new("onboarding-continue")
            .primary()
            .label(lokalbot_i18n::tr("Continue"))
            .on_click(cx.listener(move |this, _, _, cx| {
                if let Some(next) = step.next() {
                    this.go(next, cx);
                }
            }));
        match step {
            Step::Choose => {
                footer = footer
                    .child(
                        h_flex()
                            .gap(px(6.))
                            .items_center()
                            .child(ui::icon(Ico::Globe, px(14.), lb.text_secondary))
                            .child(crate::i18n::language_picker("onboarding-language", cx)),
                    )
                    .child(div().flex_1().min_w(px(8.)))
                    .child(continue_button);
            }
            Step::Access => {
                let rows = self.access_rows(cx);
                footer = footer
                    .when_some(access::allowed_count(&rows), |this, (allowed, of)| {
                        this.child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(crate::pages::ask::model::directional(
                                    &crate::pages::ask::model::mac(
                                        "%lld of %lld allowed",
                                        &[
                                            &lokalbot_i18n::number(allowed),
                                            &lokalbot_i18n::number(of),
                                        ],
                                    ),
                                )),
                        )
                    })
                    .child(div().flex_1().min_w(px(8.)))
                    .child(back)
                    .child(continue_button);
            }
            Step::Download => {
                if let Some(plan) = plan {
                    footer = self.download_footer(footer, back, plan, cx);
                }
            }
        }
        footer
    }
}

impl Render for Onboarding {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        window.set_window_title(lokalbot_i18n::tr("Welcome to LokalBot"));
        let lb = cx.lb().clone();
        let step = self.step;
        let plan = (step == Step::Download).then(|| self.plan(cx));
        let body: AnyElement = match step {
            Step::Choose => self.render_choose(cx).into_any_element(),
            Step::Access => self.render_access(cx).into_any_element(),
            Step::Download => match &plan {
                Some(plan) => self.render_download(plan, cx).into_any_element(),
                None => div().into_any_element(),
            },
        };
        let footer = self.render_footer(plan.as_ref(), cx);
        let travel = if self.forward { 24. } else { -24. };
        v_flex()
            .size_full()
            .ui_font()
            .text_align(crate::i18n::interface_alignment())
            .bg(lb.window)
            .text_color(lb.text)
            .child(
                // The steps share the title bar, as on the Mac.
                TitleBar::new()
                    .bg(lb.title_bar)
                    .border_color(lb.separator)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .justify_center()
                            .child(self.render_stepper(cx)),
                    ),
            )
            .child(
                div()
                    .id("onboarding-body")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .child(
                        div()
                            .px(px(44.))
                            .pt(px(16.))
                            .pb(px(16.))
                            .w_full()
                            .child(body)
                            .with_animation(
                                SharedString::from(format!("onboarding-step-{}", step.index())),
                                Animation::new(Duration::from_millis(250)),
                                move |element, delta| {
                                    element.left(px(travel * (1. - delta))).opacity(delta)
                                },
                            ),
                    ),
            )
            .child(ui::divider(cx))
            .child(footer)
    }
}

// ------------------------------------------------------------ shared parts

/// A step's title with one lead sentence, centred (`OnboardingHeading`).
fn heading(title: &'static str, lead: Option<String>, cx: &App) -> Div {
    let lb = cx.lb();
    v_flex()
        .w_full()
        .items_center()
        .gap(px(7.))
        .child(
            div()
                .text_center()
                .text_size(px(23.))
                .font_weight(FontWeight::BOLD)
                .text_color(lb.text)
                .child(ui::text::paragraph(title)),
        )
        .when_some(lead, |this, lead| {
            this.child(
                div()
                    .max_w(px(480.))
                    .text_center()
                    .text_size(px(14.))
                    .line_height(px(20.))
                    .text_color(lb.text_secondary)
                    .child(ui::text::paragraph(lead)),
            )
        })
}

/// Rows in one grouped card; callers put `divider` between rows.
fn card(cx: &App) -> Div {
    ui::grouped_surface(cx).w_full().flex().flex_col()
}

/// One card row: a symbol tile, its text, and a control or state at the end
/// (`OnboardingRow`).
fn row(
    symbol: Ico,
    top: bool,
    detail: impl IntoElement,
    trailing: Option<AnyElement>,
    cx: &App,
) -> Div {
    let lb = cx.lb();
    h_flex()
        .w_full()
        .min_h(px(56.))
        .px(px(14.))
        .py(px(9.))
        .gap(px(12.))
        .map(|this| {
            if top {
                this.items_start()
            } else {
                this.items_center()
            }
        })
        .child(ui::icon_tile(symbol, lb.accent_text, px(30.)))
        .child(v_flex().flex_1().min_w_0().gap(px(2.)).child(detail))
        .when_some(trailing, |this, trailing| {
            this.child(
                h_flex()
                    .flex_none()
                    .gap(px(8.))
                    .items_center()
                    .child(trailing),
            )
        })
}

/// A row's title, with the quiet tag that says what it is for.
fn row_title(title: impl Into<SharedString>, tag: Option<&'static str>, cx: &App) -> Div {
    let lb = cx.lb();
    h_flex()
        .gap(px(7.))
        .items_center()
        .flex_wrap()
        .child(
            div()
                .text_size(ty::BODY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text)
                .child(title.into()),
        )
        .when_some(tag, |this, tag| {
            this.child(
                div()
                    .px(px(7.))
                    .py(px(1.))
                    .rounded_full()
                    .bg(lb.chip_fill)
                    .text_size(px(11.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(lb.text_secondary)
                    .child(tag),
            )
        })
}

/// Secondary text that wraps.
fn quiet(content: impl Into<SharedString>, cx: &App) -> Div {
    let lb = cx.lb();
    div()
        .text_size(ty::SECONDARY)
        .line_height(px(17.))
        .text_color(lb.text_secondary)
        .child(ui::text::paragraph(content))
}

/// A quiet line under a card: a small symbol and one sentence (`OnboardingNote`).
fn note(symbol: Ico, content: impl Into<SharedString>, cx: &App) -> Div {
    let lb = cx.lb();
    h_flex()
        .w_full()
        .px(px(2.))
        .gap(px(6.))
        .items_start()
        .child(
            div()
                .pt(px(2.))
                .flex_none()
                .child(ui::icon(symbol, px(13.), lb.text_secondary)),
        )
        .child(div().flex_1().min_w_0().child(quiet(content, cx)))
}

/// A green check with one word: Allowed, Ready (`OnboardingDoneLabel`).
fn done_label(text: &'static str, cx: &App) -> AnyElement {
    let lb = cx.lb();
    h_flex()
        .gap(px(4.))
        .items_center()
        .child(ui::icon(Ico::Check, px(12.), lb.success_text))
        .child(
            div()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.success_text)
                .child(text),
        )
        .into_any_element()
}

/// One word in the attention colour: Stopped, Needs Attention.
fn attention_label(text: &'static str, cx: &App) -> AnyElement {
    div()
        .text_size(ty::SECONDARY)
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(cx.lb().attention_text)
        .child(text)
        .into_any_element()
}

/// A thin progress bar in the accent colour.
fn progress_bar(fraction: f32, cx: &App) -> Div {
    let lb = cx.lb();
    div()
        .h(px(4.))
        .w_full()
        .rounded_full()
        .bg(lb.chip_fill)
        .child(
            div()
                .h_full()
                .rounded_full()
                .bg(lb.accent_fill)
                .w(gpui_kit::relative(fraction.clamp(0.0, 1.0))),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn three_steps_in_order() {
        assert_eq!(Step::Choose.next(), Some(Step::Access));
        assert_eq!(Step::Access.next(), Some(Step::Download));
        assert_eq!(Step::Download.next(), None);
        assert_eq!(Step::Choose.previous(), None);
        assert_eq!(Step::Download.previous(), Some(Step::Access));
    }

    #[test]
    fn the_meeting_switch_keeps_the_detected_call_choice() {
        let mut draft = Draft::new(&Settings::default());
        assert!(draft.records_detected_calls());
        draft.set_meeting_mode(AutoRecordMode::Automatic);
        draft.set_records_detected_calls(false);
        assert_eq!(draft.meeting_mode, AutoRecordMode::Manual);
        draft.set_records_detected_calls(true);
        assert_eq!(draft.meeting_mode, AutoRecordMode::Automatic);

        // Settings that never auto-record start the switch off, and turning it
        // on picks a new install's own choice.
        let manual = Settings {
            auto_record_mode: AutoRecordMode::Manual,
            ..Settings::default()
        };
        let mut draft = Draft::new(&manual);
        assert!(!draft.records_detected_calls());
        draft.set_records_detected_calls(true);
        assert_eq!(draft.meeting_mode, Settings::default().auto_record_mode);
    }

    #[test]
    fn a_fresh_draft_changes_nothing_when_applied() {
        // Clicking straight through setup on a new install keeps the defaults.
        let settings = Settings::default();
        let mut applied = settings.clone();
        Draft::new(&settings).apply(&mut applied);
        assert_eq!(applied.auto_record_mode, settings.auto_record_mode);
        assert_eq!(applied.tracking_enabled, settings.tracking_enabled);
        assert_eq!(
            applied.screen_context_capture_mode,
            settings.screen_context_capture_mode
        );
        assert_eq!(
            applied.coding_agent_evidence_enabled,
            settings.coding_agent_evidence_enabled
        );
        assert_eq!(applied.cotyping_enabled, settings.cotyping_enabled);
    }

    #[test]
    fn day_memory_off_keeps_no_screen_context() {
        let mut draft = Draft::new(&Settings::default());
        draft.context_mode = ScreenContextMode::TextAndVisual;
        assert!(draft.takes_screenshots());
        draft.day_memory = false;
        assert_eq!(draft.screen_context(), ScreenContextMode::ActivityOnly);
        assert!(!draft.reads_screen_text());
    }

    use lokalbot_platform::session::Desktop;

    #[test]
    fn floats_only_where_the_compositor_tiles() {
        assert!(window_kind(&Desktop::Hyprland) == WindowKind::Floating);
        assert!(window_kind(&Desktop::Sway) == WindowKind::Floating);
        for desktop in [
            Desktop::Windows,
            Desktop::X11,
            Desktop::Kde,
            Desktop::Gnome,
            Desktop::OtherWayland("niri".into()),
        ] {
            assert!(window_kind(&desktop) == WindowKind::Normal, "{desktop:?}");
        }
    }
}
