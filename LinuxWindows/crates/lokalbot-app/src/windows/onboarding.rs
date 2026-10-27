//! Welcome to LokalBot (`OnboardingView.swift`): four steps. Choices stay a
//! draft until "Apply Choices and Start"; model downloads happen only when
//! asked for. macOS permission panes have no equivalent here, so step two
//! checks the microphone, system audio and activity tracking instead.
//! Step three can also prepare autocomplete's model, which stays off until
//! it is turned on in Settings → Writing.

use std::time::Duration;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, TitleBar, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Animation, AnimationExt as _, AnyElement, App, AppContext as _, Bounds, Context, Div, Entity,
    FontWeight, InteractiveElement as _, IntoElement, ParentElement as _, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window, WindowBounds, WindowKind,
    WindowOptions, div, img, px, relative, size,
};
use lokalbot_core::ScreenContextMode;
use lokalbot_core::settings::{AutoRecordMode, SummarizerBackend};

use crate::pages::ask::composer_inference;
use crate::pages::settings::models::{
    autocomplete_needs, model_bytes, model_name, models_in_use, size_label,
};
use crate::state::{AppData, AppEvent};
use crate::theme::{FONT_FAMILY, LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

const WIDTH: f32 = 650.;
const HEIGHT: f32 = 640.;

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
    let bounds = Bounds::centered(None, size(px(WIDTH), px(HEIGHT)), cx);
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

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Step {
    Capture,
    Access,
    Models,
    Review,
}

impl Step {
    const ALL: [Step; 4] = [Step::Capture, Step::Access, Step::Models, Step::Review];

    fn index(self) -> usize {
        Self::ALL.iter().position(|s| *s == self).unwrap_or(0)
    }

    fn title(self) -> &'static str {
        match self {
            Step::Capture => lokalbot_i18n::tr("Choose What to Remember"),
            Step::Access => lokalbot_i18n::tr("Enable the Access You Need"),
            Step::Models => lokalbot_i18n::tr("Prepare Your Workflows"),
            Step::Review => lokalbot_i18n::tr("Review and Start"),
        }
    }
}

/// `CaptureSetupDraft`: applied only on the last step.
#[derive(Clone, Copy)]
struct Draft {
    meeting_mode: AutoRecordMode,
    day_memory: bool,
    context_mode: ScreenContextMode,
}

impl Draft {
    /// Screen context the draft would turn on.
    fn screen_context(&self) -> ScreenContextMode {
        if self.day_memory {
            self.context_mode
        } else {
            ScreenContextMode::ActivityOnly
        }
    }
}

pub struct Onboarding {
    data: Entity<AppData>,
    step: Step,
    forward: bool,
    draft: Draft,
    /// "Also prepare Autocomplete (optional)".
    include_autocomplete: bool,
    _subscriptions: Vec<Subscription>,
}

