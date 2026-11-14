//! Models (`ModelsView.swift`, `ModelConnectionsView.swift`): the model
//! catalog helpers, the pages Models opens, the "Change…" menus and Online
//! services (the servers and plan sign-ins Think can use, and what is
//! approved to receive data). The first page is `model_overview`.
//!
//! Names and sizes come from the catalogs: `lokalbot_ai::catalog` for text
//! models, `lokalbot_speech::models` for speech, `lokalbot_ai::runtime` for
//! the llama.cpp binaries.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Div, Entity, FontWeight, IntoElement as _,
    ParentElement as _, SharedString, Styled as _, Subscription, Window, div, px,
};
use lokalbot_agent::session::reasoning_name;
use lokalbot_core::Settings;
use lokalbot_core::settings::{
    GenerationBudget, ReasoningLevel, SubscriptionPlan, SummarizerBackend,
};

use super::model_setup::{ModelPatch, ModelSetup};
use super::status::Role;
use super::{Section, SettingsPage};
use crate::state::{AppData, AppEvent};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

/// A picker entry: label, whether it is current, what choosing it changes, and
/// its name while it prepares.
type ModelChoice = (SharedString, bool, ModelPatch, String);

/// The default transcription model on Linux and Windows.
const DEFAULT_SPEECH_MODEL: &str = lokalbot_speech::models::DEFAULT_TRANSCRIPTION_MODEL;

/// The engine's id for the llama.cpp binaries (`lokalbot_engine` `RUNTIME_ID`).
pub const RUNTIME_ID: &str = "llama-runtime";

/// Display name of a speech or text model id.
pub fn model_name(id: &str) -> String {
    if let Some(entry) = lokalbot_ai::catalog::entry(id) {
        return entry.display_name.to_string();
    }
    if id == RUNTIME_ID {
        return "llama.cpp runtime".into();
    }
    if id == lokalbot_ai::ocr::OCR_MODEL_ID {
        return lokalbot_ai::ocr::OCR_DISPLAY_NAME.into();
    }
    if id == lokalbot_ai::ocr::OCR_LANGUAGES_ID {
        return lokalbot_ai::ocr::OCR_LANGUAGES_DISPLAY_NAME.into();
    }
    if lokalbot_speech::models::is_remote(id) {
        return lokalbot_i18n::tr("Transcription server").into();
    }
    lokalbot_speech::models::find(id)
        .map(|m| m.display_name.to_string())
        .unwrap_or_else(|| id.to_string())
}

/// What Transcribe downloads: its model, unless a server does the work, with
/// voice detection and speaker separation when on.
pub fn speech_needs(settings: &Settings) -> Vec<String> {
    let mut ids = Vec::new();
    if !lokalbot_speech::models::is_remote(&settings.transcription_model) {
        ids.push(settings.transcription_model.clone());
    }
    ids.extend(lokalbot_speech::models::supporting_ids(
        settings.multi_speaker_diarization,
    ));
    ids
}

/// Download size of a model id from its catalog. The llama.cpp runtime is
/// includes the optional CUDA libraries until system reuse is established.
pub fn model_bytes(id: &str, settings: &Settings) -> u64 {
    if let Some(entry) = lokalbot_ai::catalog::entry(id) {
        return entry.size_bytes;
    }
    if id == RUNTIME_ID {
        return lokalbot_ai::runtime::download_bytes(&settings.llama_backend);
    }
    if id == lokalbot_ai::ocr::OCR_MODEL_ID {
        return lokalbot_ai::ocr::total_size();
    }
    if id == lokalbot_ai::ocr::OCR_LANGUAGES_ID {
        return lokalbot_ai::ocr::languages_size();
    }
    lokalbot_speech::models::find(id)
        .map(|m| m.archive.size)
        .unwrap_or(0)
}

/// Model ids the current settings use on this PC: the engine's meeting,
/// dictation, search and screen text requirements, and Autocomplete's model
/// while autocomplete is on.
pub fn models_in_use(settings: &Settings) -> Vec<String> {
    let mut ids = speech_needs(settings);
    let built_in = settings.summarizer_backend == SummarizerBackend::BuiltIn;
    if built_in {
        ids.push(settings.built_in_model_id.clone());
    }
    if settings.semantic_search_enabled {
        ids.push(lokalbot_ai::catalog::EMBEDDING_MODEL_ID.to_string());
    }
    let autocomplete_on_device = settings.cotyping_enabled
        && settings.cotyping_backend == lokalbot_core::settings::CotypingBackend::OnDevice;
    if autocomplete_on_device {
        ids.push(settings.cotyping_built_in_model_id.clone());
    }
    if built_in || settings.semantic_search_enabled || autocomplete_on_device {
        ids.push(RUNTIME_ID.to_string());
    }
    if settings.screen_context_capture_mode != lokalbot_core::ScreenContextMode::ActivityOnly {
        ids.push(lokalbot_ai::ocr::OCR_MODEL_ID.to_string());
        ids.push(lokalbot_ai::ocr::OCR_LANGUAGES_ID.to_string());
    }
    ids
}

/// The name of the engine reading screen text here.
pub fn screen_text_engine_name(status: &lokalbot_ai::ocr::OcrStatus) -> &'static str {
    match status.backend {
        lokalbot_ai::ocr::OcrBackend::Tesseract => "Screen text recognition (Tesseract)",
        lokalbot_ai::ocr::OcrBackend::Windows => "Screen text recognition (Windows)",
        _ => lokalbot_ai::ocr::OCR_DISPLAY_NAME,
    }
}

/// What Autocomplete downloads: its model and the llama.cpp runtime. A
/// server needs no download.
pub fn autocomplete_needs(settings: &Settings) -> Vec<String> {
    if settings.cotyping_backend != lokalbot_core::settings::CotypingBackend::OnDevice {
        return Vec::new();
    }
    vec![
        settings.cotyping_built_in_model_id.clone(),
        RUNTIME_ID.to_string(),
    ]
}

/// Downloaded models the current settings don't use, in catalog order.
pub fn unused_models(settings: &Settings, installed: &[String]) -> Vec<String> {
    let in_use = models_in_use(settings);
    installed
        .iter()
        // Read aloud's voice has its own row, and no setting turns it off.
        .filter(|id| !in_use.contains(id) && id.as_str() != lokalbot_speech::models::KOKORO_MODEL)
        .cloned()
        .collect()
}

