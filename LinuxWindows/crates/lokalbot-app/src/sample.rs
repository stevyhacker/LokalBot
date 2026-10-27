//! "Try a sample meeting": LokalBot's bundled sample (`lokalbot_engine::sample`)
//! for a library with nothing in it yet. The models it needs download first,
//! as their own step and only when asked; then the sample is imported like
//! any recording, transcribed, and summarized, and its banner suggests one
//! question for Ask. Nothing about trying it is recorded anywhere else.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, IntoElement, ParentElement as _,
    Styled as _, div, px, relative,
};
use lokalbot_core::Meeting;
use lokalbot_core::settings::{Settings, SummarizerBackend};

use crate::pages::settings::models::{RUNTIME_ID, model_bytes, model_name, size_label};
use crate::state::{AppData, AppEvent, AskRequest, MeetingTab, ProcessingStage};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

/// The question the sample's banner suggests. Its answer is in the passage
/// where the decision changes (`SampleMeeting/expected.en.json`).
pub const QUESTION: &str = "Is the delivery window field required in the Orders API response?";

/// "Try a sample meeting" waiting for its models.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SampleSetup {
    /// The user chose "Download and continue".
    pub downloading: bool,
    /// The sample is being added to the library.
    pub importing: bool,
}

/// Model ids the sample needs: Transcribe with voice detection and speaker
/// separation, and the built-in Think model with its runtime (nothing for
/// Think on a model server).
pub fn needs(settings: &Settings) -> Vec<String> {
    let mut ids = vec![settings.transcription_model.clone()];
    ids.extend(lokalbot_speech::models::supporting_ids(
        settings.multi_speaker_diarization,
    ));
    if settings.summarizer_backend == SummarizerBackend::BuiltIn {
        ids.push(settings.built_in_model_id.clone());
        ids.push(RUNTIME_ID.to_string());
    }
    ids
}

fn missing(data: &AppData) -> Vec<String> {
    needs(&data.settings)
        .into_iter()
        .filter(|id| !data.models.installed.contains(id))
        .collect()
}

impl AppData {
    /// The sample meeting, when the library has one.
    pub fn sample_meeting(&self) -> Option<&Meeting> {
        self.meetings.iter().find(|m| m.is_sample())
    }

    /// Opens the sample, or starts adding it: straight away when its models
    /// are here, otherwise after the download step in Meetings.
    pub fn try_sample(&mut self, cx: &mut Context<Self>) {
        if let Some(sample) = self.sample_meeting() {
            let id = sample.id;
            self.open_meeting(id, MeetingTab::Summary, None, cx);
            return;
        }
        self.section = crate::state::Section::Meetings;
        self.meeting_focus = None;
        if missing(self).is_empty() {
            self.import_sample(cx);
        } else {
            self.sample_setup = Some(SampleSetup::default());
            cx.notify();
        }
    }

    pub fn download_sample_models(&mut self, cx: &mut Context<Self>) {
        let Some(setup) = self.sample_setup.as_mut() else {
            return;
        };
        setup.downloading = true;
        for id in missing(self) {
            let running = self.downloads.get(&id).is_some_and(|d| d.error.is_none());
            if !running {
                self.request(AppEvent::DownloadModel(id), cx);
            }
        }
        cx.notify();
    }

    pub fn cancel_sample(&mut self, cx: &mut Context<Self>) {
        self.sample_setup = None;
        cx.notify();
    }

    /// Called when model downloads change: continues once the last one lands.
    pub(crate) fn sample_models_changed(&mut self, cx: &mut Context<Self>) {
        let ready = self
            .sample_setup
            .as_ref()
            .is_some_and(|s| s.downloading && !s.importing);
        if ready && missing(self).is_empty() {
            self.import_sample(cx);
        }
    }