impl Onboarding {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let settings = data.read(cx).settings.clone();
        let subscriptions = vec![cx.observe_in(&data, window, |_, _, _, cx| cx.notify())];
        Self {
            data,
            step: Step::Capture,
            forward: true,
            draft: Draft {
                meeting_mode: settings.auto_record_mode,
                day_memory: settings.tracking_enabled,
                context_mode: settings.screen_context_capture_mode,
            },
            include_autocomplete: false,
            _subscriptions: subscriptions,
        }
    }

    fn go(&mut self, step: Step, cx: &mut Context<Self>) {
        self.forward = step > self.step;
        self.step = step;
        cx.notify();
    }

    fn finish(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let draft = self.draft;
        self.data.update(cx, |data, cx| {
            data.update_settings(
                |s| {
                    s.auto_record_mode = draft.meeting_mode;
                    s.tracking_enabled = draft.day_memory;
                    s.screen_context_capture_mode = draft.screen_context();
                    s.onboarding_completed = true;
                },
                cx,
            )
        });
        super::secondary(cx).onboarding = None;
        window.remove_window();
    }

    fn prepare_models(&mut self, cx: &mut Context<Self>) {
        let include_autocomplete = self.include_autocomplete;
        // The draft is not applied yet, so its screen text model is asked for here.
        let screen_text = self.draft.screen_context() != ScreenContextMode::ActivityOnly;
        self.data.update(cx, |data, cx| {
            data.request(AppEvent::PrepareModels, cx);
            if screen_text && !data.models.screen_text_ready {
                data.request(
                    AppEvent::DownloadModel(lokalbot_ai::ocr::OCR_MODEL_ID.to_string()),
                    cx,
                );
            }
            if include_autocomplete {
                let missing: Vec<String> = autocomplete_needs(&data.settings)
                    .into_iter()
                    .filter(|id| !data.models.installed.contains(id))
                    .collect();
                for id in missing {
                    data.request(AppEvent::DownloadModel(id), cx);
                }
            }
        });
    }

    fn render_capture(&self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let draft = self.draft;
        let page = cx.entity();
        let mode_page = page.clone();
        let detail_page = page.clone();
        let memory_page = page.clone();
        let retention = match self.data.read(cx).settings.retention_days {
            1 => lokalbot_i18n::tr("1 day").to_string(),
            days => lokalbot_i18n::format("{days} days", &[("days", format!("{}", days))]),
        };
        let meeting_picker = Button::new("onboarding-meeting-mode")
            .outline()
            .small()
            .label(lokalbot_i18n::tr(draft.meeting_mode.label()))
            .dropdown_caret(true)
            .dropdown_menu(move |mut menu, _, _| {
                for mode in AutoRecordMode::ALL {
                    let page = mode_page.clone();
                    menu = menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr(mode.label()))
                            .checked(mode == draft.meeting_mode)
                            .on_click(move |_, _, cx| {
                                page.update(cx, |this, cx| {
                                    this.draft.meeting_mode = mode;
                                    cx.notify();
                                })
                            }),
                    );
                }
                menu
            });
        let detail_picker = Button::new("onboarding-context-mode")
            .outline()
            .small()
            .label(lokalbot_i18n::tr(draft.context_mode.label()))
            .dropdown_caret(true)
            .disabled(!draft.day_memory)
            .dropdown_menu(move |mut menu, _, _| {
                for mode in ScreenContextMode::ALL {
                    let page = detail_page.clone();
                    menu = menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr(mode.label()))
                            .checked(mode == draft.context_mode)
                            .on_click(move |_, _, cx| {
                                page.update(cx, |this, cx| {
                                    this.draft.context_mode = mode;
                                    cx.notify();
                                })
                            }),
                    );
                }
                menu
            });
        let screen_context = draft.screen_context() != ScreenContextMode::ActivityOnly;
        v_flex()
            .gap(px(16.))
            .child(text(
                lokalbot_i18n::tr("Keep meeting evidence and a useful memory of your day. You can change each choice later in Settings."),
                lb.text_secondary,
            ))
            .child(
                ui::panel(cx)
                    .child(
                        v_flex()
                            .gap(px(12.))
                            .child(
                                v_flex()
                                    .gap(px(6.))
                                    .child(
                                        h_flex()
                                            .gap(px(12.))
                                            .items_center()
                                            .child(div().flex_1().min_w_0().text_size(ty::BODY).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Detected Meetings"))))
                                            .child(meeting_picker),
                                    )
                                    .child(text(
                                        lokalbot_i18n::tr("Ask via notification waits for you to start recording. Manual mode keeps Record Now available."),
                                        lb.text_secondary,
                                    )),
                            )
                            .child(ui::divider(cx))
                            .child(
                                h_flex()
                                    .gap(px(12.))
                                    .items_center()
                                    .child(
                                        v_flex()
                                            .flex_1().min_w_0()
                                            .gap(px(4.))
                                            .child(div().text_size(ty::BODY).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Day Memory"))))
                                            .child(text(lokalbot_i18n::tr("Remember app and window activity."), lb.text_secondary)),
                                    )
                                    .child(Switch::new("onboarding-day-memory").checked(draft.day_memory).on_click(
                                        move |on, _, cx| {
                                            let on = *on;
                                            memory_page.update(cx, |this, cx| {
                                                this.draft.day_memory = on;
                                                cx.notify();
                                            })
                                        },
                                    )),
                            )
                            .child(ui::divider(cx))
                            .child(
                                v_flex()
                                    .gap(px(6.))
                                    .child(
                                        h_flex()
                                            .gap(px(12.))
                                            .items_center()
                                            .child(div().flex_1().min_w_0().text_size(ty::BODY).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Day-Memory Detail"))))
                                            .child(detail_picker),
                                    )
                                    .child(text(
                                        crate::pages::settings::day_memory_mode_detail(draft.context_mode),
                                        lb.text_secondary,
                                    )),
                            ),
                    ),
            )
            .child(text(
                if screen_context {
                    lokalbot_i18n::format("Text and images build on app activity. Images are encrypted on disk; captured text remains searchable under your retention policy ({retention}), and passwords, excluded apps and private windows are never captured.", &[("retention", retention.to_string())])
                } else {
                    lokalbot_i18n::format("Day Memory notes the app in front and its window title, never what you type or what is on screen. Window titles are cleared after {retention}; you can change this in Settings → Privacy & Data.", &[("retention", retention.to_string())])
                },
                lb.text_secondary,
            ))
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(ui::icon(Ico::ListChecks, px(14.), lb.text_secondary))
                    .child(text(lokalbot_i18n::tr("These choices are applied on the final Review step."), lb.text_secondary)),
            )
    }

    fn render_access(&self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let (microphones, system_audio) = {
            let data = self.data.read(cx);
            (data.audio_inputs.clone(), data.settings.record_system_audio)
        };
        let microphone_status = match microphones.first() {
            Some(name) => (
                lokalbot_i18n::format("Found: {name}", &[("name", format!("{}", name))]),
                true,
            ),
            None => (
                lokalbot_i18n::tr("Checked when you first record").to_string(),
                false,
            ),
        };
        let wayland = cfg!(target_os = "linux")
            && std::env::var("XDG_SESSION_TYPE").is_ok_and(|t| t.eq_ignore_ascii_case("wayland"));
        let activity_detail = if cfg!(target_os = "windows") {
            lokalbot_i18n::tr(
                "Reads the focused app and window title. Windows needs no extra permission for this.",
            )
        } else if wayland {
            lokalbot_i18n::tr(
                "Wayland keeps window titles private on many desktops; LokalBot records the app names it can see and fills in titles where the desktop shares them.",
            )
        } else {
            lokalbot_i18n::tr(
                "Reads the focused app and window title from the X11 session. No extra permission is needed.",
            )
        };
        let system_detail = if cfg!(target_os = "windows") {
            lokalbot_i18n::tr(
                "Records the other side of calls from your speakers or headset through Windows loopback capture.",
            )
        } else {
            lokalbot_i18n::tr(
                "Records the other side of calls from your speakers or headset through a PipeWire or PulseAudio monitor.",
            )
        };
        v_flex()
            .gap(px(14.))
            .child(text(
                lokalbot_i18n::tr("LokalBot checks what it needs on this PC. Nothing here changes system settings, and you can finish setup and turn features on later."),
                lb.text_secondary,
            ))
            .child(access_row(
                Ico::Mic,
                lokalbot_i18n::tr("Microphone"),
                lokalbot_i18n::tr("Records your side of meetings and dictation."),
                microphone_status.0,
                microphone_status.1,
                cx,
            ))
            .child(access_row(
                Ico::Volume2,
                lokalbot_i18n::tr("System audio"),
                system_detail,
                if system_audio { lokalbot_i18n::tr("On").into() } else { lokalbot_i18n::tr("Off — microphone only").into() },
                system_audio,
                cx,
            ))
            .child(access_row(
                Ico::Activity,
                lokalbot_i18n::tr("App and window activity"),
                activity_detail,
                if self.draft.day_memory { lokalbot_i18n::tr("Used by Day Memory").into() } else { lokalbot_i18n::tr("Off").into() },
                self.draft.day_memory,
                cx,
            ))
            .child(text(
                lokalbot_i18n::tr("Autocomplete and the dictation shortcut can be turned on later in Settings → Writing and Dictation."),
                lb.text_secondary,
            ))
    }

    fn render_models(&self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let (settings, status, downloads) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.models.clone(),
                data.downloads.clone(),
            )
        };
        let model_status = |id: &str, ready: bool| -> (String, bool) {
            match downloads.get(id) {
                Some(progress) if progress.error.is_some() => {
                    (lokalbot_i18n::tr("Download failed").into(), false)
                }
                Some(progress) => (
                    lokalbot_i18n::format(
                        "Downloading · {0}%",
                        &[("0", format!("{}", (progress.fraction() * 100.).round()))],
                    ),
                    false,
                ),
                None if ready => (lokalbot_i18n::tr("Ready").into(), true),
                None => (lokalbot_i18n::tr("Download required").into(), false),
            }
        };
        let with_size = |id: &str| {
            format!(
                "{} · {}",
                model_name(id),
                size_label(model_bytes(id, &settings))
            )
        };
        let built_in = settings.summarizer_backend == SummarizerBackend::BuiltIn;
        let think_local = settings.think_is_local();
        let think_name = if built_in {
            with_size(&settings.built_in_model_id)
        } else {
            lokalbot_i18n::tr("Your model server").into()
        };
        let speech = model_status(&settings.transcription_model, status.transcription_ready);
        let think = model_status(&settings.built_in_model_id, status.think_ready || !built_in);
        let embedding_id = lokalbot_ai::catalog::EMBEDDING_MODEL_ID;
        let search = settings
            .semantic_search_enabled
            .then(|| model_status(embedding_id, status.embeddings_ready));
        // Everything "Prepare" downloads: Transcribe with voice detection and
        // speaker separation, Think, search by meaning, the llama.cpp runtime,
        // screen text when chosen, and Autocomplete's model when asked for.
        let ocr_id = lokalbot_ai::ocr::OCR_MODEL_ID;
        let screen_text = (self.draft.screen_context() != ScreenContextMode::ActivityOnly)
            .then(|| model_status(ocr_id, status.screen_text_ready));
        let mut needed = models_in_use(&settings);
        if screen_text.is_some() && !needed.iter().any(|id| id == ocr_id) {
            needed.push(ocr_id.to_string());
        }
        if self.include_autocomplete {
            for id in autocomplete_needs(&settings) {
                if !needed.contains(&id) {
                    needed.push(id);
                }
            }
        }
        let download: u64 = needed
            .iter()
            .filter(|id| !status.installed.contains(id))
            .map(|id| model_bytes(id, &settings))
            .sum();
        let autocomplete = model_status(
            &settings.cotyping_built_in_model_id,
            status.autocomplete_ready,
        );
        let page = cx.entity();
        let toggle_page = page.clone();
        let preparing = !downloads.is_empty();
        v_flex()
            .gap(px(14.))
            .child(text(
                lokalbot_i18n::tr("Meeting processing needs a Transcribe model and a Think model, and search by meaning adds a small embedding model. Downloads can be deferred; captured meetings wait for their selected models."),
                lb.text_secondary,
            ))
            .child(model_row(lokalbot_i18n::tr("Speech recognition"), with_size(&settings.transcription_model), speech, downloads.get(&settings.transcription_model).map(|d| d.fraction()), cx))
            .child(model_row(lokalbot_i18n::tr("Summaries and Ask"), think_name, think, downloads.get(&settings.built_in_model_id).map(|d| d.fraction()), cx))
            .when_some(search, |this, search| {
                this.child(model_row(lokalbot_i18n::tr("Search by meaning"), with_size(embedding_id), search, downloads.get(embedding_id).map(|d| d.fraction()), cx))
            })
            .when_some(screen_text, |this, screen_text| {
                this.child(model_row(lokalbot_i18n::tr("Screen text"), with_size(ocr_id), screen_text, downloads.get(ocr_id).map(|d| d.fraction()), cx))
            })
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_start()
                    .child(ui::icon(if think_local { Ico::ShieldCheck } else { Ico::Network }, px(14.), lb.text_secondary))
                    .child(text(
                        if think_local {
                            lokalbot_i18n::tr("The configured Think model processes selected context on this PC.")
                        } else {
                            lokalbot_i18n::tr("Selected transcript and work context is sent to the approved model server.")
                        },
                        lb.text_secondary,
                    )),
            )
            .child(
                h_flex()
                    .gap(px(12.))
                    .items_center()
                    .child(div().flex_1().min_w_0().text_size(ty::BODY).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Also prepare Autocomplete (optional)"))))
                    .child(Switch::new("onboarding-autocomplete").checked(self.include_autocomplete).on_click(move |on, _, cx| {
                        let on = *on;
                        toggle_page.update(cx, |this, cx| {
                            this.include_autocomplete = on;
                            cx.notify();
                        })
                    })),
            )
            .when(self.include_autocomplete, |this| {
                this.child(model_row(
                    lokalbot_i18n::tr("Autocomplete"),
                    with_size(&settings.cotyping_built_in_model_id),
                    autocomplete,
                    downloads.get(&settings.cotyping_built_in_model_id).map(|d| d.fraction()),
                    cx,
                ))
                .child(text(
                    lokalbot_i18n::tr("Autocomplete also reads the text just above the field you are typing in, such as the conversation you are answering, to fit its suggestions. It stays on this PC and is never saved; turn it off in Settings → Writing."),
                    lb.text_secondary,
                ))
            })
            .child(
                h_flex()
                    .gap(px(12.))
                    .items_center()
                    .child(
                        Button::new("onboarding-prepare")
                            .outline()
                            .icon(Icon::new(Ico::CircleArrowDown))
                            .label(if preparing { lokalbot_i18n::tr("Preparing…") } else { lokalbot_i18n::tr("Prepare Selected Models") })
                            .disabled(preparing || download == 0)
                            .on_click(move |_, _, cx| page.update(cx, |this, cx| this.prepare_models(cx))),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(if download == 0 {
                                lokalbot_i18n::tr("Everything is already on this PC.").to_string()
                            } else {
                                lokalbot_i18n::format("About {0} to download", &[("0", size_label(download).to_string())])
                            }),
                    ),
            )
            .child(text(
                lokalbot_i18n::tr("Downloads use the model provider. They do not send your meeting content. Existing downloaded models are kept."),
                lb.text_secondary,
            ))
    }

    fn render_review(&self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let status = self.data.read(cx).models.clone();
        let draft = self.draft;
        let day_memory: SharedString = if draft.day_memory {
            lokalbot_i18n::tr(draft.context_mode.label()).into()
        } else {
            lokalbot_i18n::tr("Off").into()
        };
        let meeting_models = if status.transcription_ready && status.think_ready {
            lokalbot_i18n::tr("Ready to use · not a test result")
        } else {
            lokalbot_i18n::tr("Preparation can continue later")
        };
        let row = |label: &'static str, value: SharedString| {
            h_flex()
                .gap(px(12.))
                .items_center()
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(ty::BODY)
                        .text_color(lb.text)
                        .child(label),
                )
                .child(
                    div()
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .child(value),
                )
        };
        v_flex()
            .gap(px(16.))
            .child(
                ui::panel(cx).child(
                    v_flex()
                        .gap(px(12.))
                        .child(row(lokalbot_i18n::tr("Meeting recording"), lokalbot_i18n::tr(draft.meeting_mode.label()).into()))
                        .child(ui::divider(cx))
                        .child(row(lokalbot_i18n::tr("Day memory"), day_memory))
                        .child(ui::divider(cx))
                        .child(row(lokalbot_i18n::tr("Think model"), composer_inference(cx).label))
                        .child(ui::divider(cx))
                        .child(row(lokalbot_i18n::tr("Meeting models"), meeting_models.into())),
                ),
            )
            .child(text(
                lokalbot_i18n::tr("You can browse, search and edit your existing local library immediately. Setup does not delete any content or change existing remote-server approvals."),
                lb.text_secondary,
            ))
    }
}