/// What a downloaded model is for, for the storage list.
pub(super) fn model_purpose(id: &str) -> &'static str {
    if id == RUNTIME_ID {
        return lokalbot_i18n::tr("Runs Think, Autocomplete and search models");
    }
    if id == lokalbot_ai::catalog::EMBEDDING_MODEL_ID {
        return lokalbot_i18n::tr("Search by meaning");
    }
    if id == lokalbot_ai::ocr::OCR_MODEL_ID || id == lokalbot_ai::ocr::OCR_LANGUAGES_ID {
        return lokalbot_i18n::tr("Reads screen text");
    }
    if let Some(entry) = lokalbot_ai::catalog::entry(id) {
        return if entry.think {
            lokalbot_i18n::tr("Think model")
        } else {
            lokalbot_i18n::tr("Autocomplete model")
        };
    }
    match lokalbot_speech::models::find(id).map(|m| m.kind) {
        Some(lokalbot_speech::models::ModelKind::Transcription(_)) => {
            lokalbot_i18n::tr("Transcribe model")
        }
        Some(lokalbot_speech::models::ModelKind::VoiceActivity) => {
            lokalbot_i18n::tr("Finds speech in recordings")
        }
        Some(lokalbot_speech::models::ModelKind::SpeechSynthesis) => {
            lokalbot_i18n::tr("Used by Read aloud")
        }
        Some(_) => lokalbot_i18n::tr("Separates speakers"),
        None => lokalbot_i18n::tr("Model"),
    }
}

/// "2.7 GB", "730 MB".
pub fn size_label(bytes: u64) -> String {
    let gb = bytes as f64 / 1_000_000_000.0;
    if gb >= 1.0 {
        lokalbot_i18n::format("{gb} GB", &[("gb", format!("{:.1}", gb))])
    } else {
        lokalbot_i18n::format(
            "{0} MB",
            &[("0", format!("{}", (bytes as f64 / 1_000_000.0).round()))],
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Preset {
    Balanced,
    Lightweight,
}

impl Preset {
    pub const ALL: [Preset; 2] = [Preset::Balanced, Preset::Lightweight];

    pub fn title(self) -> &'static str {
        match self {
            Preset::Balanced => lokalbot_ai::catalog::PRESETS[0].name,
            Preset::Lightweight => lokalbot_ai::catalog::PRESETS[1].name,
        }
    }

    pub fn subtitle(self) -> &'static str {
        match self {
            Preset::Balanced => lokalbot_ai::catalog::PRESETS[0].description,
            Preset::Lightweight => lokalbot_ai::catalog::PRESETS[1].description,
        }
    }

    /// Transcribe and Think model ids (`lokalbot_ai::catalog::PRESETS`).
    /// Autocomplete keeps its own model here: its lighter default suits
    /// suggestions on a CPU, and a preset should not swap it unasked.
    pub fn models(self) -> (&'static str, &'static str) {
        let index = match self {
            Preset::Balanced => 0,
            Preset::Lightweight => 1,
        };
        (
            DEFAULT_SPEECH_MODEL,
            lokalbot_ai::catalog::PRESETS[index].think,
        )
    }

    pub fn summary(self) -> String {
        let (speech, think) = self.models();
        lokalbot_i18n::format(
            "Transcribe: {0}, Think: {1}",
            &[
                ("0", model_name(speech).to_string()),
                ("1", model_name(think).to_string()),
            ],
        )
    }

    pub fn matches(self, settings: &Settings) -> bool {
        let (speech, think) = self.models();
        settings.summarizer_backend == SummarizerBackend::BuiltIn
            && settings.transcription_model == speech
            && settings.built_in_model_id == think
    }

    pub(crate) fn patch(self) -> ModelPatch {
        let (speech, think) = self.models();
        ModelPatch {
            transcription: Some(speech.to_string()),
            backend: Some(SummarizerBackend::BuiltIn),
            assistant_model_id: Some(think.to_string()),
            ..Default::default()
        }
    }
}

pub(super) fn budget_label(budget: GenerationBudget) -> &'static str {
    match budget {
        GenerationBudget::Conservative => lokalbot_i18n::tr("Conservative"),
        GenerationBudget::Standard => lokalbot_i18n::tr("Default"),
        GenerationBudget::Generous => lokalbot_i18n::tr("Generous"),
        GenerationBudget::Unlimited => lokalbot_i18n::tr("Unlimited"),
    }
}

pub(super) fn budget_detail(budget: GenerationBudget) -> &'static str {
    match budget {
        GenerationBudget::Conservative => lokalbot_i18n::tr(
            "Half the normal time and tokens. Long meetings may need a second pass.",
        ),
        GenerationBudget::Standard => lokalbot_i18n::tr(
            "Balanced limits that grow with meeting length, so most meetings finish in one pass.",
        ),
        GenerationBudget::Generous => lokalbot_i18n::tr(
            "Three times the normal limits for very long meetings or slower servers.",
        ),
        GenerationBudget::Unlimited => {
            lokalbot_i18n::tr("Runs until finished, with a 6-hour safety stop.")
        }
    }
}

