//! The options behind Models' rows (`ModelSupportingSettings.swift`,
//! `ModelPickerSheet.remoteTranscriptionSetup`): Read aloud's voice, speed and
//! sample, the transcription language and vocabulary, the transcription server
//! and where downloads come from.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::slider::{Slider, SliderEvent, SliderState};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Div, Entity, FontWeight, IntoElement as _,
    ParentElement as _, SharedString, Styled as _, Subscription, Window, div, px,
};
use lokalbot_core::Settings;
use lokalbot_core::access::is_private_network_url;
use lokalbot_core::remote_transcription::{self, RemoteTranscription};
use lokalbot_core::settings::ModelDownloadSource;
use lokalbot_engine::{Command, SpeechCommand};
use lokalbot_speech::kokoro;
use lokalbot_speech::language;
use lokalbot_speech::models::KOKORO_MODEL;

use super::models::ModelsPage;
use super::{Section, SettingsPage};
use crate::state::{AppData, AppEvent};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

/// `speechSpeed` shown like the Mac's `%.2g×`, two significant digits: 1×,
/// 1.2×, 0.95×, 0.5×.
fn speed_label(speed: f64) -> String {
    let text = if speed < 1.0 {
        format!("{speed:.2}")
    } else {
        format!("{speed:.1}")
    };
    let text = text.trim_end_matches('0').trim_end_matches('.');
    format!("{text}×")
}

const SAMPLE_KEY: &str = "sample";

/// Controls that live as long as the Settings page.
pub struct OptionsState {
    speed: Entity<SliderState>,
    prompt: Entity<TextareaState>,
    server_url: Entity<InputState>,
    server_model: Entity<InputState>,
    server_key: Entity<InputState>,
    /// The approval checkbox's draft, for the origin in `server_origin`.
    server_consent: bool,
    server_origin: Option<String>,
    /// Asked of the credential store when the form first shows, since a locked
    /// store may prompt.
    server_key_saved: Option<bool>,
    server_error: Option<SharedString>,
}

impl OptionsState {
    pub fn new(settings: &Settings, window: &mut Window, cx: &mut Context<SettingsPage>) -> Self {
        let speed = kokoro::clamped_speed(settings.speech_speed) as f32;
        let server = RemoteTranscription::from_settings(settings);
        let origin = server.origin();
        Self {
            speed: cx.new(|_| {
                SliderState::new()
                    .min(kokoro::MIN_SPEED as f32)
                    .max(kokoro::MAX_SPEED as f32)
                    .step(0.05)
                    .default_value(speed)
            }),
            prompt: cx.new(|cx| {
                TextareaState::new(window, cx)
                    .rows(3)
                    .placeholder(crate::i18n::placeholder(
                        "Names, acronyms, and domain vocabulary",
                        window,
                        cx,
                    ))
                    .default_value(settings.transcription_prompt.clone())
            }),
            server_url: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::i18n::placeholder(
                        "https://api.openai.com/v1",
                        window,
                        cx,
                    ))
                    .default_value(settings.remote_transcription_base_url.clone())
            }),
            server_model: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::i18n::placeholder("whisper-1", window, cx))
                    .default_value(settings.remote_transcription_model.clone())
            }),
            server_key: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::i18n::placeholder("Optional", window, cx))
                    .masked(true)
            }),
            server_consent: is_approved(origin.as_deref(), settings),
            server_origin: origin,
            server_key_saved: None,
            server_error: None,
        }
    }

    pub fn subscribe(
        &self,
        window: &mut Window,
        cx: &mut Context<SettingsPage>,
    ) -> Vec<Subscription> {
        vec![
            cx.subscribe_in(
                &self.speed,
                window,
                |page, _, event: &SliderEvent, _, cx| {
                    let (SliderEvent::Change(value) | SliderEvent::Release(value)) = event;
                    // Slider steps as the Mac stores them: 1.05, not 1.0499999.
                    let speed = (f64::from(value.start()) * 20.0).round() / 20.0;
                    page.update_settings(move |s| s.speech_speed = speed, cx);
                },
            ),
            cx.subscribe_in(
                &self.prompt,
                window,
                |page, input, event: &InputEvent, _, cx| {
                    if matches!(event, InputEvent::Change) {
                        let value = input.read(cx).value().to_string();
                        page.update_settings(move |s| s.transcription_prompt = value, cx);
                    }
                },
            ),
            cx.subscribe_in(
                &self.server_url,
                window,
                |page, _, event: &InputEvent, _, cx| {
                    if matches!(event, InputEvent::Change) {
                        page.server_draft_changed(cx);
                    }
                },
            ),
            cx.subscribe_in(
                &self.server_model,
                window,
                |_, _, event: &InputEvent, _, cx| {
                    if matches!(event, InputEvent::Change) {
                        cx.notify();
                    }
                },
            ),
        ]
    }

    pub fn sync(&self, new: &Settings, window: &mut Window, cx: &mut App) {
        super::sync_slider(
            &self.speed,
            kokoro::clamped_speed(new.speech_speed) as f32,
            window,
            cx,
        );
        super::sync_text(&self.prompt, &new.transcription_prompt, window, cx);
        super::sync_input(
            &self.server_url,
            &new.remote_transcription_base_url,
            window,
            cx,
        );
        super::sync_input(
            &self.server_model,
            &new.remote_transcription_model,
            window,
            cx,
        );
    }
}