impl Render for Onboarding {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        window.set_window_title(lokalbot_i18n::tr("Welcome to LokalBot"));
        let lb = cx.lb().clone();
        let step = self.step;
        let body = match step {
            Step::Capture => self.render_capture(cx),
            Step::Access => self.render_access(cx),
            Step::Models => self.render_models(cx),
            Step::Review => self.render_review(cx),
        };
        let travel = if self.forward { 24. } else { -24. };
        let dots = Step::ALL.iter().map(|item| {
            div().size(px(6.)).rounded_full().bg(if *item == step {
                lb.accent_text
            } else {
                lb.text_secondary.opacity(0.25)
            })
        });
        let primary_label = match step {
            Step::Access => lokalbot_i18n::tr("Continue with Current Access"),
            Step::Review => lokalbot_i18n::tr("Apply Choices and Start"),
            _ => lokalbot_i18n::tr("Continue"),
        };
        v_flex()
            .size_full()
            .font_family(FONT_FAMILY)
            .text_align(crate::i18n::interface_alignment())
            .bg(lb.window)
            .text_color(lb.text)
            .child(
                TitleBar::new()
                    .bg(lb.title_bar)
                    .border_color(lb.separator)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .justify_center()
                            .text_size(ty::SECONDARY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Welcome to LokalBot",
                            ))),
                    ),
            )
            .child(
                v_flex()
                    .items_center()
                    .gap(px(16.))
                    .px(metric::DETAIL_PADDING)
                    .pt(px(24.))
                    .pb(px(8.))
                    .child(crate::i18n::language_picker("onboarding-language", cx))
                    .child(img("brand/lokalbot.svg").size(px(64.)))
                    .child(h_flex().gap(px(8.)).children(dots))
                    .child(
                        div()
                            .text_center()
                            .text_size(ty::PAGE_TITLE)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(step.title()),
                    ),
            )
            .child(
                div()
                    .id("onboarding-body")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .child(div().p(px(24.)).w_full().child(body).with_animation(
                        SharedString::from(format!("onboarding-step-{}", step.index())),
                        Animation::new(Duration::from_millis(250)),
                        move |element, delta| {
                            element.left(px(travel * (1. - delta))).opacity(delta)
                        },
                    )),
            )
            .child(ui::divider(cx))
            .child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .p(px(24.))
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                "Step {0} of 4",
                                &[("0", format!("{}", step.index() + 1))],
                            ))),
                    )
                    .child(div().flex_1().min_w_0())
                    .child(
                        Button::new("onboarding-back")
                            .outline()
                            .label(lokalbot_i18n::tr("Back"))
                            .disabled(step == Step::Capture)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                let previous = Step::ALL[step.index().saturating_sub(1)];
                                this.go(previous, cx);
                            })),
                    )
                    .child(
                        Button::new("onboarding-continue")
                            .primary()
                            .label(primary_label)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                if step == Step::Review {
                                    this.finish(window, cx);
                                } else {
                                    this.go(Step::ALL[step.index() + 1], cx);
                                }
                            })),
                    ),
            )
    }
}