pub(super) const BUDGETS: [GenerationBudget; 4] = [
    GenerationBudget::Conservative,
    GenerationBudget::Standard,
    GenerationBudget::Generous,
    GenerationBudget::Unlimited,
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelsPage {
    /// What each model does, More and Advanced (`ModelStackOverviewView`).
    Active,
    /// Online services: what is approved, then the connections
    /// (`ModelRemoteOverview`, `ModelConnectionsView`).
    Connections,
    /// The models on this computer (`ModelDownloadsView`).
    Downloaded,
    /// Dictation's Compose, Read aloud and search by meaning
    /// (`ModelOtherModelsView`).
    Other,
    /// Voice, speed and the sample (`ModelSpeechSettingsSheet`).
    ReadAloud,
    /// `ModelTranscriptionOptionsSheet`.
    TranscriptionOptions,
    /// `ModelPickerSheet.remoteTranscriptionSetup`.
    TranscriptionServer,
    /// `ModelChecksSheet`.
    Checks,
    /// `ModelImportSheet`.
    Browse,
}

impl ModelsPage {
    pub fn for_setting(id: &str) -> Self {
        match id {
            "settings.summarizerBackend"
            | "settings.openAIBaseURL"
            | "settings.openAIModel"
            | "settings.ollamaBaseURL" => ModelsPage::Connections,
            "settings.unusedModels" => ModelsPage::Downloaded,
            "settings.semanticSearchEnabled" => ModelsPage::Other,
            "settings.speechVoice" | "settings.speechSpeed" => ModelsPage::ReadAloud,
            "settings.transcriptionLanguage"
            | "settings.transcriptionPrompt"
            | "settings.autoTranscriptionVocabulary" => ModelsPage::TranscriptionOptions,
            "settings.remoteTranscription" => ModelsPage::TranscriptionServer,
            super::status::MODEL_CHECKS_FOCUS => ModelsPage::Checks,
            "settings.modelBrowse" => ModelsPage::Browse,
            _ => ModelsPage::Active,
        }
    }
}

/// The Models subpage and the connection form drafts.
pub struct ModelsState {
    pub page: ModelsPage,
    /// Advanced, under More, is open (`settings.models.advancedOpen`).
    pub(super) advanced_open: bool,
    /// The connection form shown: OpenAI-compatible, Ollama, or a plan.
    connection: SummarizerBackend,
    /// ChatGPT and Claude plan accounts, loaded when their form shows.
    pub(super) plans: super::plans::PlansState,
    openai_url: Entity<InputState>,
    openai_model: Entity<InputState>,
    api_key: Entity<InputState>,
    ollama_url: Entity<InputState>,
    ollama_model: Entity<InputState>,
    saved: Option<SharedString>,
    pub(super) options: super::model_options::OptionsState,
    pub(super) setup: ModelSetup,
    pub(super) browse: super::model_browse::BrowseState,
    /// The model last asked about for its reasoning levels.
    reasoning_asked: Option<String>,
    /// What the saved Ollama server has installed, once asked.
    ollama_models: Vec<String>,
    listing_ollama: bool,
    ollama_list_problem: Option<SharedString>,
}

impl ModelsState {
    pub fn new(settings: &Settings, window: &mut Window, cx: &mut Context<SettingsPage>) -> Self {
        let field = |placeholder: &'static str,
                     value: &str,
                     window: &mut Window,
                     cx: &mut Context<SettingsPage>| {
            let value = value.to_string();
            cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::i18n::placeholder(placeholder, window, cx))
                    .default_value(value)
            })
        };
        Self {
            page: ModelsPage::Active,
            advanced_open: false,
            connection: match settings.summarizer_backend {
                SummarizerBackend::BuiltIn => SummarizerBackend::OpenAICompatible,
                other => other,
            },
            plans: Default::default(),
            openai_url: field(
                "https://example.com/v1",
                &settings.openai_base_url,
                window,
                cx,
            ),
            openai_model: field(
                "Provider model identifier",
                &settings.openai_model,
                window,
                cx,
            ),
            api_key: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::i18n::placeholder("API key (optional)", window, cx))
                    .masked(true)
            }),
            ollama_url: field(
                "http://localhost:11434",
                &settings.ollama_base_url,
                window,
                cx,
            ),
            ollama_model: field("Ollama model name", &settings.ollama_model, window, cx),
            saved: None,
            options: super::model_options::OptionsState::new(settings, window, cx),
            setup: ModelSetup::default(),
            browse: super::model_browse::BrowseState::new(window, cx),
            reasoning_asked: None,
            ollama_models: Vec::new(),
            listing_ollama: false,
            ollama_list_problem: None,
        }
    }

    pub fn subscribe(
        state: &Self,
        window: &mut Window,
        cx: &mut Context<SettingsPage>,
    ) -> Vec<Subscription> {
        let mut subscriptions: Vec<Subscription> = [
            &state.openai_url,
            &state.openai_model,
            &state.ollama_url,
            &state.ollama_model,
        ]
        .into_iter()
        .map(|input| {
            cx.subscribe_in(input, window, |page, _, event: &InputEvent, _, cx| {
                if matches!(event, InputEvent::Change) {
                    page.models.saved = None;
                    cx.notify();
                }
            })
        })
        .collect();
        subscriptions.extend(state.options.subscribe(window, cx));
        subscriptions.extend(state.browse.subscribe(window, cx));
        subscriptions
    }

    /// Follows connection settings changed elsewhere, unless the user is editing.
    pub fn sync(
        &mut self,
        old: &Settings,
        new: &Settings,
        window: &mut Window,
        cx: &mut Context<SettingsPage>,
    ) {
        for (input, before, after) in [
            (&self.openai_url, &old.openai_base_url, &new.openai_base_url),
            (&self.openai_model, &old.openai_model, &new.openai_model),
            (&self.ollama_url, &old.ollama_base_url, &new.ollama_base_url),
            (&self.ollama_model, &old.ollama_model, &new.ollama_model),
        ] {
            if before != after {
                super::sync_input(input, after, window, cx);
            }
        }
        self.options.sync(new, window, cx);
    }

    fn draft(&self, cx: &App) -> (String, String) {
        let (url, model) = match self.connection {
            SummarizerBackend::Ollama => (&self.ollama_url, &self.ollama_model),
            _ => (&self.openai_url, &self.openai_model),
        };
        (
            url.read(cx).value().trim().to_string(),
            model.read(cx).value().trim().to_string(),
        )
    }

    fn has_changes(&self, settings: &Settings, cx: &App) -> bool {
        let (url, model) = self.draft(cx);
        match self.connection {
            SummarizerBackend::Ollama => {
                url != settings.ollama_base_url || model != settings.ollama_model
            }
            SummarizerBackend::OpenAICompatible => {
                url != settings.openai_base_url || model != settings.openai_model
            }
            SummarizerBackend::BuiltIn
            | SummarizerBackend::ChatGptPlan
            | SummarizerBackend::ClaudePlan => false,
        }
    }
}