fn is_approved(origin: Option<&str>, settings: &Settings) -> bool {
    origin.is_some_and(|origin| {
        settings
            .approved_remote_transcription_origins
            .iter()
            .any(|approved| approved.eq_ignore_ascii_case(origin))
    })
}

/// The transcription model's name; a server names its model and host.
pub(super) fn transcription_name(settings: &Settings) -> String {
    if lokalbot_speech::models::is_remote(&settings.transcription_model) {
        RemoteTranscription::from_settings(settings).display_name()
    } else {
        super::models::model_name(&settings.transcription_model)
    }
}

/// "Download models from" (`ModelDownloadSourcePicker`), in Settings and onboarding.
pub(crate) fn download_source_row(
    current: ModelDownloadSource,
    focused: bool,
    on_select: impl Fn(ModelDownloadSource, &mut Window, &mut App) + 'static,
    cx: &App,
) -> impl gpui_kit::IntoElement {
    const SOURCES: [(ModelDownloadSource, &str); 3] = [
        (ModelDownloadSource::HuggingFace, "Hugging Face"),
        (ModelDownloadSource::HfMirror, "HF-Mirror (hf-mirror.com)"),
        (
            ModelDownloadSource::ModelScope,
            "ModelScope (modelscope.cn)",
        ),
    ];
    let detail = match current {
        ModelDownloadSource::HuggingFace => {
            "Downloads from huggingface.co, where the models are published."
        }
        ModelDownloadSource::HfMirror => {
            "A community mirror of Hugging Face that works in mainland China. If it fails, LokalBot tries Hugging Face."
        }
        ModelDownloadSource::ModelScope => {
            "Alibaba's model hub in mainland China, for files it carries unchanged. Other files come from HF-Mirror, then Hugging Face."
        }
    };
    let title = SOURCES
        .iter()
        .find(|(source, _)| *source == current)
        .map_or(SOURCES[0].1, |(_, title)| *title);
    settings_row::row(
        "settings.modelDownloadSource",
        lokalbot_i18n::tr("Download models from"),
        Some(lokalbot_i18n::tr(detail).into()),
        settings_row::picker(
            "settings-download-source",
            lokalbot_i18n::tr(title),
            SOURCES
                .iter()
                .map(|(source, title)| {
                    (
                        SharedString::from(lokalbot_i18n::tr(title)),
                        *source == current,
                    )
                })
                .collect(),
            move |index, window, cx| on_select(SOURCES[index].0, window, cx),
        ),
        focused,
        cx,
    )
}