fn text(content: impl Into<SharedString>, color: gpui_kit::Hsla) -> Div {
    div()
        .text_size(ty::BODY)
        .line_height(px(20.))
        .text_color(color)
        .child(crate::ui::text::paragraph(content))
}

fn access_row(
    icon: Ico,
    title: &'static str,
    detail: &'static str,
    status: String,
    good: bool,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let tint = if good {
        lb.success_text
    } else {
        lb.attention_text
    };
    ui::panel(cx)
        .child(
            h_flex()
                .gap(px(12.))
                .items_start()
                .child(ui::icon_tile(icon, lb.accent_text, px(32.)))
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(4.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text)
                                .child(title),
                        )
                        .child(text(detail, lb.text_secondary))
                        .child(
                            h_flex()
                                .gap(px(6.))
                                .items_center()
                                .child(ui::icon(
                                    if good {
                                        Ico::CircleCheck
                                    } else {
                                        Ico::CircleAlert
                                    },
                                    px(13.),
                                    tint,
                                ))
                                .child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(tint)
                                        .child(status),
                                ),
                        ),
                ),
        )
        .into_any_element()
}

fn model_row(
    title: &'static str,
    model: String,
    status: (String, bool),
    progress: Option<f32>,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let (label, good) = status;
    ui::panel(cx)
        .child(
            h_flex()
                .gap(px(12.))
                .items_center()
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(3.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text)
                                .child(title),
                        )
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(model),
                        ),
                )
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(if good {
                            lb.success_text
                        } else {
                            lb.text_secondary
                        })
                        .child(label),
                ),
        )
        .when_some(progress, |this, fraction| {
            this.child(
                div()
                    .mt(px(10.))
                    .h(px(4.))
                    .w_full()
                    .rounded_full()
                    .bg(lb.chip_fill)
                    .child(
                        div()
                            .h_full()
                            .rounded_full()
                            .bg(lb.accent_fill)
                            .w(relative(fraction.clamp(0.0, 1.0))),
                    ),
            )
        })
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;
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