impl SettingsPage {
    pub(super) fn models_sections(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<Section> {
        match self.models.page {
            ModelsPage::Active => self.models_overview(window, cx),
            ModelsPage::Connections => self.connections(window, cx),
            ModelsPage::Downloaded => self.downloaded_models_page(cx),
            ModelsPage::Other => self.other_models_page(cx),
            ModelsPage::ReadAloud => self.read_aloud_page(cx),
            ModelsPage::TranscriptionOptions => self.transcription_options_page(cx),
            ModelsPage::TranscriptionServer => self.transcription_server_page(cx),
            ModelsPage::Checks => self.model_checks_page(cx),
            ModelsPage::Browse => self.model_browse_page(cx),
        }
    }

    /// Asks the Think server what the selected model accepts, once per model; the
    /// picker shows the answer when it comes (`ModelStackOverviewView`).
    pub(super) fn look_up_reasoning(&mut self, cx: &mut Context<Self>) {
        let settings = self.data.read(cx).settings.clone();
        let key = lokalbot_ai::think::reasoning_lookup_key(&settings);
        if self.models.reasoning_asked.as_ref() == Some(&key) {
            return;
        }
        self.models.reasoning_asked = Some(key);
        cx.spawn(async move |this, cx| {
            cx.background_spawn(async move {
                lokalbot_ai::think::refresh_reasoning_choices(&settings);
            })
            .await;
            let _ = this.update(cx, |_, cx| cx.notify());
        })
        .detach();
    }

    /// "Change…" beside a role (`ModelPickerSheet`): the models to choose
    /// from, then what sets the role up beyond its model. A model is
    /// prepared before the switch, so the current one stays until then
    /// (`ModelSetup`). Autocomplete's servers are set up on its own page.
    pub(super) fn change_button(&self, role: Role, cx: &mut Context<Self>) -> AnyElement {
        let settings = self.data.read(cx).settings.clone();
        let page = cx.entity();
        let options: Vec<ModelChoice> = match role {
            Role::Transcribe => lokalbot_speech::models::transcription_models()
                .iter()
                .map(|m| {
                    (
                        SharedString::from(format!(
                            "{} · {}",
                            m.display_name,
                            size_label(m.archive.size)
                        )),
                        settings.transcription_model == m.id,
                        ModelPatch {
                            transcription: Some(m.id.to_string()),
                            ..Default::default()
                        },
                        m.display_name.to_string(),
                    )
                })
                .collect(),
            Role::Think => {
                let mut items: Vec<ModelChoice> = lokalbot_ai::catalog::think_entries()
                    .map(|m| {
                        (
                            SharedString::from(format!(
                                "{} · {}",
                                m.display_name,
                                size_label(m.size_bytes)
                            )),
                            settings.summarizer_backend == SummarizerBackend::BuiltIn
                                && settings.built_in_model_id == m.id,
                            ModelPatch {
                                backend: Some(SummarizerBackend::BuiltIn),
                                assistant_model_id: Some(m.id.to_string()),
                                ..Default::default()
                            },
                            m.display_name.to_string(),
                        )
                    })
                    .collect();
                let server = |title: &'static str, backend| -> ModelChoice {
                    (
                        lokalbot_i18n::tr(title).into(),
                        settings.summarizer_backend == backend,
                        ModelPatch {
                            backend: Some(backend),
                            ..Default::default()
                        },
                        lokalbot_i18n::tr(title).to_string(),
                    )
                };
                items.push(server("Ollama server", SummarizerBackend::Ollama));
                items.push(server(
                    "OpenAI-compatible server",
                    SummarizerBackend::OpenAICompatible,
                ));
                for plan in SubscriptionPlan::ALL {
                    items.push(server(plan.title(), plan.backend()));
                }
                items
            }
            Role::Autocomplete => lokalbot_ai::catalog::autocomplete_entries(Some(
                &settings.cotyping_built_in_model_id,
            ))
            .map(|m| {
                (
                    SharedString::from(format!(
                        "{} · {}",
                        m.display_name,
                        size_label(m.size_bytes)
                    )),
                    settings.cotyping_built_in_model_id == m.id,
                    ModelPatch {
                        autocomplete_model_id: Some(m.id.to_string()),
                        ..Default::default()
                    },
                    m.display_name.to_string(),
                )
            })
            .collect(),
        };
        let options = std::rc::Rc::new(options);
        // What the menu opens beyond choosing a model.
        let links: &'static [(&'static str, ChangeLink)] = match role {
            Role::Transcribe => &[
                (
                    "Transcription server…",
                    ChangeLink::Page(ModelsPage::TranscriptionServer),
                ),
                (
                    "Language & vocabulary…",
                    ChangeLink::Page(ModelsPage::TranscriptionOptions),
                ),
            ],
            Role::Think => &[("Browse Hugging Face…", ChangeLink::Page(ModelsPage::Browse))],
            // Servers for autocomplete are set up on Autocomplete's page.
            Role::Autocomplete => &[(
                "Where autocomplete runs…",
                ChangeLink::Reveal("settings.cotypingBackend"),
            )],
        };
        let server_checked = match role {
            Role::Transcribe => lokalbot_speech::models::is_remote(&settings.transcription_model),
            Role::Autocomplete => {
                settings.cotyping_backend != lokalbot_core::settings::CotypingBackend::OnDevice
            }
            Role::Think => false,
        };
        Button::new(SharedString::from(format!("{}-change", role_setting(role))))
            .outline()
            .small()
            .label(lokalbot_i18n::tr("Change…"))
            .disabled(self.models.setup.is_switching())
            .dropdown_menu(move |mut menu, _, _| {
                menu = menu.scrollable(options.len() > 12);
                for (label, checked, patch, title) in options.iter() {
                    let page = page.clone();
                    let patch = patch.clone();
                    let title = title.clone();
                    let already = *checked;
                    menu = menu.item(
                        PopupMenuItem::new(label.clone())
                            .checked(*checked)
                            .on_click(move |_, _, cx| {
                                if already {
                                    return;
                                }
                                page.update(cx, |page, cx| {
                                    let data = page.data.clone();
                                    page.models.setup.apply(
                                        patch.clone(),
                                        title.clone(),
                                        &data,
                                        cx,
                                    );
                                    cx.notify();
                                });
                            }),
                    );
                }
                if !links.is_empty() {
                    menu = menu.separator();
                }
                for (title, link) in links {
                    let page = page.clone();
                    let link = *link;
                    let checked = matches!(
                        link,
                        ChangeLink::Page(ModelsPage::TranscriptionServer) | ChangeLink::Reveal(_)
                    ) && server_checked;
                    menu = menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr(title))
                            .checked(checked)
                            .on_click(move |_, window, cx| {
                                page.update(cx, |page, cx| match link {
                                    ChangeLink::Page(target) => {
                                        page.models.page = target;
                                        cx.notify();
                                    }
                                    ChangeLink::Reveal(id) => page.reveal(id, window, cx),
                                });
                            }),
                    );
                }
                menu
            })
            .into_any_element()
    }

    /// How long Think reasons (`ModelStackOverviewView.reasoningRow`): only
    /// the levels the selected model accepts; a stored level it lacks shows
    /// as the one it maps to (`ReasoningSupport`).
    pub(super) fn reasoning_control(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let settings = self.data.read(cx).settings.clone();
        let support = lokalbot_agent::session::ReasoningChoices::for_settings(&settings);
        if !support.is_adjustable() {
            return div()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                    "Set by the model",
                )))
                .into_any_element();
        }
        let data = self.data.clone();
        let shown = support.displayed(settings.think_reasoning_level);
        let automatic = match support.default_level {
            Some(default) => lokalbot_i18n::format(
                "Automatic ({level})",
                &[("level", lokalbot_i18n::tr(reasoning_name(default)).into())],
            ),
            None => lokalbot_i18n::tr("Automatic").to_string(),
        };
        let title = if shown == ReasoningLevel::Automatic {
            automatic.clone()
        } else {
            lokalbot_i18n::tr(reasoning_name(shown)).to_string()
        };
        Button::new("settings-reasoning")
            .outline()
            .small()
            .label(title)
            .dropdown_caret(true)
            .tooltip(lokalbot_i18n::tr("How much the Think model reasons before it answers in summaries and Ask. The levels are the ones this model accepts. Automatic keeps LokalBot's per-task amounts and the server's own default. A level sets the most any task uses. Agent Mode follows this unless you pick its own level in the Agent composer."))
            .dropdown_menu(move |mut menu, _, _| {
                let choose = |level: ReasoningLevel| {
                    let data = data.clone();
                    move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                        data.update(cx, |data, cx| {
                            data.update_settings(|s| s.think_reasoning_level = level, cx)
                        })
                    }
                };
                menu = menu.item(
                    PopupMenuItem::new(automatic.clone())
                        .checked(shown == ReasoningLevel::Automatic)
                        .on_click(choose(ReasoningLevel::Automatic)),
                );
                for level in support.levels.iter().copied() {
                    menu = menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr(reasoning_name(level)))
                            .checked(shown == level)
                            .on_click(choose(level)),
                    );
                }
                menu
            })
            .into_any_element()
    }

    /// Think processing budget as a menu (`budgetRow`).
    pub(super) fn budget_control(&self, cx: &mut Context<Self>) -> AnyElement {
        let settings = self.data.read(cx).settings.clone();
        let data = self.data.clone();
        settings_row::picker(
            "settings-budget",
            budget_label(settings.generation_budget_preset),
            BUDGETS
                .iter()
                .map(|budget| {
                    (
                        SharedString::from(budget_label(*budget)),
                        *budget == settings.generation_budget_preset,
                    )
                })
                .collect(),
            move |index, _, cx| {
                let budget = BUDGETS[index.min(BUDGETS.len() - 1)];
                data.update(cx, |data, cx| {
                    data.update_settings(|s| s.generation_budget_preset = budget, cx)
                });
            },
        )
        .into_any_element()
    }

    fn connections(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Vec<Section> {
        let _ = window;
        let lb = cx.lb().clone();
        let settings = self.data.read(cx).settings.clone();
        let page = cx.entity();
        let connection = self.models.connection;
        let is_ollama = connection == SummarizerBackend::Ollama;
        let plan = SubscriptionPlan::for_backend(connection);
        let used = settings.summarizer_backend == connection;
        let (draft_url, _) = self.models.draft(cx);
        let has_changes = self.models.has_changes(&settings, cx);

        let header = v_flex()
            .gap(px(4.))
            .child(
                div()
                    .text_size(ty::SECTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Model connections",
                    ))),
            )
            .child(settings_row::help(
                lokalbot_i18n::tr(
                    "Manage servers and credentials. To use one, choose it with Change… beside Think.",
                ),
                cx,
            ));
        let bar = Section::bare(super::subpage::bar(
            "settings-models-back",
            lokalbot_i18n::tr("Models"),
            lokalbot_i18n::tr("Online services"),
            move |_, cx| {
                page.update(cx, |page, cx| {
                    page.models.page = ModelsPage::Active;
                    cx.notify();
                })
            },
            cx,
        ));
        let approvals = self.approvals_section(cx);
        let page = cx.entity();

        let tab_page = page.clone();
        const TABS: [SummarizerBackend; 4] = [
            SummarizerBackend::OpenAICompatible,
            SummarizerBackend::Ollama,
            SummarizerBackend::ChatGptPlan,
            SummarizerBackend::ClaudePlan,
        ];
        let tabs = settings_row::segmented(
            "settings-connection",
            &[
                lokalbot_i18n::tr("OpenAI-compatible"),
                lokalbot_i18n::tr("Ollama"),
                lokalbot_i18n::tr("ChatGPT plan"),
                lokalbot_i18n::tr("Claude plan"),
            ],
            TABS.iter().position(|tab| *tab == connection).unwrap_or(0),
            move |index, _, cx| {
                tab_page.update(cx, |page, cx| {
                    page.models.connection = TABS[index];
                    page.models.saved = None;
                    cx.notify();
                })
            },
            cx,
        );
        // A plan is used only once its own consent is on.
        let usable = plan.is_none_or(|plan| plan.is_approved(&settings));
        let use_data = self.data.clone();
        let used_row = h_flex()
            .gap(px(8.))
            .items_center()
            .child(ui::icon(
                if used { Ico::CircleCheck } else { Ico::Network },
                px(14.),
                lb.text_secondary,
            ))
            .child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(if used {
                        lokalbot_i18n::tr("Used by Think")
                    } else {
                        lokalbot_i18n::tr("Available for Think")
                    }),
            )
            .when(!used, |this| {
                this.child(
                    Button::new("settings-use-connection")
                        .outline()
                        .xsmall()
                        .label(lokalbot_i18n::tr("Use for Think"))
                        .disabled(!usable)
                        .on_click(move |_, _, cx| {
                            use_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.summarizer_backend = connection, cx)
                            })
                        }),
                )
            });

        let field = |label: &'static str, input: &Entity<InputState>, cx: &App| {
            v_flex()
                .gap(px(5.))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .text_color(cx.lb().text)
                        .child(label),
                )
                .child(Input::new(input))
        };
        let mut form = v_flex().w_full().gap(px(14.)).child(tabs).child(used_row);
        if let Some(plan) = plan {
            let form = form.child(self.plan_form(plan, cx));
            return vec![
                bar,
                approvals,
                Section::new(None).row(
                    "settings.summarizerBackend",
                    settings_row::content_row(
                        "settings.summarizerBackend",
                        v_flex().gap(px(14.)).child(header).child(form.py(px(4.))),
                        self.is_focused("settings.summarizerBackend"),
                        cx,
                    ),
                ),
            ];
        }
        if is_ollama {
            form = form
                .child(field(
                    lokalbot_i18n::tr("Server URL"),
                    &self.models.ollama_url,
                    cx,
                ))
                .child(field(
                    lokalbot_i18n::tr("Model ID"),
                    &self.models.ollama_model,
                    cx,
                ))
                .child(self.ollama_model_list(has_changes, cx));
        } else {
            let key_data = self.data.clone();
            let key_input = self.models.api_key.clone();
            form = form
                .child(field(lokalbot_i18n::tr("Server URL"), &self.models.openai_url, cx))
                .child(field(lokalbot_i18n::tr("Model ID"), &self.models.openai_model, cx))
                .child(
                    v_flex()
                        .gap(px(5.))
                        .child(div().text_size(ty::BODY).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("API key"))))
                        .child(
                            h_flex()
                                .gap(px(8.))
                                .child(div().flex_1().min_w_0().child(Input::new(&self.models.api_key).mask_toggle()))
                                .child(Button::new("settings-save-key").outline().small().label(lokalbot_i18n::tr("Save key")).on_click(move |_, window, cx| {
                                    let key = key_input.read(cx).value().trim().to_string();
                                    if key.is_empty() {
                                        return;
                                    }
                                    key_data.update(cx, |data, cx| data.request(AppEvent::SaveApiKey(key), cx));
                                    key_input.update(cx, |input, cx| input.set_value("", window, cx));
                                })),
                        )
                        .child(settings_row::help(lokalbot_i18n::tr("Kept in the system credential store only when you choose Save key. Leave empty for a server that needs no key."), cx)),
                );
        }
        if !is_ollama {
            if lokalbot_ai::think::Dialect::inferred(&draft_url)
                == lokalbot_ai::think::Dialect::OpenRouter
            {
                form = form.child(super::plans::openrouter_policy(self.data.clone(), cx));
            }
            if lokalbot_ai::anthropic::is_anthropic(&draft_url) {
                form = form.child(super::plans::anthropic_note(cx));
            }
        }
        form = form.child(self.endpoint_disclosure(&draft_url, cx));
        let connection_check = self.connection_check_row(connection, has_changes, cx);

        let save_page = page.clone();
        form = form.child(
            h_flex()
                .gap(px(12.))
                .items_center()
                .child(
                    Button::new("settings-save-connection")
                        .primary()
                        .small()
                        .label(lokalbot_i18n::tr("Save connection"))
                        .disabled(!has_changes)
                        .on_click(move |_, _, cx| {
                            save_page.update(cx, |page, cx| page.save_connection(cx))
                        }),
                )
                .when_some(self.models.saved.clone(), |this, saved| {
                    this.child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(saved),
                    )
                }),
        );
        form = form.child(connection_check);

        vec![
            bar,
            approvals,
            Section::new(None).row(
                "settings.summarizerBackend",
                settings_row::content_row(
                    "settings.summarizerBackend",
                    v_flex().gap(px(14.)).child(header).child(form.py(px(4.))),
                    self.is_focused("settings.summarizerBackend"),
                    cx,
                ),
            ),
        ]
    }

    /// What is approved to receive data, each with Revoke… and what it
    /// covers (`ModelRemoteOverview`). Nothing is approved or chosen here.
    fn approvals_section(&self, cx: &mut Context<Self>) -> Section {
        let lb = cx.lb().clone();
        let settings = self.data.read(cx).settings.clone();
        let mut section = Section::new(lokalbot_i18n::tr("Approved to receive your data"));
        if settings.approved_remote_inference_origins.is_empty() {
            section = section.row(
                "settings.remoteHelp",
                settings_row::content_row(
                    "settings.remoteHelp",
                    v_flex()
                        .gap(px(6.))
                        .child(
                            h_flex()
                                .gap(px(8.))
                                .items_center()
                                .child(ui::icon(Ico::ShieldCheck, px(15.), lb.text_secondary))
                                .child(
                                    div()
                                        .text_size(ty::BODY)
                                        .text_color(lb.text_secondary)
                                        .child(lokalbot_i18n::tr("No remote servers approved")),
                                ),
                        )
                        .child(settings_row::help(
                            lokalbot_i18n::tr("Local models process on this PC. Each remote server requires its own approval before context can leave this PC."),
                            cx,
                        )),
                    false,
                    cx,
                ),
            );
        }
        let origin_row = |id: SharedString,
                          icon: Ico,
                          name: String,
                          button: Button,
                          notice: &'static str,
                          cx: &mut Context<Self>| {
            settings_row::content_row(
                id,
                v_flex()
                    .gap(px(8.))
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .child(ui::icon(icon, px(15.), lb.attention_text))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .child(name),
                            )
                            .child(button),
                    )
                    .child(settings_row::help(notice, cx)),
                false,
                cx,
            )
        };
        for origin in settings.approved_remote_inference_origins.clone() {
            let data = self.data.clone();
            let revoke = origin.clone();
            let button = Button::new(SharedString::from(format!("revoke-{origin}")))
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Revoke…"))
                .on_click(move |_, window, cx| {
                    confirm_revoke(data.clone(), revoke.clone(), window, cx)
                });
            section = section.row(
                "settings.remoteOrigin",
                origin_row(
                    SharedString::from(format!("settings-origin-{origin}")),
                    Ico::Network,
                    origin_display_name(&origin),
                    button,
                    approved_origin_notice(),
                    cx,
                ),
            );
        }
        for origin in settings.approved_remote_transcription_origins.clone() {
            let data = self.data.clone();
            let revoke = origin.clone();
            let button = Button::new(SharedString::from(format!("revoke-audio-{origin}")))
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Revoke…"))
                .on_click(move |_, window, cx| {
                    confirm_revoke_audio(data.clone(), revoke.clone(), window, cx)
                });
            section = section.row(
                "settings.remoteOrigin",
                origin_row(
                    SharedString::from(format!("settings-audio-origin-{origin}")),
                    Ico::AudioLines,
                    origin.clone(),
                    button,
                    approved_audio_origin_notice(),
                    cx,
                ),
            );
        }
        section
    }

    /// Loopback, blocked HTTP, or a remote origin with its consent toggle.
    fn endpoint_disclosure(&self, raw_url: &str, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let settings = self.data.read(cx).settings.clone();
        if raw_url.is_empty() || lokalbot_core::access::is_loopback_url(raw_url) {
            return h_flex()
                .gap(px(8.))
                .items_center()
                .child(ui::icon(Ico::ShieldCheck, px(14.), lb.success_text))
                .child(settings_row::help(
                    lokalbot_i18n::tr("Loopback server: inference context stays on this PC."),
                    cx,
                ));
        }
        let Some(origin) = lokalbot_core::access::origin_of(raw_url) else {
            return h_flex().child(settings_row::help(
                lokalbot_i18n::tr("The server URL is not valid."),
                cx,
            ));
        };
        if !origin.starts_with("https://") {
            return h_flex()
                .gap(px(8.))
                .items_start()
                .child(ui::icon(Ico::Lock, px(14.), lb.attention_text))
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Blocked: remote inference must use HTTPS so transcripts and screen text are encrypted in transit."))),
                );
        }
        let approved = settings
            .approved_remote_inference_origins
            .iter()
            .any(|o| o.eq_ignore_ascii_case(&origin));
        let host = origin
            .split_once("://")
            .map(|(_, h)| h.to_string())
            .unwrap_or(origin.clone());
        let data = self.data.clone();
        let toggle_origin = origin.clone();
        v_flex()
            .gap(px(8.))
            .p(px(12.))
            .rounded(px(8.))
            .bg(lb.status_fill(lb.attention))
            .border_1()
            .border_color(lb.status_stroke(lb.attention))
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(ui::icon(Ico::Network, px(14.), lb.attention_text))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                "Remote processing · {host}",
                                &[("host", host.to_string())],
                            ))),
                    ),
            )
            .child(settings_row::help(remote_processing_notice(), cx))
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
                            .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                "Allow sending context to {origin}",
                                &[("origin", origin.to_string())],
                            ))),
                    )
                    .child(settings_row::switch(
                        "settings-remote-consent",
                        approved,
                        move |on, _, cx| {
                            let origin = toggle_origin.clone();
                            data.update(cx, |data, cx| {
                                data.update_settings(
                                    |s| {
                                        s.approved_remote_inference_origins
                                            .retain(|o| !o.eq_ignore_ascii_case(&origin));
                                        if on {
                                            s.approved_remote_inference_origins.push(origin);
                                        }
                                    },
                                    cx,
                                )
                            })
                        },
                    )),
            )
    }

    /// "List server models" and the picker it fills (`refreshOllama`). It asks the
    /// saved server, which must already be allowed to receive context.
    fn ollama_model_list(&self, has_changes: bool, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let listing = self.models.listing_ollama;
        let models = self.models.ollama_models.clone();
        let chosen = self.models.ollama_model.read(cx).value().to_string();
        let input = self.models.ollama_model.clone();
        v_flex()
            .gap(px(5.))
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(
                        Button::new("settings-ollama-list")
                            .outline()
                            .small()
                            .label(if listing {
                                lokalbot_i18n::tr("Loading…")
                            } else {
                                lokalbot_i18n::tr("List server models")
                            })
                            .disabled(listing || has_changes)
                            .on_click(cx.listener(|page, _, _, cx| page.list_ollama_models(cx))),
                    )
                    .when(!models.is_empty(), |this| {
                        this.child(
                            Button::new("settings-ollama-models")
                                .outline()
                                .small()
                                .label(if chosen.is_empty() {
                                    lokalbot_i18n::tr("Choose a model").to_string()
                                } else {
                                    chosen.clone()
                                })
                                .dropdown_caret(true)
                                .tooltip(lokalbot_i18n::tr("Available models"))
                                .dropdown_menu(move |mut menu, _, _| {
                                    for model in &models {
                                        let input = input.clone();
                                        let name = model.clone();
                                        menu = menu.item(
                                            PopupMenuItem::new(model.clone())
                                                .checked(*model == chosen)
                                                .on_click(move |_, window, cx| {
                                                    input.update(cx, |input, cx| {
                                                        input.set_value(name.clone(), window, cx)
                                                    });
                                                }),
                                        );
                                    }
                                    menu
                                }),
                        )
                    }),
            )
            .when_some(self.models.ollama_list_problem.clone(), |this, problem| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(crate::ui::text::paragraph(problem)),
                )
            })
    }

    fn list_ollama_models(&mut self, cx: &mut Context<Self>) {
        let settings = self.data.read(cx).settings.clone();
        let (url, approved) = (
            settings.ollama_base_url,
            settings.approved_remote_inference_origins,
        );
        self.models.listing_ollama = true;
        self.models.ollama_list_problem = None;
        cx.notify();
        cx.spawn(async move |page, cx| {
            let asked = url.clone();
            let listed = cx
                .background_spawn(async move {
                    lokalbot_ai::think::list_ollama_models(&asked, &approved)
                })
                .await;
            let _ = page.update(cx, |page, cx| {
                page.models.listing_ollama = false;
                // The server changed meanwhile: this answer is about another one.
                if page.data.read(cx).settings.ollama_base_url != url {
                    cx.notify();
                    return;
                }
                match listed {
                    Ok(models) => {
                        if models.is_empty() {
                            page.models.ollama_list_problem = Some(lokalbot_i18n::tr("No models returned. Check that the Ollama server is running and has a model installed.").into());
                        }
                        page.models.ollama_models = models;
                    }
                    Err(err) => page.models.ollama_list_problem = Some(format!("{err:#}").into()),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn save_connection(&mut self, cx: &mut Context<Self>) {
        let (url, model) = self.models.draft(cx);
        let ollama = self.models.connection == SummarizerBackend::Ollama;
        self.update_settings(
            move |s| {
                if ollama {
                    s.ollama_base_url = url;
                    s.ollama_model = model;
                } else {
                    s.openai_base_url = url;
                    s.openai_model = model;
                }
            },
            cx,
        );
        self.models.saved = Some(lokalbot_i18n::tr("Saved").into());
        cx.notify();
    }
}

/// "gpt-5.5 · ChatGPT plan", or the plan alone before a model is chosen.
fn plan_model_name(settings: &Settings) -> String {
    let Some(plan) = settings.think_plan() else {
        return String::new();
    };
    let title = lokalbot_i18n::tr(plan.title());
    let model = plan.model(settings);
    if model.is_empty() {
        title.to_string()
    } else {
        format!("{model} · {title}")
    }
}

/// What "Change…" opens beyond a model: a page of Models, or a setting on
/// another page.
#[derive(Clone, Copy)]
enum ChangeLink {
    Page(ModelsPage),
    Reveal(&'static str),
}

/// The catalog setting a role's row stands for, so search and links land on it.
pub(super) fn role_setting(role: Role) -> &'static str {
    match role {
        Role::Transcribe => "settings.transcriptionModel",
        Role::Think => "settings.builtInModelID",
        Role::Autocomplete => "settings.cotypingBuiltInModelID",
    }
}

/// Think's model as people know it: a built-in model, a server's model or the
/// server, or a plan (`ModelSettingsPresentation.assistantName`).
pub(super) fn think_name(settings: &Settings) -> String {
    match settings.summarizer_backend {
        SummarizerBackend::BuiltIn => model_name(&settings.built_in_model_id),
        SummarizerBackend::Ollama => {
            if settings.ollama_model.is_empty() {
                lokalbot_i18n::tr("Ollama").into()
            } else {
                settings.ollama_model.clone()
            }
        }
        SummarizerBackend::OpenAICompatible => {
            if settings.openai_model.is_empty() {
                lokalbot_i18n::tr("OpenAI-compatible server").into()
            } else {
                settings.openai_model.clone()
            }
        }
        SummarizerBackend::ChatGptPlan | SummarizerBackend::ClaudePlan => plan_model_name(settings),
    }
}

pub(super) fn confirm_preset(
    page: Entity<SettingsPage>,
    preset: Preset,
    download: u64,
    window: &mut Window,
    cx: &mut App,
) {
    let detail = if download > 0 {
        lokalbot_i18n::format(
            "{0} Estimated new download: {1}. Existing models are kept.",
            &[
                ("0", preset.summary().to_string()),
                ("1", size_label(download).to_string()),
            ],
        )
    } else {
        lokalbot_i18n::format(
            "{0} Every model is already on this PC.",
            &[("0", preset.summary().to_string())],
        )
    };
    window.open_alert_dialog(cx, move |alert, _, _| {
        let page = page.clone();
        alert
            .title(lokalbot_i18n::format(
                "Use {0}?",
                &[("0", preset.title().to_string())],
            ))
            .description(detail.clone())
            .confirm()
            .ok_text(if download > 0 {
                lokalbot_i18n::tr("Download and apply")
            } else {
                lokalbot_i18n::tr("Apply preset")
            })
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                page.update(cx, |page, cx| {
                    let data = page.data.clone();
                    page.models
                        .setup
                        .apply(preset.patch(), preset.title(), &data, cx);
                    cx.notify();
                });
                true
            })
    });
}

/// Asks before deleting a downloaded model the settings don't use.
pub(super) fn confirm_remove(data: Entity<AppData>, id: String, window: &mut Window, cx: &mut App) {
    let name = model_name(&id);
    let size = size_label(model_bytes(&id, &data.read(cx).settings));
    window.open_alert_dialog(cx, move |alert, _, _| {
        let data = data.clone();
        let id = id.clone();
        alert
            .title(lokalbot_i18n::format("Remove {name}?", &[("name", name.to_string())]))
            .description(lokalbot_i18n::format("This deletes {name} ({size}) from this PC. Your current settings don't use it, and you can download it again later.", &[("name", name.to_string()), ("size", size.to_string())]))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Remove"))
            .ok_variant(ButtonVariant::Danger)
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                let id = id.clone();
                data.update(cx, |data, cx| {
                    // Settings may have changed while the dialog was open.
                    if !models_in_use(&data.settings).contains(&id) {
                        data.request(AppEvent::DeleteModel(id), cx);
                    }
                });
                true
            })
    });
}

/// An approved Think origin as people know it: a plan by its name and
/// host, a server by its origin (`SubscriptionPlan.approvalDisplayName`).
pub(super) fn origin_display_name(origin: &str) -> String {
    match SubscriptionPlan::for_consent_key(origin) {
        Some(plan) => format!(
            "{} · {}",
            lokalbot_i18n::tr(plan.title()),
            plan.destination_host()
        ),
        None => origin.to_string(),
    }
}

pub(super) fn confirm_revoke(
    data: Entity<AppData>,
    origin: String,
    window: &mut Window,
    cx: &mut App,
) {
    window.open_alert_dialog(cx, move |alert, _, _| {
        let data = data.clone();
        let origin = origin.clone();
        alert
            .title(lokalbot_i18n::format("Revoke access to {origin}?", &[("origin", origin.to_string())]))
            .description(lokalbot_i18n::tr("This also revokes scheduled processing for this origin. Any model using it will require approval again."))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Revoke Access"))
            .ok_variant(ButtonVariant::Danger)
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                let origin = origin.clone();
                data.update(cx, |data, cx| {
                    data.update_settings(|s| s.approved_remote_inference_origins.retain(|o| o != &origin), cx)
                });
                true
            })
    });
}