/// The back button, title and subtitle of a Models subpage.
pub(super) fn subpage_header(
    page: Entity<SettingsPage>,
    title: &'static str,
    subtitle: &'static str,
    cx: &mut App,
) -> gpui_kit::Div {
    let lb = cx.lb().clone();
    v_flex()
        .gap(px(10.))
        .child(
            h_flex().child(
                Button::new("settings-models-back")
                    .ghost()
                    .small()
                    .icon(Icon::new(Ico::ChevronLeft))
                    .label(lokalbot_i18n::tr("Models"))
                    .on_click(move |_, _, cx| {
                        page.update(cx, |page, cx| {
                            page.models.page = ModelsPage::Active;
                            cx.notify();
                        });
                        stop_sample(cx);
                    }),
            ),
        )
        .child(
            div()
                .text_size(ty::SECTION)
                .font_weight(FontWeight::BOLD)
                .text_color(lb.text)
                .child(crate::ui::text::paragraph(title)),
        )
        .child(settings_row::help(subtitle, cx))
}

fn stop_sample(cx: &mut App) {
    let reading = AppData::global(cx).read(cx).speech.reading.clone();
    if reading.as_deref() == Some(SAMPLE_KEY) {
        crate::bridge::send(Command::Speech(SpeechCommand::Stop), cx);
    }
}

impl SettingsPage {
    /// The URL changed: an approval belongs to one origin, so show the saved
    /// choice for a newly entered server rather than carrying the toggle over.
    fn server_draft_changed(&mut self, cx: &mut Context<Self>) {
        let settings = self.data.read(cx).settings.clone();
        let origin = self.server_draft(&settings, cx).origin();
        let options = &mut self.models.options;
        if options.server_origin != origin {
            options.server_consent = is_approved(origin.as_deref(), &settings);
            options.server_origin = origin;
        }
        options.server_error = None;
        cx.notify();
    }

    /// The server form as a configuration, with the approval checkbox applied.
    fn server_draft(&self, settings: &Settings, cx: &App) -> RemoteTranscription {
        let options = &self.models.options;
        let mut draft = RemoteTranscription {
            base_url: options.server_url.read(cx).value().trim().to_string(),
            model: options.server_model.read(cx).value().trim().to_string(),
            approved_origins: settings.approved_remote_transcription_origins.clone(),
        };
        if let Some(origin) = draft.origin() {
            draft
                .approved_origins
                .retain(|approved| !approved.eq_ignore_ascii_case(&origin));
            if options.server_consent {
                draft.approved_origins.push(origin);
            }
        }
        draft
    }

    /// Saves the typed key and the approval, then switches once the server is
    /// allowed to receive audio. The approval list is replaced as a whole, so
    /// unchecking revokes the origin.
    fn use_transcription_server(&mut self, cx: &mut Context<Self>) {
        let settings = self.data.read(cx).settings.clone();
        let draft = self.server_draft(&settings, cx);
        if let Err(error) = draft.validated_endpoint() {
            self.models.options.server_error =
                Some(lokalbot_i18n::tr(&error.to_string()).to_string().into());
            cx.notify();
            return;
        }
        let key = self
            .models
            .options
            .server_key
            .read(cx)
            .value()
            .trim()
            .to_string();
        if !key.is_empty() {
            match lokalbot_engine::secrets::save_remote_transcription_api_key(&key) {
                Ok(()) => self.models.options.server_key_saved = Some(true),
                Err(error) => {
                    self.models.options.server_error = Some(format!("{error:#}").into());
                    cx.notify();
                    return;
                }
            }
        }
        let approved = draft.approved_origins.clone();
        self.update_settings(
            move |s| s.approved_remote_transcription_origins = approved,
            cx,
        );
        let patch = super::model_setup::ModelPatch {
            transcription: Some(remote_transcription::MODEL_ID.to_string()),
            remote_transcription_base_url: Some(draft.base_url.clone()),
            remote_transcription_model: Some(draft.model.clone()),
            ..Default::default()
        };
        let data = self.data.clone();
        self.models
            .setup
            .apply(patch, draft.display_name(), &data, cx);
        self.models.page = ModelsPage::Active;
        cx.notify();
    }