    fn import_sample(&mut self, cx: &mut Context<Self>) {
        self.sample_setup
            .get_or_insert_with(SampleSetup::default)
            .importing = true;
        cx.notify();
        let library = self.library.clone();
        let sample = lokalbot_engine::sample::for_language(lokalbot_i18n::current().code);
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    lokalbot_engine::library_ops::import_sample(
                        &library,
                        sample,
                        chrono::Utc::now(),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.sample_setup = None;
                match result {
                    Ok(meeting) => {
                        log::info!("sample meeting added meeting={}", meeting.id);
                        // Notes are part of the sample even with automatic notes off.
                        this.request(
                            AppEvent::ProcessMeeting {
                                meeting_id: meeting.id,
                                transcribe: true,
                                summarize: true,
                            },
                            cx,
                        );
                        this.reload(cx);
                        this.open_meeting(meeting.id, MeetingTab::Summary, None, cx);
                    }
                    Err(failure) => this.show_error(failure.localized(sample.title), cx),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Asks the suggested question about the sample, with the sample as the only source.
    pub fn ask_sample_question(&mut self, meeting_id: uuid::Uuid, cx: &mut Context<Self>) {
        self.ask(
            AskRequest {
                question: lokalbot_i18n::tr(QUESTION).to_string(),
                meeting_ids: vec![meeting_id],
                submit: true,
            },
            cx,
        );
    }
}

fn stage_row(done: bool, active: bool, label: &'static str, cx: &App) -> AnyElement {
    let lb = cx.lb();
    h_flex()
        .gap(px(8.))
        .items_center()
        .child(if done {
            ui::icon(Ico::CircleCheck, px(16.), lb.success_text).into_any_element()
        } else if active {
            Spinner::new().small().into_any_element()
        } else {
            ui::icon(Ico::Circle, px(16.), lb.text_tertiary).into_any_element()
        })
        .child(
            div()
                .text_size(ty::BODY)
                .font_weight(if active {
                    FontWeight::SEMIBOLD
                } else {
                    FontWeight::NORMAL
                })
                .text_color(if done || active {
                    lb.text
                } else {
                    lb.text_secondary
                })
                .child(label),
        )
        .into_any_element()
}

/// The Meetings detail pane while the sample waits for its models: what will
/// download and how big it is, then the steps that follow.
pub fn render_setup(data: &Entity<AppData>, cx: &App) -> AnyElement {
    let lb = cx.lb().clone();
    let state = data.read(cx);
    let setup = state.sample_setup.clone().unwrap_or_default();
    let needed = needs(&state.settings);
    let missing = missing(state);
    let total: u64 = missing
        .iter()
        .map(|id| model_bytes(id, &state.settings))
        .sum();
    let failed = missing
        .iter()
        .any(|id| state.downloads.get(id).is_some_and(|d| d.error.is_some()));
    let rows = needed.iter().map(|id| {
        let installed = !missing.contains(id);
        let progress = state.downloads.get(id).cloned();
        let status: String = match &progress {
            _ if installed => lokalbot_i18n::tr("Ready").into(),
            Some(p) if p.error.is_some() => lokalbot_i18n::tr("Download failed").into(),
            Some(p) => lokalbot_i18n::format(
                "Downloading · {0}%",
                &[("0", format!("{}", (p.fraction() * 100.).round()))],
            ),
            None => size_label(model_bytes(id, &state.settings)),
        };
        v_flex()
            .gap(px(6.))
            .child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(model_name(id)),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(if installed {
                                lb.success_text
                            } else {
                                lb.text_secondary
                            })
                            .child(status),
                    ),
            )
            .when_some(
                progress.filter(|p| !installed && p.error.is_none()),
                |this, p| {
                    this.child(
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
                                    .w(relative(p.fraction().clamp(0.0, 1.0))),
                            ),
                    )
                },
            )
            .into_any_element()
    });
    let download_data = data.clone();
    let cancel_data = data.clone();
    let downloading = setup.downloading && !failed;
    v_flex()
        .size_full()
        .items_center()
        .justify_center()
        .p(px(24.))
        .child(
            ui::panel(cx)
                .w_full()
                .max_w(px(520.))
                .flex()
                .flex_col()
                .gap(px(16.))
                .child(
                    h_flex()
                        .gap(px(12.))
                        .items_center()
                        .child(ui::icon_tile(Ico::AudioLines, lb.accent_text, px(40.)))
                        .child(
                            div()
                                .text_size(ty::COLUMN_TITLE)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text)
                                .child(lokalbot_i18n::tr("Try a sample meeting")),
                        ),
                )
                .child(
                    div()
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .child(ui::text::paragraph(lokalbot_i18n::tr("A made-up three-and-a-half-minute call between two synthetic voices. LokalBot transcribes it and writes its notes locally, then answers a question about it and shows the passage the answer came from."))),
                )
                .child(stage_row(missing.is_empty(), downloading, lokalbot_i18n::tr("Download models"), cx))
                .child(v_flex().pl(px(24.)).gap(px(10.)).children(rows))
                .child(stage_row(false, setup.importing, lokalbot_i18n::tr("Transcribe the sample"), cx))
                .child(stage_row(false, false, lokalbot_i18n::tr("Write the notes"), cx))
                .child(stage_row(false, false, lokalbot_i18n::tr("Ask about it"), cx))
                .child(
                    h_flex()
                        .gap(px(10.))
                        .items_center()
                        .child(
                            Button::new("sample-download")
                                .primary()
                                .small()
                                .label(if failed {
                                    lokalbot_i18n::tr("Retry").to_string()
                                } else {
                                    format!(
                                        "{} · {}",
                                        lokalbot_i18n::tr("Download and continue"),
                                        size_label(total)
                                    )
                                })
                                .disabled(downloading || setup.importing)
                                .on_click(move |_, _, cx| {
                                    download_data.update(cx, |data, cx| data.download_sample_models(cx))
                                }),
                        )
                        .child(
                            Button::new("sample-cancel")
                                .ghost()
                                .small()
                                .label(lokalbot_i18n::tr("Cancel"))
                                .on_click(move |_, _, cx| {
                                    cancel_data.update(cx, |data, cx| data.cancel_sample(cx))
                                }),
                        ),
                ),
        )
        .into_any_element()
}