/// What approving a Think server covers (`ModelConnectionsView`).
fn remote_processing_notice() -> &'static str {
    lokalbot_i18n::tr(
        "Think may send meeting transcripts, screen text, what you told Ask to remember about you, Agent context, and inherited dictation requests to this server when you use those features. Scheduled daily summaries and overnight review also run here and can send activity titles, captured screen text, meeting evidence, and retained Dream memory without a prompt each time.",
    )
}

/// Under an approved origin in Overview (`ModelOverviewSections`).
pub(super) fn approved_origin_notice() -> &'static str {
    lokalbot_i18n::tr(
        "Includes scheduled daily summaries and overnight review, which can send activity titles, captured screen text, meeting evidence, and retained Dream memory to this origin without a prompt each time.",
    )
}

pub(super) fn approved_audio_origin_notice() -> &'static str {
    lokalbot_i18n::tr(
        "Transcription server. Receives meeting and dictation audio, the language hint, and transcription vocabulary, including automatic processing after meetings.",
    )
}

/// Audio stops going there. A Think approval for the same server stays apart.
fn revoke_audio_origin(settings: &mut Settings, origin: &str) {
    settings
        .approved_remote_transcription_origins
        .retain(|o| o != origin);
}

pub(super) fn confirm_revoke_audio(
    data: Entity<AppData>,
    origin: String,
    window: &mut Window,
    cx: &mut App,
) {
    window.open_alert_dialog(cx, move |alert, _, _| {
        let data = data.clone();
        let origin = origin.clone();
        alert
            .title(lokalbot_i18n::format("Stop sending audio to {origin}?", &[("origin", origin.to_string())]))
            .description(lokalbot_i18n::tr("Meetings will wait for transcription until you approve this server again or choose a model on this computer."))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Revoke Access"))
            .ok_variant(ButtonVariant::Danger)
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                let origin = origin.clone();
                data.update(cx, |data, cx| {
                    data.update_settings(|s| revoke_audio_origin(s, &origin), cx)
                });
                true
            })
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Think approval names what actually leaves: digests send screen text.
    #[test]
    fn the_think_approval_names_what_is_sent() {
        let notice = remote_processing_notice();
        for sent in [
            "screen text",
            "what you told Ask to remember about you",
            "Agent context",
            "captured screen text",
            "retained Dream memory",
        ] {
            assert!(notice.contains(sent), "{sent}");
        }
        for sent in ["captured screen text", "retained Dream memory"] {
            assert!(approved_origin_notice().contains(sent), "{sent}");
        }
        assert!(approved_audio_origin_notice().contains("audio"));
    }

    #[test]
    fn revoking_audio_leaves_think_alone() {
        let mut settings = Settings {
            approved_remote_inference_origins: vec!["https://gpu.example".into()],
            approved_remote_transcription_origins: vec![
                "https://gpu.example".into(),
                "https://audio.example".into(),
            ],
            ..Settings::default()
        };
        revoke_audio_origin(&mut settings, "https://gpu.example");
        assert_eq!(
            settings.approved_remote_transcription_origins,
            ["https://audio.example"]
        );
        assert_eq!(
            settings.approved_remote_inference_origins,
            ["https://gpu.example"]
        );
    }

    #[test]
    fn presets_round_trip() {
        let mut settings = Settings::default();
        Preset::Balanced.patch().apply(&mut settings);
        assert!(Preset::Balanced.matches(&settings));
        assert!(!Preset::Lightweight.matches(&settings));
        assert_eq!(size_label(2_740_937_888), "2.7 GB");
        assert_eq!(size_label(730_895_584), "731 MB");
        assert_eq!(model_name("qwen3.5-4b"), "Qwen3.5 4B");
    }
}
