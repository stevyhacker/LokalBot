//! Models (`ModelsView.swift`, `ModelStackOverviewView.swift`,
//! `ModelConnectionsView.swift`): the Transcribe, Think and Autocomplete
//! roles, presets, remote servers, storage, the processing budget and server
//! connections.
//!
//! Names and sizes come from the catalogs: `lokalbot_ai::catalog` for text
//! models, `lokalbot_speech::models` for speech, `lokalbot_ai::runtime` for
//! the llama.cpp binaries.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Div, Entity, FontWeight, InteractiveElement as _,
    IntoElement as _, ParentElement as _, SharedString, StatefulInteractiveElement as _,
    Styled as _, Subscription, Window, div, px,
};
use lokalbot_core::Settings;
use lokalbot_core::settings::{
    GenerationBudget, ReasoningLevel, SubscriptionPlan, SummarizerBackend,
};

use super::{Section, SettingsPage};
use crate::state::{AppData, AppEvent};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

/// A picker entry: label, whether it is current, and how to select it.
type ModelChoice = (SharedString, bool, Box<dyn Fn(&mut Settings)>);

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
    lokalbot_speech::models::find(id)
        .map(|m| m.display_name.to_string())
        .unwrap_or_else(|| id.to_string())
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
    lokalbot_speech::models::find(id)
        .map(|m| m.archive.size)
        .unwrap_or(0)
}

/// Model ids the current settings use on this PC: the engine's meeting,
/// dictation, search and screen text requirements, and Autocomplete's model
/// while autocomplete is on.
pub fn models_in_use(settings: &Settings) -> Vec<String> {
    let mut ids = vec![settings.transcription_model.clone()];
    ids.extend(lokalbot_speech::models::supporting_ids(
        settings.multi_speaker_diarization,
    ));
    let built_in = settings.summarizer_backend == SummarizerBackend::BuiltIn;
    if built_in {
        ids.push(settings.built_in_model_id.clone());
    }
    if settings.semantic_search_enabled {
        ids.push(lokalbot_ai::catalog::EMBEDDING_MODEL_ID.to_string());
    }
    if settings.cotyping_enabled {
        ids.push(settings.cotyping_built_in_model_id.clone());
    }
    if built_in || settings.semantic_search_enabled || settings.cotyping_enabled {
        ids.push(RUNTIME_ID.to_string());
    }
    if settings.screen_context_capture_mode != lokalbot_core::ScreenContextMode::ActivityOnly {
        ids.push(lokalbot_ai::ocr::OCR_MODEL_ID.to_string());
    }
    ids
}

/// What Autocomplete downloads: its model and the llama.cpp runtime.
pub fn autocomplete_needs(settings: &Settings) -> Vec<String> {
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
        .filter(|id| !in_use.contains(id))
        .cloned()
        .collect()
}

/// What a downloaded model is for, for the storage list.
fn model_purpose(id: &str) -> &'static str {
    if id == RUNTIME_ID {
        return lokalbot_i18n::tr("Runs Think, Autocomplete and search models");
    }
    if id == lokalbot_ai::catalog::EMBEDDING_MODEL_ID {
        return lokalbot_i18n::tr("Search by meaning");
    }
    if id == lokalbot_ai::ocr::OCR_MODEL_ID {
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

#[derive(Clone, Copy, PartialEq, Eq)]
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

    fn subtitle(self) -> &'static str {
        match self {
            Preset::Balanced => lokalbot_ai::catalog::PRESETS[0].description,
            Preset::Lightweight => lokalbot_ai::catalog::PRESETS[1].description,
        }
    }

    /// Transcribe and Think model ids (`lokalbot_ai::catalog::PRESETS`).
    /// Autocomplete keeps its own model here: its lighter default suits
    /// suggestions on a CPU, and a preset should not swap it unasked.
    fn models(self) -> (&'static str, &'static str) {
        let index = match self {
            Preset::Balanced => 0,
            Preset::Lightweight => 1,
        };
        (
            DEFAULT_SPEECH_MODEL,
            lokalbot_ai::catalog::PRESETS[index].think,
        )
    }

    fn summary(self) -> String {
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

    fn apply(self, settings: &mut Settings) {
        let (speech, think) = self.models();
        settings.summarizer_backend = SummarizerBackend::BuiltIn;
        settings.transcription_model = speech.into();
        settings.built_in_model_id = think.into();
    }
}

fn budget_label(budget: GenerationBudget) -> &'static str {
    match budget {
        GenerationBudget::Conservative => lokalbot_i18n::tr("Conservative"),
        GenerationBudget::Standard => lokalbot_i18n::tr("Default"),
        GenerationBudget::Generous => lokalbot_i18n::tr("Generous"),
        GenerationBudget::Unlimited => lokalbot_i18n::tr("Unlimited"),
    }
}

fn budget_detail(budget: GenerationBudget) -> &'static str {
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

const BUDGETS: [GenerationBudget; 4] = [
    GenerationBudget::Conservative,
    GenerationBudget::Standard,
    GenerationBudget::Generous,
    GenerationBudget::Unlimited,
];