/// The banner on the sample meeting: what it is, how far processing got,
/// the suggested question, and removing it.
pub fn render_banner(
    data: &Entity<AppData>,
    meeting_id: uuid::Uuid,
    has_transcript: bool,
    has_summary: bool,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb().clone();
    let state = data.read(cx);
    let stage = state.processing.get(&meeting_id).cloned();
    let transcribing = matches!(
        stage,
        Some(
            ProcessingStage::Queued
                | ProcessingStage::WaitingForModels
                | ProcessingStage::PreparingModel(_)
                | ProcessingStage::Transcribing
                | ProcessingStage::IdentifyingSpeakers
        )
    );
    let summarizing = matches!(stage, Some(ProcessingStage::Summarizing));
    let ask_data = data.clone();
    let remove_data = data.clone();
    ui::status_surface(lb.accent_fill, cx)
        .px(px(14.))
        .py(px(12.))
        .flex()
        .flex_col()
        .gap(px(10.))
        .child(
            h_flex()
                .gap(px(8.))
                .items_center()
                .child(ui::icon(Ico::Sparkles, px(16.), lb.accent_text))
                .child(
                    div()
                        .flex_1()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(lokalbot_i18n::tr("Sample meeting")),
                )
                .child(
                    Button::new("sample-remove")
                        .ghost()
                        .small()
                        .label(lokalbot_i18n::tr("Remove sample"))
                        .on_click(move |_, _, cx| {
                            remove_data.update(cx, |data, cx| data.delete_meeting(meeting_id, cx))
                        }),
                ),
        )
        .child(
            div()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(ui::text::paragraph(lokalbot_i18n::tr("The people and the company are made up, and the voices are synthetic. Your day, people, projects and action lists leave it out."))),
        )
        .child(
            h_flex()
                .flex_wrap()
                .gap(px(16.))
                .child(stage_row(true, false, lokalbot_i18n::tr("Download models"), cx))
                .child(stage_row(has_transcript, transcribing, lokalbot_i18n::tr("Transcribe the sample"), cx))
                .child(stage_row(has_summary, summarizing, lokalbot_i18n::tr("Write the notes"), cx)),
        )
        .child(
            h_flex()
                .gap(px(10.))
                .items_center()
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(lokalbot_i18n::tr("Try asking:")),
                        )
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text)
                                .child(ui::text::paragraph(lokalbot_i18n::tr(QUESTION))),
                        ),
                )
                .child(
                    Button::new("sample-ask")
                        .primary()
                        .small()
                        .label(lokalbot_i18n::tr("Ask"))
                        .disabled(!has_transcript)
                        .on_click(move |_, _, cx| {
                            ask_data.update(cx, |data, cx| data.ask_sample_question(meeting_id, cx))
                        }),
                ),
        )
        .into_any_element()
}