    /// Language & vocabulary (`ModelTranscriptionOptionsSheet`).
    pub(super) fn transcription_options_page(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let lb = cx.lb().clone();
        let settings = self.data.read(cx).settings.clone();
        let model = settings.transcription_model.clone();
        let name = transcription_name(&settings);
        let header = subpage_header(
            cx.entity(),
            lokalbot_i18n::tr("Language & vocabulary"),
            lokalbot_i18n::tr("Options for the transcription model currently in use."),
            cx,
        );

        let code = settings.transcription_language.clone();
        let picker_model = model.clone();
        let language_data = self.data.clone();
        let picker = Button::new("settings-transcription-language")
            .outline()
            .small()
            .label(lokalbot_i18n::tr(language::language_name(&code)))
            .dropdown_caret(true)
            .dropdown_menu(move |mut menu, _, _| {
                menu = menu.scrollable(true);
                for (option, title) in language::TRANSCRIPTION_LANGUAGES {
                    let data = language_data.clone();
                    menu = menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr(title))
                            .checked(code == option)
                            .disabled(!language::is_language_selectable(&picker_model, option))
                            .on_click(move |_, _, cx| {
                                data.update(cx, |data, cx| {
                                    data.update_settings(
                                        |s| s.transcription_language = option.to_string(),
                                        cx,
                                    )
                                })
                            }),
                    );
                }
                menu
            });
        let message =
            language::language_selection_message(&model, &settings.transcription_language);
        let language_row = settings_row::row(
            "settings.transcriptionLanguage",
            lokalbot_i18n::tr("Language"),
            message.map(|message| lokalbot_i18n::tr(message).into()),
            picker,
            self.is_focused("settings.transcriptionLanguage"),
            cx,
        );

        let vocabulary_row = settings_row::content_row(
            "settings.transcriptionPrompt",
            v_flex()
                .gap(px(6.))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(lb.text)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "Names and vocabulary",
                        ))),
                )
                .child(
                    Textarea::new(&self.models.options.prompt)
                        .h(px(72.))
                        .text_size(ty::BODY),
                ),
            self.is_focused("settings.transcriptionPrompt"),
            cx,
        );

        let names_data = self.data.clone();
        let names_row = settings_row::row(
            "settings.autoTranscriptionVocabulary",
            lokalbot_i18n::tr("Add names LokalBot already knows"),
            Some(lokalbot_i18n::tr("Calendar attendee names, names you applied in related meetings, and active project names are added on this PC. Email addresses are never used.").into()),
            settings_row::switch(
                "settings.autoTranscriptionVocabulary",
                settings.auto_transcription_vocabulary,
                move |on, _, cx| {
                    names_data.update(cx, |data, cx| {
                        data.update_settings(|s| s.auto_transcription_vocabulary = on, cx)
                    })
                },
            ),
            self.is_focused("settings.autoTranscriptionVocabulary"),
            cx,
        );

        let mut section = Section::new(None)
            .row(
                "settings.transcriptionModel",
                settings_row::row(
                    "settings.transcriptionModel",
                    lokalbot_i18n::tr("Model"),
                    None,
                    settings_row::value(name.clone(), cx),
                    false,
                    cx,
                ),
            )
            .row("settings.transcriptionLanguage", language_row)
            .row("settings.transcriptionPrompt", vocabulary_row)
            .row("settings.autoTranscriptionVocabulary", names_row);
        if lokalbot_speech::models::is_remote(&model) {
            section = section.row(
                "settings.transcriptionVocabularyRemote",
                settings_row::content_row(
                    "settings.transcriptionVocabularyRemote",
                    settings_row::help(
                        lokalbot_i18n::tr("Your transcription server receives this vocabulary, including any added names, with the audio."),
                        cx,
                    ),
                    false,
                    cx,
                ),
            );
        }
        if !lokalbot_speech::models::accepts_vocabulary(&model) {
            section = section.row(
                "settings.transcriptionVocabularyIgnored",
                settings_row::content_row(
                    "settings.transcriptionVocabularyIgnored",
                    settings_row::help(
                        lokalbot_i18n::format(
                            "{0} ignores vocabulary. Qwen3-ASR uses it.",
                            &[("0", name)],
                        ),
                        cx,
                    ),
                    false,
                    cx,
                ),
            );
        }
        vec![
            Section::new(None).row(
                "settings.modelsHeader",
                settings_row::content_row("settings.modelsHeader", header, false, cx),
            ),
            section,
        ]
    }

    /// The server form (`remoteTranscriptionSetup`).
    pub(super) fn transcription_server_page(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let lb = cx.lb().clone();
        let settings = self.data.read(cx).settings.clone();
        let draft = self.server_draft(&settings, cx);
        let header = subpage_header(
            cx.entity(),
            lokalbot_i18n::tr("Transcription server"),
            lokalbot_i18n::tr(
                "OpenAI-style speech-to-text on a server you choose: OpenAI, Groq, OpenRouter, or whisper.cpp on another device. Sends audio to that server.",
            ),
            cx,
        );
        let field =
            |title: &'static str, help: Option<&'static str>, input: AnyElement, cx: &App| {
                v_flex()
                    .gap(px(5.))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .text_color(cx.lb().text)
                            .child(crate::ui::text::paragraph(title)),
                    )
                    .child(input)
                    .when_some(help, |this, help| this.child(settings_row::help(help, cx)))
            };
        let key_saved = *self.models.options.server_key_saved.get_or_insert_with(|| {
            lokalbot_engine::secrets::remote_transcription_api_key().is_some()
        });
        let options = &self.models.options;
        let uses_think_key = !key_saved
            && options.server_key.read(cx).value().is_empty()
            && remote_transcription::uses_think_key(&draft.base_url, &settings.openai_base_url);
        let forget_page = cx.entity();
        let key_input = h_flex()
            .gap(px(8.))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .child(Input::new(&options.server_key).mask_toggle()),
            )
            .when(key_saved, |this| {
                this.child(
                    Button::new("settings-server-forget-key")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Forget"))
                        .on_click(move |_, _, cx| {
                            forget_page.update(cx, |page, cx| {
                                let options = &mut page.models.options;
                                match lokalbot_engine::secrets::save_remote_transcription_api_key(
                                    "",
                                ) {
                                    Ok(()) => options.server_key_saved = Some(false),
                                    Err(error) => {
                                        options.server_error = Some(format!("{error:#}").into())
                                    }
                                }
                                cx.notify();
                            })
                        }),
                )
            });
        let key_help = if key_saved {
            Some(lokalbot_i18n::tr("Saved in the system credential store."))
        } else if uses_think_key {
            Some(lokalbot_i18n::tr("Uses your Think key for this server."))
        } else {
            None
        };
        let form = v_flex()
            .gap(px(14.))
            .py(px(4.))
            .child(field(
                lokalbot_i18n::tr("Server URL"),
                Some(lokalbot_i18n::tr(
                    "Use the provider's /v1 URL, or end with /inference for whisper.cpp.",
                )),
                Input::new(&options.server_url).into_any_element(),
                cx,
            ))
            .child(field(
                lokalbot_i18n::tr("Model"),
                Some(lokalbot_i18n::tr(
                    "Leave empty if the server runs one model.",
                )),
                Input::new(&options.server_model).into_any_element(),
                cx,
            ))
            .child(field(
                lokalbot_i18n::tr("API key"),
                key_help,
                key_input.into_any_element(),
                cx,
            ))
            .children(self.server_access(&draft, cx));
        let error = self.models.options.server_error.clone();
        let use_page = cx.entity();
        let options_page = cx.entity();
        let actions = h_flex()
            .gap(px(12.))
            .items_center()
            .child(
                Button::new("settings-use-server")
                    .primary()
                    .small()
                    .label(lokalbot_i18n::tr("Use This Server"))
                    .disabled(self.models.setup.is_switching())
                    .on_click(move |_, _, cx| {
                        use_page.update(cx, |page, cx| page.use_transcription_server(cx))
                    }),
            )
            .child(settings_row::link_button(
                "settings-server-options",
                lokalbot_i18n::tr("Language & vocabulary…"),
                move |_, cx| {
                    options_page.update(cx, |page, cx| {
                        page.models.page = ModelsPage::TranscriptionOptions;
                        cx.notify();
                    })
                },
                cx,
            ));
        vec![
            Section::new(None).row(
                "settings.modelsHeader",
                settings_row::content_row("settings.modelsHeader", header, false, cx),
            ),
            Section::new(None).row(
                "settings.remoteTranscription",
                settings_row::content_row(
                    "settings.remoteTranscription",
                    v_flex().gap(px(14.)).child(form).child(actions).when_some(
                        error,
                        |this, message| {
                            this.child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.attention_text)
                                    .child(crate::ui::text::paragraph(message)),
                            )
                        },
                    ),
                    self.is_focused("settings.remoteTranscription"),
                    cx,
                ),
            ),
        ]
    }

    /// Where the audio goes and its per-origin approval (`remoteTranscriptionAccess`).
    fn server_access(&self, draft: &RemoteTranscription, cx: &mut Context<Self>) -> Option<Div> {
        let lb = cx.lb().clone();
        let Some(endpoint) = draft.endpoint() else {
            return draft.is_configured().then(|| {
                h_flex().child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Use an http or https transcription server URL without a query or a user name."))),
                )
            });
        };
        if draft.is_on_this_computer() {
            return Some(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(ui::icon(Ico::ShieldCheck, px(14.), lb.success_text))
                    .child(settings_row::help(
                        lokalbot_i18n::tr("Runs on this PC. Audio stays here."),
                        cx,
                    )),
            );
        }
        let origin = draft.origin()?;
        let encrypted = origin.starts_with("https://");
        if !encrypted && !is_private_network_url(&endpoint) {
            return Some(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(ui::icon(Ico::Lock, px(14.), lb.attention_text))
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.attention_text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Use HTTPS for a server outside your network or tailnet.",
                            ))),
                    ),
            );
        }
        let page = cx.entity();
        let consent = self.models.options.server_consent;
        Some(
            v_flex()
                .gap(px(8.))
                .p(px(12.))
                .rounded(px(8.))
                .bg(lb.status_fill(lb.attention))
                .border_1()
                .border_color(lb.status_stroke(lb.attention))
                .child(
                    h_flex()
                        .gap(px(10.))
                        .items_center()
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .text_size(ty::BODY)
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(lb.text)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                    "Send audio to {0}",
                                    &[("0", origin)],
                                ))),
                        )
                        .child(settings_row::switch(
                            "settings-server-consent",
                            consent,
                            move |on, _, cx| {
                                page.update(cx, |page, cx| {
                                    page.models.options.server_consent = on;
                                    page.models.options.server_error = None;
                                    cx.notify();
                                })
                            },
                        )),
                )
                .child(settings_row::help(
                    lokalbot_i18n::tr("Meetings, dictation, and your vocabulary go to this server, including automatically after each meeting."),
                    cx,
                ))
                .when(!encrypted, |this| {
                    this.child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.attention_text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Unencrypted HTTP: use it only on your own network or tailnet.",
                            ))),
                    )
                }),
        )
    }

    /// The row under "Also used by LokalBot" that opens the page below.
    pub(super) fn read_aloud_row(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let page = cx.entity();
        settings_row::row(
            "settings.speechVoice",
            lokalbot_i18n::tr("Read aloud"),
            Some(lokalbot_i18n::tr("Kokoro 82M · On this PC").into()),
            settings_row::link_button(
                "settings-read-aloud",
                lokalbot_i18n::tr("Change…"),
                move |_, cx| {
                    page.update(cx, |page, cx| {
                        page.models.page = ModelsPage::ReadAloud;
                        cx.notify();
                    })
                },
                cx,
            ),
            self.is_focused("settings.speechVoice"),
            cx,
        )
        .into_any_element()
    }

    pub(super) fn read_aloud_page(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let lb = cx.lb().clone();
        let (settings, installed, download, speech) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.models.installed.iter().any(|id| id == KOKORO_MODEL),
                data.downloads.get(KOKORO_MODEL).cloned(),
                data.speech.clone(),
            )
        };
        let downloading = download.as_ref().is_some_and(|d| d.error.is_none());
        let download_error = download.as_ref().and_then(|d| d.error.clone());
        let sample_error = speech
            .error
            .as_ref()
            .filter(|(key, _)| key == SAMPLE_KEY)
            .map(|(_, message)| SharedString::from(lokalbot_i18n::tr(message).to_string()));
        let playing = speech.reading.as_deref() == Some(SAMPLE_KEY);

        let header = subpage_header(
            cx.entity(),
            lokalbot_i18n::tr("Read aloud"),
            lokalbot_i18n::tr("Read summaries and answers using a voice on this PC."),
            cx,
        );

        let voice_data = self.data.clone();
        let current = kokoro::voice(&settings.speech_voice);
        let voice_row = settings_row::row(
            "settings.speechVoice",
            lokalbot_i18n::tr("Voice"),
            None,
            settings_row::picker(
                "settings-speech-voice",
                current.display_name,
                kokoro::VOICES
                    .iter()
                    .map(|voice| {
                        (
                            SharedString::from(voice.display_name),
                            voice.id == current.id,
                        )
                    })
                    .collect(),
                move |index, _, cx| {
                    let id = kokoro::VOICES[index].id;
                    voice_data.update(cx, |data, cx| {
                        data.update_settings(|s| s.speech_voice = id.into(), cx)
                    });
                },
            ),
            self.is_focused("settings.speechVoice"),
            cx,
        );
        let speed_row = settings_row::row(
            "settings.speechSpeed",
            lokalbot_i18n::tr("Speed"),
            None,
            h_flex()
                .gap(px(12.))
                .items_center()
                .child(
                    div()
                        .w(px(220.))
                        .child(Slider::new(&self.models.options.speed)),
                )
                .child(
                    div()
                        .w(px(42.))
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .child(speed_label(kokoro::clamped_speed(settings.speech_speed))),
                ),
            false,
            cx,
        );

        let sample_data = self.data.clone();
        let action: AnyElement = if installed {
            Button::new("settings-speech-sample")
                .outline()
                .small()
                .label(if playing {
                    lokalbot_i18n::tr("Stop sample")
                } else {
                    lokalbot_i18n::tr("Play sample")
                })
                .on_click(move |_, _, cx| {
                    let command = if playing {
                        SpeechCommand::Stop
                    } else {
                        SpeechCommand::Read {
                            key: SAMPLE_KEY.into(),
                            // Spoken by an English voice in every interface language.
                            text: "Here is a sample of LokalBot's voice. Your summaries can be read aloud on this PC.".to_string(),
                        }
                    };
                    crate::bridge::send(Command::Speech(command), cx);
                })
                .into_any_element()
        } else if downloading {
            let fraction = download.as_ref().map(|d| d.fraction()).unwrap_or(0.);
            h_flex()
                .gap(px(10.))
                .items_center()
                .child(settings_row::help(
                    lokalbot_i18n::format(
                        "Downloading · {0}%",
                        &[("0", format!("{}", (fraction * 100.).round()))],
                    ),
                    cx,
                ))
                .child(
                    Button::new("settings-speech-cancel")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Cancel"))
                        .on_click(move |_, _, cx| {
                            sample_data.update(cx, |data, cx| {
                                data.request(AppEvent::CancelDownload(KOKORO_MODEL.into()), cx)
                            })
                        }),
                )
                .into_any_element()
        } else {
            Button::new("settings-speech-download")
                .primary()
                .small()
                .label(lokalbot_i18n::tr("Download voice model"))
                .on_click(move |_, _, cx| {
                    sample_data.update(cx, |data, cx| {
                        data.request(AppEvent::DownloadModel(KOKORO_MODEL.into()), cx)
                    })
                })
                .into_any_element()
        };
        let action_row = settings_row::content_row(
            "settings.speechSample",
            v_flex()
                .gap(px(8.))
                .child(h_flex().child(action))
                .child(settings_row::help(
                    if installed {
                        lokalbot_i18n::tr("Downloaded. Voice synthesis runs locally.")
                    } else {
                        lokalbot_i18n::tr("Download once to use this voice offline.")
                    },
                    cx,
                ))
                .when_some(sample_error.or(download_error), |this, message| {
                    this.child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.attention_text)
                            .child(crate::ui::text::paragraph(message)),
                    )
                }),
            false,
            cx,
        );

        vec![
            Section::new(None).row(
                "settings.modelsHeader",
                settings_row::content_row("settings.modelsHeader", header, false, cx),
            ),
            Section::new(None)
                .row(
                    "settings.speechModel",
                    settings_row::row(
                        "settings.speechModel",
                        lokalbot_i18n::tr("Model"),
                        None,
                        settings_row::value("Kokoro 82M", cx),
                        false,
                        cx,
                    ),
                )
                .row("settings.speechVoice", voice_row)
                .row("settings.speechSpeed", speed_row)
                .row("settings.speechSample", action_row),
        ]
    }

    /// Read aloud's model in Model Storage, once there is something to show
    /// (`ModelDownloadsView.speechRow`).
    pub(super) fn read_aloud_storage_row(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let lb = cx.lb().clone();
        let (installed, download) = {
            let data = self.data.read(cx);
            (
                data.models.installed.iter().any(|id| id == KOKORO_MODEL),
                data.downloads.get(KOKORO_MODEL).cloned(),
            )
        };
        let error = download.as_ref().and_then(|d| d.error.clone());
        let downloading = download.as_ref().is_some_and(|d| d.error.is_none());
        if !installed && !downloading && error.is_none() {
            return None;
        }
        let data = self.data.clone();
        let button = if downloading {
            Button::new("settings-remove-kokoro")
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Cancel"))
                .on_click(move |_, _, cx| {
                    data.update(cx, |data, cx| {
                        data.request(AppEvent::CancelDownload(KOKORO_MODEL.into()), cx)
                    })
                })
        } else if installed {
            Button::new("settings-remove-kokoro")
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Remove…"))
                .on_click(move |_, window, cx| confirm_remove_voice(data.clone(), window, cx))
        } else {
            Button::new("settings-remove-kokoro")
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Retry"))
                .on_click(move |_, _, cx| {
                    data.update(cx, |data, cx| {
                        data.request(AppEvent::DownloadModel(KOKORO_MODEL.into()), cx)
                    })
                })
        };
        let detail: SharedString = if downloading {
            let fraction = download.as_ref().map(|d| d.fraction()).unwrap_or(0.);
            lokalbot_i18n::format(
                "Downloading · {0}%",
                &[("0", format!("{}", (fraction * 100.).round()))],
            )
            .into()
        } else {
            lokalbot_i18n::tr("Used by Read aloud").into()
        };
        Some(
            settings_row::content_row(
                "settings-storage-kokoro",
                h_flex()
                    .gap(px(12.))
                    .items_center()
                    .child(ui::icon(Ico::Volume2, px(16.), lb.text_secondary))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .child("Kokoro 82M"),
                            )
                            .child(settings_row::help(detail, cx))
                            .when_some(error, |this, message| {
                                this.child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(lb.attention_text)
                                        .child(crate::ui::text::paragraph(message)),
                                )
                            }),
                    )
                    .child(button),
                false,
                cx,
            )
            .into_any_element(),
        )
    }
}