const REASONING: [(ReasoningLevel, &str); 6] = [
    (ReasoningLevel::Automatic, "Automatic"),
    (ReasoningLevel::Off, "Off"),
    (ReasoningLevel::Low, "Low"),
    (ReasoningLevel::Medium, "Medium"),
    (ReasoningLevel::High, "High"),
    (ReasoningLevel::Max, "Max"),
];

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ModelsPage {
    Active,
    Connections,
}

impl ModelsPage {
    pub fn for_setting(id: &str) -> Self {
        if id == "settings.summarizerBackend" {
            ModelsPage::Connections
        } else {
            ModelsPage::Active
        }
    }
}

/// The Models subpage and the connection form drafts.
pub struct ModelsState {
    pub page: ModelsPage,
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
        }
    }

    pub fn subscribe(
        state: &Self,
        window: &mut Window,
        cx: &mut Context<SettingsPage>,
    ) -> Vec<Subscription> {
        [
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
        .collect()
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
            ModelsPage::Active => self.active_models(cx),
            ModelsPage::Connections => self.connections(window, cx),
        }
    }

    fn active_models(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let (settings, status, downloads, root) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.models.clone(),
                data.downloads.clone(),
                data.library.paths().clone(),
            )
        };
        let lb = cx.lb().clone();
        let local = settings.think_is_local();
        let setup = Preset::ALL
            .iter()
            .find(|p| p.matches(&settings))
            .map(|p| p.title())
            .unwrap_or(lokalbot_i18n::tr("Custom"));
        let location = if local {
            lokalbot_i18n::tr("On this PC")
        } else {
            lokalbot_i18n::tr("Local + remote")
        };

        let summary = Section::new(None).row(
            "settings.models",
            settings_row::content_row(
                "settings.models",
                h_flex()
                    .gap(px(18.))
                    .items_center()
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Current setup",
                            ))),
                    )
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                "{setup} · {location}",
                                &[
                                    ("setup", setup.to_string()),
                                    ("location", location.to_string()),
                                ],
                            ))),
                    ),
                self.is_focused("settings.models"),
                cx,
            ),
        );

        // Core roles.
        let think_name = match settings.summarizer_backend {
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
            SummarizerBackend::ChatGptPlan | SummarizerBackend::ClaudePlan => {
                plan_model_name(&settings)
            }
        };
        let think_location = match settings.summarizer_backend {
            SummarizerBackend::BuiltIn => None,
            SummarizerBackend::Ollama => Some(settings.ollama_base_url.clone()),
            SummarizerBackend::OpenAICompatible => Some(settings.openai_base_url.clone()),
            SummarizerBackend::ChatGptPlan | SummarizerBackend::ClaudePlan => settings
                .think_plan()
                .map(|plan| format!("https://{}", plan.destination_host())),
        };
        // What each role downloads: Transcribe with voice detection (and speaker
        // separation when on); built-in Think with the llama.cpp runtime.
        let mut speech_needs = vec![settings.transcription_model.clone()];
        speech_needs.extend(lokalbot_speech::models::supporting_ids(
            settings.multi_speaker_diarization,
        ));
        let think_needs = if settings.summarizer_backend == SummarizerBackend::BuiltIn {
            vec![settings.built_in_model_id.clone(), RUNTIME_ID.to_string()]
        } else {
            Vec::new()
        };
        let progress = |needs: &[String]| {
            needs
                .iter()
                .find_map(|id| downloads.get(id))
                .map(|d| d.fraction())
        };
        let mut roles = Section::new(lokalbot_i18n::tr("Core Roles"));
        roles = roles.row(
            "settings.transcriptionModel",
            self.role_row(
                RoleRow {
                    id: "settings.transcriptionModel",
                    icon: Ico::AudioLines,
                    title: lokalbot_i18n::tr("Transcribe"),
                    detail: lokalbot_i18n::tr("Meeting audio to text"),
                    model: model_name(&settings.transcription_model),
                    remote: None,
                    ready: status.transcription_ready,
                    downloading: progress(&speech_needs),
                    needs: speech_needs.clone(),
                    installed: status.installed.clone(),
                },
                RoleChoices::Speech,
                cx,
            ),
        );
        roles = roles.row(
            "settings.builtInModelID",
            self.role_row(
                RoleRow {
                    id: "settings.builtInModelID",
                    icon: Ico::Brain,
                    title: lokalbot_i18n::tr("Think"),
                    detail: lokalbot_i18n::tr("Summaries, Ask, and Compose"),
                    model: think_name,
                    remote: think_location
                        .filter(|url| !lokalbot_core::access::is_loopback_url(url)),
                    ready: status.think_ready
                        || settings.summarizer_backend != SummarizerBackend::BuiltIn,
                    downloading: progress(&think_needs),
                    needs: think_needs.clone(),
                    installed: status.installed.clone(),
                },
                RoleChoices::Think,
                cx,
            ),
        );
        let autocomplete_needs = autocomplete_needs(&settings);
        roles = roles.row(
            "settings.cotypingBuiltInModelID",
            self.role_row(
                RoleRow {
                    id: "settings.cotypingBuiltInModelID",
                    icon: Ico::TextCursorInput,
                    title: lokalbot_i18n::tr("Autocomplete"),
                    detail: lokalbot_i18n::tr("Suggestions as you type"),
                    model: model_name(&settings.cotyping_built_in_model_id),
                    remote: None,
                    ready: status.autocomplete_ready,
                    downloading: progress(&autocomplete_needs),
                    needs: autocomplete_needs.clone(),
                    installed: status.installed.clone(),
                },
                RoleChoices::Autocomplete,
                cx,
            ),
        );
        let prepare_data = self.data.clone();
        let any_missing = !(status.transcription_ready && status.think_ready);
        roles = roles.row(
            "settings.prepareModels",
            settings_row::content_row(
                "settings.prepareModels",
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(settings_row::help(
                        if downloads.is_empty() {
                            lokalbot_i18n::tr("Downloads come from the model provider and never include your meeting content.")
                        } else {
                            lokalbot_i18n::tr("Downloading models. You can keep using LokalBot meanwhile.")
                        },
                        cx,
                    ).flex_1().min_w_0())
                    .child(
                        Button::new("settings-prepare-models")
                            .outline()
                            .small()
                            .icon(Icon::new(Ico::CircleArrowDown))
                            .label(lokalbot_i18n::tr("Prepare Selected Models"))
                            .disabled(!any_missing || !downloads.is_empty())
                            .on_click(move |_, _, cx| prepare_data.update(cx, |data, cx| data.request(AppEvent::PrepareModels, cx))),
                    ),
                false,
                cx,
            ),
        );

        // Presets.
        let mut presets = Section::new(lokalbot_i18n::tr("Presets"));
        for preset in Preset::ALL {
            let current = preset.matches(&settings);
            let (speech, think) = preset.models();
            let download: u64 = [speech, think]
                .iter()
                .filter(|id| !status.installed.iter().any(|installed| installed == *id))
                .map(|id| model_bytes(id, &settings))
                .sum();
            let data = self.data.clone();
            presets = presets.row(
                if preset == Preset::Balanced {
                    "settings.presetBalanced"
                } else {
                    "settings.presetLightweight"
                },
                settings_row::content_row(
                    if preset == Preset::Balanced {
                        "settings.presetBalanced"
                    } else {
                        "settings.presetLightweight"
                    },
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
                                        .font_weight(FontWeight::MEDIUM)
                                        .text_color(lb.text)
                                        .child(preset.title()),
                                )
                                .child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(lb.text_secondary)
                                        .child(preset.subtitle()),
                                )
                                .child(
                                    div()
                                        .text_size(ty::CAPTION)
                                        .text_color(lb.text_secondary)
                                        .child(preset.summary()),
                                ),
                        )
                        .when(current, |this| {
                            this.child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.accent_text)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                        "Current",
                                    ))),
                            )
                        })
                        .child(
                            Button::new(if preset == Preset::Balanced {
                                "preset-balanced"
                            } else {
                                "preset-lightweight"
                            })
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Apply…"))
                            .disabled(current)
                            .on_click(move |_, window, cx| {
                                confirm_preset(data.clone(), preset, download, window, cx)
                            }),
                        ),
                    false,
                    cx,
                ),
            );
        }
        presets = presets.row(
            "settings.presetsHelp",
            settings_row::content_row(
                "settings.presetsHelp",
                settings_row::help(lokalbot_i18n::tr("Review model changes and download sizes before applying. Existing models are kept."), cx),
                false,
                cx,
            ),
        );

        // Remote servers.
        let page = cx.entity();
        let mut remote = Section::new(lokalbot_i18n::tr("Remote Server")).row(
            "settings.summarizerBackend",
            settings_row::content_row(
                "settings.summarizerBackend",
                h_flex()
                    .items_center()
                    .child(
                        h_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(8.))
                            .items_center()
                            .child(ui::icon(Ico::ShieldCheck, px(15.), lb.text_secondary))
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text_secondary)
                                    .child(
                                        if settings.approved_remote_inference_origins.is_empty() {
                                            lokalbot_i18n::tr("No remote servers approved")
                                        } else {
                                            lokalbot_i18n::tr("Approved remote servers")
                                        },
                                    ),
                            ),
                    )
                    .child(settings_row::link_button(
                        "settings-manage-connections",
                        lokalbot_i18n::tr("Manage Connections…"),
                        move |_, cx| {
                            page.update(cx, |page, cx| {
                                page.models.page = ModelsPage::Connections;
                                cx.notify();
                            })
                        },
                        cx,
                    )),
                self.is_focused("settings.summarizerBackend"),
                cx,
            ),
        );
        if settings.approved_remote_inference_origins.is_empty() {
            remote = remote.row(
                "settings.remoteHelp",
                settings_row::content_row(
                    "settings.remoteHelp",
                    settings_row::help(lokalbot_i18n::tr("Local models process on this PC. Each remote server requires its own approval before context can leave this PC."), cx),
                    false,
                    cx,
                ),
            );
        }
        for origin in settings.approved_remote_inference_origins.clone() {
            let data = self.data.clone();
            let revoke = origin.clone();
            let shown = match SubscriptionPlan::for_consent_key(&origin) {
                Some(plan) => format!(
                    "{} · {}",
                    lokalbot_i18n::tr(plan.title()),
                    plan.destination_host()
                ),
                None => origin.clone(),
            };
            remote = remote.row(
                "settings.remoteOrigin",
                settings_row::content_row(
                    SharedString::from(format!("settings-origin-{origin}")),
                    v_flex()
                        .gap(px(8.))
                        .child(
                            h_flex()
                                .gap(px(8.))
                                .items_center()
                                .child(ui::icon(Ico::Network, px(15.), lb.attention_text))
                                .child(div().flex_1().min_w_0().text_size(ty::BODY).text_color(lb.text).child(shown))
                                .child(Button::new(SharedString::from(format!("revoke-{origin}"))).outline().small().label(lokalbot_i18n::tr("Revoke…")).on_click(
                                    move |_, window, cx| confirm_revoke(data.clone(), revoke.clone(), window, cx),
                                )),
                        )
                        .child(settings_row::help(lokalbot_i18n::tr("Includes scheduled daily summaries, which can send activity titles and meeting evidence to this origin without a prompt each time."), cx)),
                    false,
                    cx,
                ),
            );
        }

        // Storage: what is downloaded, and the models the settings don't use.
        let models_dir = root.models_dir();
        let open_dir = models_dir.clone();
        let library_root = root.root().to_path_buf();
        let stored = status
            .installed
            .iter()
            .filter(|id| id.as_str() != RUNTIME_ID)
            .count();
        let unused = unused_models(&settings, &status.installed);
        let mut storage = Section::new(lokalbot_i18n::tr("Model Storage")).row(
            "settings.modelStorage",
            settings_row::content_row(
                "settings.modelStorage",
                h_flex()
                    .gap(px(12.))
                    .items_center()
                    .child(ui::icon(Ico::HardDrive, px(20.), lb.text_secondary))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(3.))
                            .child(div().text_size(ty::BODY).text_color(lb.text).child(
                                match stored {
                                    0 => lokalbot_i18n::tr("No models downloaded yet").to_string(),
                                    1 => lokalbot_i18n::tr("1 model on this PC").to_string(),
                                    n => lokalbot_i18n::format(
                                        "{n} models on this PC",
                                        &[("n", format!("{}", n))],
                                    ),
                                },
                            ))
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .truncate()
                                    .child(models_dir.display().to_string()),
                            ),
                    )
                    .child(
                        Button::new("settings-open-models")
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Show in Folder"))
                            .on_click(move |_, _, cx| {
                                let target = if open_dir.is_dir() {
                                    open_dir.clone()
                                } else {
                                    library_root.clone()
                                };
                                cx.open_with_system(&target);
                            }),
                    ),
                self.is_focused("settings.modelStorage"),
                cx,
            ),
        );
        for runtime in &status.runtime_storage {
            let path = runtime.path.clone();
            let id = SharedString::from(format!("settings-runtime-storage-{}", runtime.name));
            storage = storage.row(
                "settings.modelStorage",
                settings_row::content_row(
                    id.clone(),
                    h_flex()
                        .gap(px(12.))
                        .items_center()
                        .child(div().flex_1().child(settings_row::help(
                            format!(
                                "llama.cpp · {} · {}",
                                lokalbot_i18n::tr(&runtime.name),
                                size_label(runtime.bytes)
                            ),
                            cx,
                        )))
                        .child(
                            Button::new(id)
                                .outline()
                                .small()
                                .label(lokalbot_i18n::tr("Show in Folder"))
                                .on_click(move |_, _, cx| cx.open_with_system(&path)),
                        ),
                    false,
                    cx,
                ),
            );
        }
        if !unused.is_empty() {
            let total: u64 = unused.iter().map(|id| model_bytes(id, &settings)).sum();
            let rows = unused.iter().map(|id| {
                let data = self.data.clone();
                let remove = id.clone();
                h_flex()
                    .gap(px(12.))
                    .items_center()
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .truncate()
                                    .child(model_name(id)),
                            )
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(format!(
                                        "{} · {}",
                                        model_purpose(id),
                                        size_label(model_bytes(id, &settings))
                                    )),
                            ),
                    )
                    .child(
                        Button::new(SharedString::from(format!("settings-remove-{id}")))
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Remove…"))
                            .on_click(move |_, window, cx| {
                                confirm_remove(data.clone(), remove.clone(), window, cx)
                            }),
                    )
            });
            storage = storage.row(
                "settings.unusedModels",
                settings_row::content_row(
                    "settings.unusedModels",
                    v_flex()
                        .gap(px(10.))
                        .child(
                            v_flex()
                                .gap(px(2.))
                                .child(
                                    div()
                                        .text_size(ty::BODY)
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(lb.text)
                                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Not used by your current settings"))),
                                )
                                .child(settings_row::help(
                                    lokalbot_i18n::format("Removing all of them frees about {0}. You can download any of them again later.", &[("0", size_label(total).to_string())]),
                                    cx,
                                )),
                        )
                        .children(rows),
                    false,
                    cx,
                ),
            );
        }

        // Processing budget.
        let budget_data = self.data.clone();
        let budget_index = BUDGETS
            .iter()
            .position(|b| *b == settings.generation_budget_preset)
            .unwrap_or(1);
        let mut budget_column = v_flex()
            .gap(px(8.))
            .child(
                div()
                    .text_size(ty::SECTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Think processing budget",
                    ))),
            )
            .child(settings_row::segmented(
                "settings-budget",
                &BUDGETS.map(budget_label),
                budget_index,
                move |index, _, cx| {
                    let budget = BUDGETS[index];
                    budget_data.update(cx, |data, cx| {
                        data.update_settings(|s| s.generation_budget_preset = budget, cx)
                    });
                },
                cx,
            ))
            .child(settings_row::help(
                lokalbot_i18n::format(
                    "Applies to every Think model — built-in and servers. {0}",
                    &[(
                        "0",
                        budget_detail(settings.generation_budget_preset).to_string(),
                    )],
                ),
                cx,
            ));
        if settings.generation_budget_preset == GenerationBudget::Unlimited {
            budget_column = budget_column.child(
                div().text_size(ty::SECONDARY).text_color(lb.attention_text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Unlimited removes practical caps: a single meeting can process for up to 6 hours. On a paid API this can run up significant token costs; on a local model it can keep this PC busy and hot for a long time."))),
            );
        }
        let budget = Section::new(None).row(
            "settings.generationBudgetPreset",
            settings_row::content_row(
                "settings.generationBudgetPreset",
                budget_column,
                self.is_focused("settings.generationBudgetPreset"),
                cx,
            ),
        );

        let semantic_data = self.data.clone();
        let also = Section::new(lokalbot_i18n::tr("Also used by LokalBot")).row(
            "settings.semanticSearchEnabled",
            settings_row::row(
                "settings.semanticSearchEnabled",
                lokalbot_i18n::tr("Search by meaning"),
                Some(
                    if settings.semantic_search_enabled {
                        lokalbot_i18n::tr("Managed automatically · On this PC")
                    } else {
                        lokalbot_i18n::tr("Off · On this PC")
                    }
                    .into(),
                ),
                settings_row::switch(
                    "settings.semanticSearchEnabled",
                    settings.semantic_search_enabled,
                    move |on, _, cx| {
                        semantic_data.update(cx, |data, cx| {
                            data.update_settings(|s| s.semantic_search_enabled = on, cx)
                        })
                    },
                ),
                self.is_focused("settings.semanticSearchEnabled"),
                cx,
            ),
        );

        let backend_data = self.data.clone();
        let backends = ["auto", "vulkan", "cuda", "cpu"];
        let selected_backend = backends
            .iter()
            .position(|b| settings.llama_backend.trim().eq_ignore_ascii_case(b))
            .unwrap_or(0);
        let cuda_selected = selected_backend == 2;
        let runtime_progress = downloads.get(RUNTIME_ID);
        let runtime_downloading = runtime_progress.is_some_and(|d| d.error.is_none());
        let runtime_detail = match runtime_progress {
            Some(progress) if progress.error.is_some() => progress
                .error
                .as_ref()
                .map(ToString::to_string)
                .unwrap_or_default(),
            Some(progress) => lokalbot_i18n::format(
                "Downloading · {0}%",
                &[("0", format!("{}", (progress.fraction() * 100.).round()))],
            ),
            None if status.runtime_backend.is_some() => format!(
                "{} · {}",
                lokalbot_i18n::tr("Ready"),
                status.runtime_backend.as_ref().unwrap()
            ),
            // Downloaded, but the setup GPU check failed: no download is left.
            None if status.runtime_needs_check => {
                format!("{} · CUDA", lokalbot_i18n::tr("Not ready"))
            }
            None => lokalbot_i18n::format(
                "About {0} to download",
                &[(
                    "0",
                    size_label(lokalbot_ai::runtime::download_bytes(
                        &settings.llama_backend,
                    )),
                )],
            ),
        };
        let runtime_data = self.data.clone();
        let runtime = Section::new("llama.cpp").row(
            "settings.llamaBackend",
            settings_row::content_row(
                "settings.llamaBackend",
                v_flex()
                    .gap(px(8.))
                    .child(settings_row::segmented(
                        "settings-llama-backend",
                        &[
                            lokalbot_i18n::tr("Automatic"),
                            "Vulkan",
                            lokalbot_i18n::tr("CUDA (experimental)"),
                            "CPU",
                        ],
                        selected_backend,
                        move |index, _, cx| {
                            backend_data.update(cx, |data, cx| {
                                data.update_settings(
                                    |s| s.llama_backend = backends[index].into(),
                                    cx,
                                )
                            });
                        },
                        cx,
                    ))
                    .child(
                        h_flex()
                            .gap(px(12.))
                            .items_center()
                            .child(div().flex_1().child(settings_row::help(runtime_detail, cx)))
                            .child(
                                Button::new("settings-runtime-download")
                                    .outline()
                                    .small()
                                    .label(if runtime_downloading {
                                        lokalbot_i18n::tr("Cancel")
                                    } else if cuda_selected
                                        && (status.runtime_backend.is_some()
                                            || status.runtime_needs_check)
                                    {
                                        // Setup repeats the GPU check and repairs
                                        // missing libraries without a full download.
                                        lokalbot_i18n::tr("Check again")
                                    } else {
                                        lokalbot_i18n::tr("Download")
                                    })
                                    .disabled(
                                        status.runtime_backend.is_some()
                                            && !cuda_selected
                                            && runtime_progress.is_none(),
                                    )
                                    .on_click(move |_, _, cx| {
                                        runtime_data.update(cx, |data, cx| {
                                            data.request(
                                                if runtime_downloading {
                                                    AppEvent::CancelDownload(RUNTIME_ID.into())
                                                } else {
                                                    AppEvent::DownloadModel(RUNTIME_ID.into())
                                                },
                                                cx,
                                            )
                                        });
                                    }),
                            ),
                    ),
                self.is_focused("settings.llamaBackend"),
                cx,
            ),
        );

        vec![
            summary, roles, runtime, presets, remote, storage, budget, also,
        ]
    }

    fn role_row(&self, row: RoleRow, choices: RoleChoices, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let settings = self.data.read(cx).settings.clone();
        let remote = row.remote.clone();
        let tint = if remote.is_some() {
            lb.attention_text
        } else {
            lb.accent_text
        };
        let location: SharedString = match (&remote, row.ready) {
            (Some(url), _) => {
                let host = lokalbot_core::access::origin_of(url).unwrap_or_else(|| url.clone());
                lokalbot_i18n::format("Remote · {host}", &[("host", host.to_string())]).into()
            }
            (None, true) => lokalbot_i18n::tr("On this PC · Downloaded").into(),
            (None, false) => lokalbot_i18n::tr("On this PC").into(),
        };
        // What this role still has to download.
        let missing: Vec<String> = row
            .needs
            .iter()
            .filter(|id| !row.installed.contains(id))
            .cloned()
            .collect();
        let missing_bytes: u64 = missing.iter().map(|id| model_bytes(id, &settings)).sum();
        let status: Option<(SharedString, gpui_kit::Hsla)> =
            match (row.downloading, row.ready, &remote) {
                (Some(fraction), _, _) => Some((
                    lokalbot_i18n::format(
                        "Downloading · {0}%",
                        &[("0", format!("{}", (fraction * 100.).round()))],
                    )
                    .into(),
                    lb.text_secondary,
                )),
                (None, false, None) if missing_bytes > 0 => Some((
                    lokalbot_i18n::format(
                        "Download required · {0}",
                        &[("0", size_label(missing_bytes).to_string())],
                    )
                    .into(),
                    lb.attention_text,
                )),
                (None, false, None) => Some((
                    lokalbot_i18n::tr("Download required").into(),
                    lb.attention_text,
                )),
                _ => None,
            };
        let data = self.data.clone();
        let options: Vec<ModelChoice> = match choices {
            RoleChoices::Speech => lokalbot_speech::models::transcription_models()
                .iter()
                .map(|m| {
                    let id = m.id;
                    (
                        SharedString::from(format!(
                            "{} · {}",
                            m.display_name,
                            size_label(m.archive.size)
                        )),
                        settings.transcription_model == id,
                        Box::new(move |s: &mut Settings| s.transcription_model = id.into())
                            as Box<dyn Fn(&mut Settings)>,
                    )
                })
                .collect(),
            RoleChoices::Think => {
                let mut items: Vec<ModelChoice> = lokalbot_ai::catalog::think_entries()
                    .map(|m| {
                        let id = m.id;
                        (
                            SharedString::from(format!(
                                "{} · {}",
                                m.display_name,
                                size_label(m.size_bytes)
                            )),
                            settings.summarizer_backend == SummarizerBackend::BuiltIn
                                && settings.built_in_model_id == id,
                            Box::new(move |s: &mut Settings| {
                                s.summarizer_backend = SummarizerBackend::BuiltIn;
                                s.built_in_model_id = id.into();
                            }) as Box<dyn Fn(&mut Settings)>,
                        )
                    })
                    .collect();
                items.push((
                    lokalbot_i18n::tr("Ollama server").into(),
                    settings.summarizer_backend == SummarizerBackend::Ollama,
                    Box::new(|s: &mut Settings| s.summarizer_backend = SummarizerBackend::Ollama),
                ));
                items.push((
                    lokalbot_i18n::tr("OpenAI-compatible server").into(),
                    settings.summarizer_backend == SummarizerBackend::OpenAICompatible,
                    Box::new(|s: &mut Settings| {
                        s.summarizer_backend = SummarizerBackend::OpenAICompatible
                    }),
                ));
                for plan in SubscriptionPlan::ALL {
                    items.push((
                        lokalbot_i18n::tr(plan.title()).into(),
                        settings.summarizer_backend == plan.backend(),
                        Box::new(move |s: &mut Settings| s.summarizer_backend = plan.backend()),
                    ));
                }
                items
            }
            RoleChoices::Autocomplete => lokalbot_ai::catalog::autocomplete_entries(Some(
                &settings.cotyping_built_in_model_id,
            ))
            .map(|m| {
                let id = m.id;
                (
                    SharedString::from(format!(
                        "{} · {}",
                        m.display_name,
                        size_label(m.size_bytes)
                    )),
                    settings.cotyping_built_in_model_id == id,
                    Box::new(move |s: &mut Settings| s.cotyping_built_in_model_id = id.into())
                        as Box<dyn Fn(&mut Settings)>,
                )
            })
            .collect(),
        };
        let options = std::rc::Rc::new(options);
        let change = Button::new(SharedString::from(format!("{}-change", row.id)))
            .outline()
            .small()
            .label(lokalbot_i18n::tr("Change…"))
            .dropdown_menu(move |mut menu, _, _| {
                for (index, (label, checked, _)) in options.iter().enumerate() {
                    let data = data.clone();
                    let options = options.clone();
                    menu = menu.item(
                        PopupMenuItem::new(label.clone())
                            .checked(*checked)
                            .on_click(move |_, _, cx| {
                                if let Some((_, _, apply)) = options.get(index) {
                                    data.update(cx, |data, cx| {
                                        data.update_settings(|s| apply(s), cx)
                                    });
                                }
                            }),
                    );
                }
                menu
            });

        let reasoning = matches!(choices, RoleChoices::Think).then(|| {
            let data = self.data.clone();
            let current = REASONING
                .iter()
                .find(|(level, _)| *level == settings.think_reasoning_level)
                .map(|(_, l)| *l)
                .unwrap_or(lokalbot_i18n::tr("Automatic"));
            h_flex()
                .gap(px(6.))
                .items_center()
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Reasoning"))),
                )
                .child(settings_row::picker(
                    "settings-reasoning",
                    current,
                    REASONING
                        .iter()
                        .map(|(level, label)| {
                            (
                                SharedString::from(*label),
                                *level == settings.think_reasoning_level,
                            )
                        })
                        .collect(),
                    move |index, _, cx| {
                        let level = REASONING[index].0;
                        data.update(cx, |data, cx| {
                            data.update_settings(|s| s.think_reasoning_level = level, cx)
                        });
                    },
                ))
        });

        settings_row::content_row(
            row.id,
            h_flex()
                .w_full()
                .gap(px(20.))
                .items_start()
                .py(px(4.))
                .child(
                    h_flex()
                        .w(px(210.))
                        .flex_none()
                        .gap(px(10.))
                        .items_center()
                        .child(
                            div()
                                .w(px(30.))
                                .flex_none()
                                .flex()
                                .justify_center()
                                .child(ui::icon(row.icon, px(20.), tint)),
                        )
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
                                        .child(row.title),
                                )
                                .child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(lb.text_secondary)
                                        .child(row.detail),
                                ),
                        ),
                )
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
                                .truncate()
                                .child(row.model),
                        )
                        .child(location_label(location, remote.is_some(), cx))
                        .when_some(status, |this, (text, color)| {
                            let cancel = row.downloading.is_some().then(|| {
                                let data = self.data.clone();
                                let ids = row.needs.clone();
                                div()
                                    .id(SharedString::from(format!("{}-cancel", row.id)))
                                    .cursor_pointer()
                                    .text_color(lb.accent_text)
                                    .hover(|s| s.underline())
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Cancel")))
                                    .on_click(move |_, _, cx| {
                                        data.update(cx, |data, cx| {
                                            for id in &ids {
                                                data.request(
                                                    AppEvent::CancelDownload(id.clone()),
                                                    cx,
                                                );
                                            }
                                        })
                                    })
                            });
                            // Download only what this role is missing.
                            let download =
                                (row.downloading.is_none() && !missing.is_empty()).then(|| {
                                    let data = self.data.clone();
                                    div()
                                        .id(SharedString::from(format!("{}-download", row.id)))
                                        .ml(px(4.))
                                        .cursor_pointer()
                                        .text_color(lb.accent_text)
                                        .hover(|s| s.underline())
                                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                            "Download",
                                        )))
                                        .on_click(move |_, _, cx| {
                                            data.update(cx, |data, cx| {
                                                for id in &missing {
                                                    data.request(
                                                        AppEvent::DownloadModel(id.clone()),
                                                        cx,
                                                    );
                                                }
                                            })
                                        })
                                });
                            this.child(
                                h_flex()
                                    .gap(px(5.))
                                    .items_center()
                                    .text_size(ty::SECONDARY)
                                    .text_color(color)
                                    .child(ui::icon(Ico::CircleAlert, px(13.), color))
                                    .child(text)
                                    .children(cancel)
                                    .children(download),
                            )
                        })
                        .children(reasoning),
                )
                .child(change),
            self.is_focused(row.id),
            cx,
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

        let back_page = page.clone();
        let header = v_flex()
            .gap(px(10.))
            .child(
                h_flex().child(
                    Button::new("settings-models-back")
                        .ghost()
                        .small()
                        .icon(Icon::new(Ico::ChevronLeft))
                        .label(lokalbot_i18n::tr("Models"))
                        .on_click(move |_, _, cx| {
                            back_page.update(cx, |page, cx| {
                                page.models.page = ModelsPage::Active;
                                cx.notify();
                            })
                        }),
                ),
            )
            .child(div().text_size(ty::SECTION).font_weight(FontWeight::BOLD).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Model connections"))))
            .child(settings_row::help(lokalbot_i18n::tr("Manage servers and credentials. Choose which provider Think uses under Core Roles."), cx));

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
                Section::new(None).row(
                    "settings.connectionsHeader",
                    settings_row::content_row("settings.connectionsHeader", header, false, cx),
                ),
                Section::new(None).row(
                    "settings.summarizerBackend",
                    settings_row::content_row(
                        "settings.summarizerBackend",
                        form.py(px(4.)),
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
                ));
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

        vec![
            Section::new(None).row(
                "settings.connectionsHeader",
                settings_row::content_row("settings.connectionsHeader", header, false, cx),
            ),
            Section::new(None).row(
                "settings.summarizerBackend",
                settings_row::content_row(
                    "settings.summarizerBackend",
                    form.py(px(4.)),
                    self.is_focused("settings.summarizerBackend"),
                    cx,
                ),
            ),
        ]
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
        if !origin.starts_with("https://")
            && !lokalbot_core::access::is_private_network_url(raw_url)
        {
            return h_flex()
                .gap(px(8.))
                .items_start()
                .child(ui::icon(Ico::Lock, px(14.), lb.attention_text))
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Blocked: remote inference must use HTTPS so transcripts and activity are encrypted in transit."))),
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
                    .child(div().text_size(ty::BODY).font_weight(FontWeight::SEMIBOLD).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::format("Remote processing · {host}", &[("host", host.to_string())])))),
            )
            .child(settings_row::help(lokalbot_i18n::tr("Think may send meeting transcripts, Ask questions with their sources, and dictation requests to this server when you use those features. Scheduled daily summaries also run here and can send activity titles and meeting evidence without a prompt each time."), cx))
            .child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(div().flex_1().min_w_0().text_size(ty::BODY).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::format("Allow sending context to {origin}", &[("origin", origin.to_string())]))))
                    .child(settings_row::switch("settings-remote-consent", approved, move |on, _, cx| {
                        let origin = toggle_origin.clone();
                        data.update(cx, |data, cx| {
                            data.update_settings(
                                |s| {
                                    s.approved_remote_inference_origins.retain(|o| !o.eq_ignore_ascii_case(&origin));
                                    if on {
                                        s.approved_remote_inference_origins.push(origin);
                                    }
                                },
                                cx,
                            )
                        })
                    })),
            )
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

struct RoleRow {
    id: &'static str,
    icon: Ico,
    title: &'static str,
    detail: &'static str,
    model: String,
    remote: Option<String>,
    ready: bool,
    /// Progress of the first of `needs` that is downloading.
    downloading: Option<f32>,
    /// Ids the role downloads (empty for a model server).
    needs: Vec<String>,
    installed: Vec<String>,
}

#[derive(Clone, Copy)]
enum RoleChoices {
    Speech,
    Think,
    Autocomplete,
}

/// "On this PC · Downloaded", or a remote origin in an amber capsule.
fn location_label(text: SharedString, remote: bool, cx: &App) -> Div {
    let lb = cx.lb();
    if remote {
        h_flex().child(
            h_flex()
                .gap(px(5.))
                .items_center()
                .px(px(7.))
                .py(px(2.))
                .rounded_full()
                .bg(lb.attention_text.opacity(if lb.dark { 0.16 } else { 0.08 }))
                .text_size(ty::SECONDARY)
                .text_color(lb.attention_text)
                .child(ui::icon(Ico::Network, px(12.), lb.attention_text))
                .child(text),
        )
    } else {
        h_flex()
            .gap(px(5.))
            .items_center()
            .text_size(ty::SECONDARY)
            .text_color(lb.text_secondary)
            .child(ui::icon(Ico::Monitor, px(12.), lb.text_secondary))
            .child(text)
    }
}

fn confirm_preset(
    data: Entity<AppData>,
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
        let data = data.clone();
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
                data.update(cx, |data, cx| {
                    data.update_settings(|s| preset.apply(s), cx);
                    if download > 0 {
                        data.request(AppEvent::PrepareModels, cx);
                    }
                });
                true
            })
    });
}

/// Asks before deleting a downloaded model the settings don't use.
fn confirm_remove(data: Entity<AppData>, id: String, window: &mut Window, cx: &mut App) {
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

fn confirm_revoke(data: Entity<AppData>, origin: String, window: &mut Window, cx: &mut App) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presets_round_trip() {
        let mut settings = Settings::default();
        Preset::Balanced.apply(&mut settings);
        assert!(Preset::Balanced.matches(&settings));
        assert!(!Preset::Lightweight.matches(&settings));
        assert_eq!(size_label(2_740_937_888), "2.7 GB");
        assert_eq!(size_label(730_895_584), "731 MB");
        assert_eq!(model_name("qwen3.5-4b"), "Qwen3.5 4B");
    }
}