fn confirm_remove_voice(data: Entity<AppData>, window: &mut Window, cx: &mut App) {
    window.open_alert_dialog(cx, move |alert, _, _| {
        let data = data.clone();
        alert
            .title(lokalbot_i18n::tr("Remove downloaded model?"))
            .description(lokalbot_i18n::format(
                "Remove the downloaded files for {0}? {1} Your recordings and transcripts are kept.",
                &[
                    ("0", "Kokoro 82M".to_string()),
                    (
                        "1",
                        lokalbot_i18n::tr("Read aloud will need this model downloaded again.")
                            .to_string(),
                    ),
                ],
            ))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Remove download"))
            .ok_variant(ButtonVariant::Danger)
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                data.update(cx, |data, cx| {
                    data.request(AppEvent::DeleteModel(KOKORO_MODEL.into()), cx)
                });
                true
            })
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speed_label_reads_like_the_mac() {
        assert_eq!(speed_label(1.0), "1×");
        assert_eq!(speed_label(0.5), "0.5×");
        assert_eq!(speed_label(1.25), "1.2×");
        assert_eq!(speed_label(1.05), "1.1×");
        assert_eq!(speed_label(0.95), "0.95×");
        assert_eq!(speed_label(0.6), "0.6×");
        assert_eq!(speed_label(2.0), "2×");
    }
}
