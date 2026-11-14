//! Settings › Models' first page (`ModelStackOverviewView`,
//! `ModelsPagePresentation`): what each of the three models does, which one
//! it is, where it runs, what it weighs and whether it is ready, under the
//! Model set; then rows that open the downloaded models, the online services
//! and the other models; then Advanced, folded. The header carries "Download
//! all" (`header::start_downloads`).
//!
//! Port-only parts and where they went: the llama.cpp backend (Automatic,
//! Vulkan, CUDA, CPU) and its runtime download sit under Advanced; download
//! mirrors are Advanced's "Download models from"; Ollama, OpenAI-compatible
//! servers and the ChatGPT and Claude plan sign-ins are Online services;
//! Hugging Face models are under Think's "Change…"; the transcription server
//! and language are under Transcribe's "Change…"; screen text recognition
//! files and the runtime's libraries are listed in Downloaded models.

use std::collections::HashMap;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, FontWeight, Hsla, InteractiveElement as _, IntoElement as _,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px,
};
use lokalbot_core::Settings;
use lokalbot_core::settings::{GenerationBudget, SummarizerBackend};
use lokalbot_engine::{ModelCheckStatus, ModelRole};

use super::models::{
    self, ModelsPage, Preset, RUNTIME_ID, model_bytes, model_name, models_in_use, size_label,
};
use super::status::{self, ModelInfo, ModelState, Role};
use super::{Section, SettingsPage};
use crate::pages::people::model::{directional, fill};
use crate::state::{AppEvent, DownloadProgress};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

/// What a row, or the button at its end, does when chosen.
type RowAction = std::rc::Rc<dyn Fn(&mut Window, &mut App)>;

/// The settings that are rows under Advanced: search and links that land on
/// one open it (`ModelStackOverviewView.advancedSettings`).
pub const ADVANCED_SETTINGS: [&str; 5] = [
    "settings.thinkReasoningLevel",
    "settings.generationBudgetPreset",
    "settings.modelDownloadSource",
    "settings.llamaBackend",
    "settings.modelStorage",
];

// ------------------------------------------------------------ presentation

/// Where a role's model runs (`ModelRoleRow.Place`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Place {
    ThisPc,
    /// A server or plan that receives what the model reads.
    Online(String),
    /// A server or plan that is chosen and not usable yet.
    NotSetUp,
}

/// The state beside a role's model (`ModelRoleRow.Chip`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Chip {
    Ready,
    NotDownloaded,
    /// `None` while the download has not said how far it is.
    Downloading(Option<f32>),
    Checking,
    CheckFailed,
    /// A download stopped.
    Stopped,
    NotSetUp,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChipTone {
    Good,
    Attention,
    Quiet,
}

impl Chip {
    pub fn tone(self) -> ChipTone {
        match self {
            Chip::Ready => ChipTone::Good,
            Chip::NotDownloaded | Chip::CheckFailed | Chip::Stopped | Chip::NotSetUp => {
                ChipTone::Attention
            }
            Chip::Downloading(_) | Chip::Checking => ChipTone::Quiet,
        }
    }

    pub fn text(self) -> String {
        match self {
            Chip::Ready => lokalbot_i18n::tr("Ready").to_string(),
            Chip::NotDownloaded => lokalbot_i18n::tr("Not downloaded").to_string(),
            Chip::Downloading(None) => lokalbot_i18n::tr("Downloading…").to_string(),
            Chip::Downloading(Some(fraction)) => fill(
                lokalbot_i18n::tr("Downloading · %lld%%"),
                &[&lokalbot_i18n::number(
                    (fraction.clamp(0.0, 1.0) * 100.).round() as usize,
                )],
            ),
            Chip::Checking => lokalbot_i18n::tr("Checking…").to_string(),
            Chip::CheckFailed => lokalbot_i18n::tr("Check failed").to_string(),
            Chip::Stopped => lokalbot_i18n::tr("Stopped").to_string(),
            Chip::NotSetUp => lokalbot_i18n::tr("Not set up").to_string(),
        }
    }
}

/// One row under "What each model does" (`ModelRoleRow`).
#[derive(Clone, Debug, PartialEq)]
pub struct RoleRow {
    pub role: Role,
    /// The selected model's own name.
    pub name: String,
    pub place: Place,
    /// What the model weighs, while it runs here and downloads.
    pub bytes: Option<u64>,
    pub chip: Chip,
    /// False for Autocomplete's model while Autocomplete is off: nothing
    /// waits for it, so its missing download is not a warning.
    pub needed: bool,
    /// Why a download stopped or a check failed, in the downloader's or the
    /// check's own words.
    pub problem: Option<String>,
}

impl RoleRow {
    pub fn title(&self) -> &'static str {
        match self.role {
            Role::Transcribe => lokalbot_i18n::tr("Transcribe"),
            Role::Think => lokalbot_i18n::tr("Think"),
            Role::Autocomplete => lokalbot_i18n::tr("Autocomplete"),
        }
    }

    /// What the model does, in plain words.
    pub fn job(&self) -> &'static str {
        match self.role {
            Role::Transcribe => lokalbot_i18n::tr("Turns meeting audio and dictation into text"),
            Role::Think => lokalbot_i18n::tr("Writes summaries and answers questions"),
            Role::Autocomplete => lokalbot_i18n::tr("Suggests the next words as you type"),
        }
    }

    pub fn icon(&self) -> Ico {
        match self.role {
            Role::Transcribe => Ico::AudioLines,
            Role::Think => Ico::Brain,
            Role::Autocomplete => Ico::TextCursorInput,
        }
    }

    pub fn chip_tone(&self) -> ChipTone {
        if self.chip == Chip::NotDownloaded && !self.needed {
            ChipTone::Quiet
        } else {
            self.chip.tone()
        }
    }

    /// "On this PC · 2.7 GB" or "Online · example.com". A choice that is not
    /// set up yet is an online one; its chip says the rest.
    pub fn place_text(&self) -> String {
        match &self.place {
            Place::Online(host) => format!("{} · {host}", lokalbot_i18n::tr("Online")),
            Place::NotSetUp => lokalbot_i18n::tr("Online").to_string(),
            Place::ThisPc => match self.bytes.filter(|bytes| *bytes > 0) {
                Some(bytes) => format!(
                    "{} · {}",
                    lokalbot_i18n::tr("On this PC"),
                    size_label(bytes)
                ),
                None => lokalbot_i18n::tr("On this PC").to_string(),
            },
        }
    }
}

/// The engine's name for a role, for its checks.
pub fn engine_role(role: Role) -> ModelRole {
    match role {
        Role::Transcribe => ModelRole::Transcribe,
        Role::Think => ModelRole::Think,
        Role::Autocomplete => ModelRole::Autocomplete,
    }
}

/// Where a role's model runs. A server on this computer's own address counts
/// as this computer: nothing leaves it.
pub fn place(role: Role, settings: &Settings) -> Place {
    use lokalbot_core::access::{host_of, is_loopback_url};
    match role {
        Role::Transcribe => {
            if !lokalbot_speech::models::is_remote(&settings.transcription_model) {
                return Place::ThisPc;
            }
            let server =
                lokalbot_core::remote_transcription::RemoteTranscription::from_settings(settings);
            if !server.is_ready() {
                Place::NotSetUp
            } else if server.is_on_this_computer() {
                Place::ThisPc
            } else {
                lokalbot_core::remote_transcription::audio_destination(settings)
                    .map_or(Place::NotSetUp, Place::Online)
            }
        }
        Role::Think => {
            if settings.summarizer_backend == SummarizerBackend::BuiltIn {
                return Place::ThisPc;
            }
            if !lokalbot_ai::think::allows_automatic_main_inference(settings) {
                return Place::NotSetUp;
            }
            if let Some(plan) = settings.think_plan() {
                return Place::Online(plan.destination_host().to_string());
            }
            let url = match settings.summarizer_backend {
                SummarizerBackend::Ollama => settings.ollama_base_url.trim(),
                _ => settings.openai_base_url.trim(),
            };
            if is_loopback_url(url) {
                Place::ThisPc
            } else {
                host_of(url).map_or(Place::NotSetUp, Place::Online)
            }
        }
        Role::Autocomplete => {
            use lokalbot_ai::autocomplete::server::{Route, route};
            match route(settings, None) {
                Route::OnDevice => Place::ThisPc,
                Route::Unavailable(_) => Place::NotSetUp,
                Route::Server(endpoint) if endpoint.is_on_this_computer() => Place::ThisPc,
                Route::Server(endpoint) => Place::Online(
                    host_of(&endpoint.base_url).unwrap_or_else(|| endpoint.origin.clone()),
                ),
            }
        }
    }
}

/// The role's model by its own name, a server's model with its host.
pub fn role_name(role: Role, settings: &Settings) -> String {
    match role {
        Role::Transcribe => super::model_options::transcription_name(settings),
        Role::Think => models::think_name(settings),
        Role::Autocomplete => super::writing_server::model_display_name(settings).to_string(),
    }
}

/// What the role's model weighs when it downloads to this computer, from
/// the sizes the header's download line uses: Transcribe with the files that
/// find speech, Think with the runtime that runs it.
fn role_bytes(role: Role, settings: &Settings) -> Option<u64> {
    let (ids, downloads) = status::role_ids(role, settings);
    if !downloads {
        return None;
    }
    let bytes: u64 = ids
        .iter()
        .filter(|id| role == Role::Think || id.as_str() != RUNTIME_ID)
        .map(|id| model_bytes(id, settings))
        .sum();
    (bytes > 0).then_some(bytes)
}

/// The three rows, from the status the header uses, the downloads and the
/// last checks (`ModelsPagePresentation.init`).
pub fn role_rows(
    settings: &Settings,
    models: &[ModelInfo],
    downloads: &HashMap<String, DownloadProgress>,
    checks: &ModelCheckStatus,
) -> Vec<RoleRow> {
    models
        .iter()
        .map(|info| {
            let role = info.role;
            let place = place(role, settings);
            let check = checks.result(engine_role(role));
            let failure = check.and_then(|result| result.failure.clone());
            let chip = match (&info.state, &place) {
                (_, Place::NotSetUp) => Chip::NotSetUp,
                (ModelState::Ready, _) if checks.testing == Some(engine_role(role)) => {
                    Chip::Checking
                }
                (ModelState::Ready, _) if failure.is_some() => Chip::CheckFailed,
                (ModelState::Ready, _) => Chip::Ready,
                (ModelState::Downloading(progress), _) => Chip::Downloading(*progress),
                (ModelState::Attention, _) if info.downloads => Chip::Stopped,
                (ModelState::Missing, _) if info.downloads => Chip::NotDownloaded,
                (ModelState::Attention | ModelState::Missing, _) => Chip::NotSetUp,
            };
            let (ids, _) = status::role_ids(role, settings);
            let download_error = ids
                .iter()
                .filter_map(|id| downloads.get(id).and_then(|d| d.error.clone()))
                .map(|error| error.to_string())
                .next();
            RoleRow {
                role,
                name: role_name(role, settings),
                bytes: (place == Place::ThisPc)
                    .then(|| role_bytes(role, settings))
                    .flatten(),
                place,
                chip,
                needed: role != Role::Autocomplete || settings.cotyping_enabled,
                problem: download_error.or_else(|| {
                    (info.state == ModelState::Ready)
                        .then_some(failure)
                        .flatten()
                }),
            }
        })
        .collect()
}

/// The preset the choices match, if any (`ModelStackPreset.matching`).
pub fn model_set(settings: &Settings) -> Option<Preset> {
    Preset::ALL
        .into_iter()
        .find(|preset| preset.matches(settings))
}

/// What a set's three models weigh together with it applied. `None` when
/// one of them does not download here: Autocomplete on a server
/// (`ModelsPagePresentation.bytes(of:)`).
pub fn preset_bytes(preset: Preset, settings: &Settings) -> Option<u64> {
    if settings.cotyping_backend != lokalbot_core::settings::CotypingBackend::OnDevice {
        return None;
    }
    let (speech, think) = preset.models();
    let sizes = [
        model_bytes(speech, settings),
        model_bytes(think, settings),
        model_bytes(&settings.cotyping_built_in_model_id, settings),
    ];
    (!sizes.contains(&0)).then(|| sizes.iter().sum())
}

/// The line under "Model set": what the set is for and what it weighs, or
/// that the models were picked by hand.
pub fn model_set_help(settings: &Settings) -> String {
    match model_set(settings) {
        Some(preset) => match preset_bytes(preset, settings) {
            Some(bytes) => fill(
                lokalbot_i18n::tr("%@ %@ in all."),
                &[lokalbot_i18n::tr(preset.subtitle()), &size_label(bytes)],
            ),
            None => lokalbot_i18n::tr(preset.subtitle()).to_string(),
        },
        None => lokalbot_i18n::tr(
            "You picked your own models. Choose a set to go back to one that was tested together.",
        )
        .to_string(),
    }
}

/// "Balanced local · 9.8 GB", or the title alone when a size is unknown.
pub fn preset_menu_title(preset: Preset, settings: &Settings) -> String {
    let title = lokalbot_i18n::tr(preset.title());
    match preset_bytes(preset, settings) {
        Some(bytes) => format!("{title} · {}", size_label(bytes)),
        None => title.to_string(),
    }
}

/// How many models Downloaded lists, or "None yet".
pub fn downloaded_summary(installed: &[String]) -> String {
    let count = installed
        .iter()
        .filter(|id| id.as_str() != RUNTIME_ID)
        .count();
    if count == 0 {
        lokalbot_i18n::tr("None yet").to_string()
    } else {
        lokalbot_i18n::number(count)
    }
}

/// The services approved to receive something, each named once, or that
/// none is.
pub fn online_summary(settings: &Settings) -> String {
    let mut names: Vec<String> = Vec::new();
    for origin in settings
        .approved_remote_inference_origins
        .iter()
        .chain(&settings.approved_remote_transcription_origins)
    {
        // A server by its host, a plan by its name.
        let name = match lokalbot_core::settings::SubscriptionPlan::for_consent_key(origin) {
            Some(plan) => lokalbot_i18n::tr(plan.title()).to_string(),
            None => lokalbot_core::access::host_of(origin).unwrap_or_else(|| origin.clone()),
        };
        if !names.contains(&name) {
            names.push(name);
        }
    }
    if names.is_empty() {
        lokalbot_i18n::tr("None set up").to_string()
    } else {
        names.join(", ")
    }
}

// --------------------------------------------------------------- drawing

impl SettingsPage {
    /// The first page of Models.
    pub(super) fn models_overview(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<Section> {
        self.look_up_reasoning(cx);
        let (settings, status, downloads, checks) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.models.clone(),
                data.downloads.clone(),
                data.model_checks.clone(),
            )
        };
        let infos = status::models(&settings, &status, &downloads);
        let rows = role_rows(&settings, &infos, &downloads, &checks);
        // Below this the row stacks its model under its name (`ViewThatFits`).
        let compact = window.viewport_size().width < px(960.);

        let mut sections = Vec::new();
        if let Some(feedback) = self.model_setup_feedback(cx) {
            sections.push(Section::new(None).row("settings-model-switch", feedback));
        }

        let mut roles = Section::new(lokalbot_i18n::tr("What each model does"))
            .row("settings.models", self.model_set_row(&settings, cx));
        for row in &rows {
            let element = self.role_row(row, &settings, compact, cx);
            roles = roles.row(models::role_setting(row.role), element);
        }
        sections.push(roles);

        let page = cx.entity();
        let open = move |target: ModelsPage| {
            let page = page.clone();
            move |_: &mut Window, cx: &mut App| {
                page.update(cx, |page, cx| {
                    page.models.page = target;
                    cx.notify();
                })
            }
        };
        sections.push(
            Section::new(lokalbot_i18n::tr("More"))
                .row(
                    "settings.unusedModels",
                    drill_row(
                        "settings-models-more-downloaded",
                        lokalbot_i18n::tr("Downloaded models"),
                        Some(lokalbot_i18n::tr("Delete ones you no longer use")),
                        Some(downloaded_summary(&status.installed)),
                        open(ModelsPage::Downloaded),
                        cx,
                    ),
                )
                .row(
                    "settings.summarizerBackend",
                    drill_row(
                        "settings-models-more-online",
                        lokalbot_i18n::tr("Online services"),
                        Some(lokalbot_i18n::tr(
                            "Your AI subscription, or a server you run",
                        )),
                        Some(online_summary(&settings)),
                        open(ModelsPage::Connections),
                        cx,
                    ),
                )
                .row(
                    "settings.semanticSearchEnabled",
                    drill_row(
                        "settings-models-more-other",
                        lokalbot_i18n::tr("Other models"),
                        Some(lokalbot_i18n::tr(
                            "Read aloud, search by meaning, Dictation’s Compose",
                        )),
                        Some(lokalbot_i18n::tr("On this PC").to_string()),
                        open(ModelsPage::Other),
                        cx,
                    ),
                ),
        );
        sections.extend(self.models_advanced(&settings, &status, &downloads, cx));
        sections
    }

    /// The set the three models belong to, as a menu. Choosing one opens its
    /// review, which lists the changes and the download before anything is
    /// applied (`modelSetRow`).
    fn model_set_row(&self, settings: &Settings, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let current = model_set(settings);
        let switching = self.models.setup.is_switching();
        let installed = self.data.read(cx).models.installed.clone();
        let page = cx.entity();
        let entries: Vec<(Preset, String, u64)> = Preset::ALL
            .into_iter()
            .map(|preset| {
                let (speech, think) = preset.models();
                // What applying it would download now.
                let download: u64 = [speech, think]
                    .iter()
                    .filter(|id| !installed.iter().any(|have| have == *id))
                    .map(|id| model_bytes(id, settings))
                    .sum();
                (preset, preset_menu_title(preset, settings), download)
            })
            .collect();
        let title = current
            .map(|preset| lokalbot_i18n::tr(preset.title()))
            .unwrap_or(lokalbot_i18n::tr("Custom"));
        let menu = Button::new("settings-model-set")
            .outline()
            .small()
            .label(title)
            .dropdown_caret(true)
            .disabled(switching)
            .dropdown_menu(move |mut menu, _, _| {
                for (preset, label, download) in &entries {
                    let page = page.clone();
                    let (preset, download) = (*preset, *download);
                    let selected = Some(preset) == current;
                    menu = menu.item(
                        PopupMenuItem::new(label.clone())
                            .checked(selected)
                            .disabled(selected)
                            .on_click(move |_, window, cx| {
                                models::confirm_preset(page.clone(), preset, download, window, cx)
                            }),
                    );
                }
                menu
            });
        settings_row::content_row(
            "settings.models",
            h_flex()
                .w_full()
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
                                .child(lokalbot_i18n::tr("Model set")),
                        )
                        .child(settings_row::help(model_set_help(settings), cx)),
                )
                .child(div().flex_none().child(menu)),
            self.is_focused("settings.models"),
            cx,
        )
        .into_any_element()
    }

    /// One role: its job, its model and where it runs, the chip, Change…
    fn role_row(
        &self,
        row: &RoleRow,
        settings: &Settings,
        compact: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let id = models::role_setting(row.role);
        let away = row.place != Place::ThisPc;
        let tint = if away {
            lb.attention_text
        } else {
            lb.accent_text
        };
        let heading = h_flex()
            .gap(px(10.))
            .items_center()
            .min_w_0()
            .child(ui::icon_tile(row.icon(), tint, px(32.)))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(lb.text)
                            .child(row.title()),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .line_height(px(18.))
                            .text_color(lb.text_secondary)
                            .child(ui::text::paragraph(row.job())),
                    ),
            );
        let place_icon = match row.place {
            Place::ThisPc => Ico::Monitor,
            Place::NotSetUp => Ico::TriangleAlert,
            Place::Online(_) => Ico::Globe,
        };
        let place_color = if away {
            lb.attention_text
        } else {
            lb.text_secondary
        };
        let plan = (row.role == Role::Think)
            .then(|| settings.think_plan())
            .flatten()
            .filter(|plan| plan.is_approved(settings));
        let page = cx.entity();
        let role = row.role;
        let summary = v_flex()
            .min_w_0()
            .gap(px(3.))
            .child(
                div()
                    .text_size(ty::BODY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .line_clamp(2)
                    .child(row.name.clone()),
            )
            .child(
                h_flex()
                    .gap(px(5.))
                    .items_center()
                    .min_w_0()
                    .text_size(ty::SECONDARY)
                    .text_color(place_color)
                    .child(ui::icon(place_icon, px(12.), place_color))
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .child(directional(row.place_text())),
                    ),
            )
            .when_some(plan, |this, plan| {
                this.child(super::plans::manage_usage(
                    "settings-models-plan-usage",
                    plan,
                    cx,
                ))
            })
            .when_some(row.problem.clone(), |this, problem| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .line_clamp(3)
                        .child(ui::text::paragraph(problem)),
                )
            })
            .when(row.place == Place::NotSetUp, |this| {
                this.child(settings_row::link_button(
                    SharedString::from(format!("{id}-review")),
                    lokalbot_i18n::tr("Review Connection…"),
                    move |window, cx| {
                        page.update(cx, |page, cx| page.review_connection(role, window, cx))
                    },
                    cx,
                ))
            });
        let chip = self.chip(row, cx);
        let change = self.change_button(row.role, cx);
        let content = if compact {
            v_flex()
                .w_full()
                .gap(px(10.))
                .child(
                    h_flex()
                        .w_full()
                        .gap(px(12.))
                        .items_center()
                        .child(heading.flex_1())
                        .child(chip)
                        .child(change),
                )
                .child(summary.pl(px(42.)))
        } else {
            v_flex().w_full().child(
                h_flex()
                    .w_full()
                    .gap(px(16.))
                    .items_center()
                    .child(heading.w(px(236.)).flex_none())
                    .child(summary.flex_1())
                    .child(chip)
                    .child(change),
            )
        };
        settings_row::content_row(id, content.py(px(2.)), self.is_focused(id), cx)
            .into_any_element()
    }

    /// The chip, with when the model last answered its check as its tooltip.
    fn chip(&self, row: &RoleRow, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let (color, fill_color): (Hsla, Hsla) = match row.chip_tone() {
            ChipTone::Good => (lb.success_text, lb.status_fill(lb.success)),
            ChipTone::Attention => (lb.attention_text, lb.status_fill(lb.attention)),
            ChipTone::Quiet => (lb.text_secondary, lb.quiet_fill),
        };
        let checked = (row.chip == Chip::Ready)
            .then(|| {
                self.data
                    .read(cx)
                    .model_checks
                    .result(engine_role(row.role))
                    .filter(|result| result.failure.is_none())
                    .map(|result| {
                        fill(
                            lokalbot_i18n::tr("Checked at %@"),
                            &[&result.checked_at.format("%H:%M").to_string()],
                        )
                    })
            })
            .flatten();
        div()
            .id(SharedString::from(format!(
                "{}-chip",
                models::role_setting(row.role)
            )))
            .flex_none()
            .px(px(8.))
            .py(px(2.))
            .rounded_full()
            .bg(fill_color)
            .text_size(ty::CAPTION)
            .font_weight(FontWeight::MEDIUM)
            .text_color(color)
            .whitespace_nowrap()
            .child(directional(row.chip.text()))
            .when_some(checked, |this, text| {
                this.tooltip(move |window, cx| Tooltip::new(text.clone()).build(window, cx))
            })
            .into_any_element()
    }

    /// Each server is set up where it is chosen: Think's on Online services,
    /// Transcribe's on its server page, Autocomplete's on its own page.
    fn review_connection(&mut self, role: Role, window: &mut Window, cx: &mut Context<Self>) {
        match role {
            Role::Transcribe => {
                self.models.page = ModelsPage::TranscriptionServer;
                cx.notify();
            }
            Role::Think => {
                self.models.page = ModelsPage::Connections;
                cx.notify();
            }
            Role::Autocomplete => self.reveal("settings.cotypingBackend", window, cx),
        }
    }

    /// Advanced, folded until opened or until search lands on one of its
    /// settings.
    fn models_advanced(
        &mut self,
        settings: &Settings,
        status: &crate::state::ModelStatus,
        downloads: &HashMap<String, DownloadProgress>,
        cx: &mut Context<Self>,
    ) -> Vec<Section> {
        let lb = cx.lb().clone();
        let expanded = self.models.advanced_open
            || self.focused.is_some_and(|id| {
                ADVANCED_SETTINGS.contains(&id) || id == status::MODEL_CHECKS_FOCUS
            });
        let page = cx.entity();
        let flip: RowAction = std::rc::Rc::new(move |_, cx| {
            page.update(cx, |page, cx| {
                page.models.advanced_open = !expanded;
                // Folding drops the highlight that kept it open.
                if expanded {
                    page.focused = None;
                }
                cx.notify();
            })
        });
        let button_flip = flip.clone();
        let toggle = h_flex()
            .id("settings-models-advanced")
            .gap(px(4.))
            .items_center()
            .cursor_pointer()
            .child(
                Button::new("settings-models-advanced-toggle")
                    .ghost()
                    .xsmall()
                    .icon(gpui_kit::component::Icon::new(if expanded {
                        Ico::ChevronDown
                    } else if lokalbot_i18n::current().rtl {
                        Ico::ChevronLeft
                    } else {
                        Ico::ChevronRight
                    }))
                    .tooltip(if expanded {
                        lokalbot_i18n::tr("Expanded")
                    } else {
                        lokalbot_i18n::tr("Collapsed")
                    })
                    .on_click(move |_, window, cx| {
                        cx.stop_propagation();
                        button_flip(window, cx)
                    }),
            )
            .child(
                div()
                    .text_size(ty::SECTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(lokalbot_i18n::tr("Advanced")),
            )
            .on_click(move |_, window, cx| flip(window, cx));
        if !expanded {
            return vec![Section::bare(toggle)];
        }
        let advanced_row = |id: &'static str,
                            title: &'static str,
                            detail: String,
                            control: AnyElement,
                            focused: bool,
                            cx: &mut Context<Self>| {
            settings_row::row(id, title, Some(detail.into()), control, focused, cx)
                .into_any_element()
        };
        let reasoning = self.reasoning_control(cx);
        let budget = self.budget_control(cx);
        let mut budget_detail = v_flex().gap(px(4.)).child(settings_row::help(
            lokalbot_i18n::tr(models::budget_detail(settings.generation_budget_preset)),
            cx,
        ));
        if settings.generation_budget_preset == GenerationBudget::Unlimited {
            budget_detail = budget_detail.child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.attention_text)
                    .child(ui::text::paragraph(lokalbot_i18n::tr("Unlimited removes practical caps: a single meeting can process for up to 6 hours. On a paid API this can run up significant token costs; on a local model it can keep this PC busy and hot for a long time."))),
            );
        }
        let source_data = self.data.clone();
        let checks_page = cx.entity();
        let section = Section::new(None)
            .header(toggle)
            .row(
                "settings.thinkReasoningLevel",
                advanced_row(
                    "settings.thinkReasoningLevel",
                    lokalbot_i18n::tr("How long Think reasons"),
                    lokalbot_i18n::tr(
                        "Automatic lets each task decide. A level sets the most any task uses.",
                    )
                    .to_string(),
                    reasoning,
                    self.is_focused("settings.thinkReasoningLevel"),
                    cx,
                ),
            )
            .row(
                "settings.generationBudgetPreset",
                settings_row::content_row(
                    "settings.generationBudgetPreset",
                    v_flex()
                        .w_full()
                        .gap(px(6.))
                        .child(
                            h_flex()
                                .w_full()
                                .gap(px(16.))
                                .items_center()
                                .child(
                                    settings_row::label(
                                        lokalbot_i18n::tr("Effort on long meetings"),
                                        Some(lokalbot_i18n::tr("More effort reads more of a long meeting, and takes longer. It applies to every Think model.").into()),
                                        cx,
                                    )
                                    .flex_1(),
                                )
                                .child(div().flex_none().child(budget)),
                        )
                        .child(budget_detail),
                    self.is_focused("settings.generationBudgetPreset"),
                    cx,
                )
                .into_any_element(),
            )
            .row(
                "settings.modelDownloadSource",
                super::model_options::download_source_row(
                    settings.model_download_source,
                    self.is_focused("settings.modelDownloadSource"),
                    move |source, _, cx| {
                        source_data.update(cx, |data, cx| {
                            data.update_settings(|s| s.model_download_source = source, cx)
                        })
                    },
                    cx,
                )
                .into_any_element(),
            )
            .row("settings.llamaBackend", self.llama_row(settings, status, downloads, cx))
            .row("settings.modelStorage", self.storage_row(status, cx))
            .row(
                status::MODEL_CHECKS_FOCUS,
                advanced_row(
                    status::MODEL_CHECKS_FOCUS,
                    lokalbot_i18n::tr("Check the models"),
                    lokalbot_i18n::tr(
                        "Check each available model independently using sample content.",
                    )
                    .to_string(),
                    Button::new("settings-check-models")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Check Setup…"))
                        .on_click(move |_, _, cx| {
                            checks_page.update(cx, |page, cx| {
                                page.models.page = ModelsPage::Checks;
                                cx.notify();
                            })
                        })
                        .into_any_element(),
                    self.is_focused(status::MODEL_CHECKS_FOCUS),
                    cx,
                ),
            );
        vec![section]
    }

    /// The llama.cpp runtime that runs Think, Autocomplete and search here:
    /// its backend and its download (port-only).
    fn llama_row(
        &self,
        settings: &Settings,
        status: &crate::state::ModelStatus,
        downloads: &HashMap<String, DownloadProgress>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
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
            None => match &status.runtime_backend {
                Some(backend) => format!("{} · {backend}", lokalbot_i18n::tr("Ready")),
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
            },
        };
        let runtime_data = self.data.clone();
        let installed = status.runtime_backend.is_some();
        let needs_check = status.runtime_needs_check;
        settings_row::content_row(
            "settings.llamaBackend",
            v_flex()
                .w_full()
                .gap(px(8.))
                .child(settings_row::label("llama.cpp", None, cx))
                .child(h_flex().child(settings_row::segmented(
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
                            data.update_settings(|s| s.llama_backend = backends[index].into(), cx)
                        });
                    },
                    cx,
                )))
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
                                } else if cuda_selected && (installed || needs_check) {
                                    // Setup repeats the GPU check and repairs
                                    // missing libraries without a full download.
                                    lokalbot_i18n::tr("Check again")
                                } else {
                                    lokalbot_i18n::tr("Download")
                                })
                                .disabled(installed && !cuda_selected && runtime_progress.is_none())
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
        )
        .into_any_element()
    }

    /// Where the model files are and what is loaded now (`ModelStorageRow`).
    fn storage_row(
        &self,
        status: &crate::state::ModelStatus,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let root = self.data.read(cx).library.paths().clone();
        let models_dir = root.models_dir();
        let open_dir = models_dir.clone();
        let library_root = root.root().to_path_buf();
        let stored = status
            .installed
            .iter()
            .filter(|id| id.as_str() != RUNTIME_ID)
            .count();
        settings_row::content_row(
            "settings.modelStorage",
            h_flex()
                .w_full()
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
                                .text_color(lb.text)
                                .child(lokalbot_i18n::tr("Model Storage")),
                        )
                        .child(settings_row::help(
                            match stored {
                                0 => lokalbot_i18n::tr("No models downloaded yet").to_string(),
                                1 => lokalbot_i18n::tr("1 model on this PC").to_string(),
                                n => lokalbot_i18n::format(
                                    "{n} models on this PC",
                                    &[("n", lokalbot_i18n::number(n))],
                                ),
                            },
                            cx,
                        ))
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .truncate()
                                .child(models_dir.display().to_string()),
                        )
                        .child(settings_row::help(
                            super::resource_monitor::memory_summary(cx),
                            cx,
                        )),
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
        )
        .into_any_element()
    }

    /// Downloaded models (`ModelDownloadsView`): every model file here with
    /// what it is for and its size, the downloads under way, the runtime's
    /// libraries and Read aloud's voice. A model the settings don't use can be
    /// removed; one in use stays (the port never deletes a model in use).
    pub(super) fn downloaded_models_page(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let lb = cx.lb().clone();
        let (settings, status, downloads) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.models.clone(),
                data.downloads.clone(),
            )
        };
        let page = cx.entity();
        let bar = Section::bare(super::subpage::bar(
            "settings-models-back",
            lokalbot_i18n::tr("Models"),
            lokalbot_i18n::tr("Downloaded models"),
            move |_, cx| {
                page.update(cx, |page, cx| {
                    page.models.page = ModelsPage::Active;
                    cx.notify();
                })
            },
            cx,
        ));
        let in_use = models_in_use(&settings);
        let mut ids: Vec<String> = status
            .installed
            .iter()
            .filter(|id| {
                id.as_str() != RUNTIME_ID && id.as_str() != lokalbot_speech::models::KOKORO_MODEL
            })
            .cloned()
            .collect();
        for id in downloads.keys() {
            if !ids.contains(id)
                && id.as_str() != RUNTIME_ID
                && id.as_str() != lokalbot_speech::models::KOKORO_MODEL
            {
                ids.push(id.clone());
            }
        }
        ids.sort_by_key(|id| model_name(id).to_lowercase());
        let mut list = Section::new(None).row(
            "settings.downloadedHeader",
            settings_row::content_row(
                "settings.downloadedHeader",
                v_flex()
                    .gap(px(4.))
                    .child(
                        div()
                            .text_size(ty::SECTION)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(lokalbot_i18n::tr("Models on this PC")),
                    )
                    .child(settings_row::help(
                        lokalbot_i18n::tr("Manage downloads and free up disk space. Each model shows the features that use it."),
                        cx,
                    )),
                false,
                cx,
            ),
        );
        if ids.is_empty() {
            list = list.row(
                "settings.downloadedEmpty",
                settings_row::content_row(
                    "settings.downloadedEmpty",
                    settings_row::help(lokalbot_i18n::tr("No models downloaded yet"), cx),
                    false,
                    cx,
                ),
            );
        }
        for id in &ids {
            let progress = downloads.get(id);
            let used = in_use.contains(id);
            let detail = format!(
                "{} · {}",
                models::model_purpose(id),
                size_label(model_bytes(id, &settings))
            );
            let data = self.data.clone();
            let target = id.clone();
            let control: AnyElement = match progress {
                Some(progress) if progress.error.is_none() => h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(settings_row::help(
                        lokalbot_i18n::format(
                            "Downloading · {0}%",
                            &[("0", format!("{}", (progress.fraction() * 100.).round()))],
                        ),
                        cx,
                    ))
                    .child(
                        Button::new(SharedString::from(format!("settings-cancel-{id}")))
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Cancel"))
                            .on_click(move |_, _, cx| {
                                data.update(cx, |data, cx| {
                                    data.request(AppEvent::CancelDownload(target.clone()), cx)
                                })
                            }),
                    )
                    .into_any_element(),
                Some(_) => Button::new(SharedString::from(format!("settings-retry-{id}")))
                    .outline()
                    .small()
                    .label(lokalbot_i18n::tr("Retry"))
                    .on_click(move |_, _, cx| {
                        data.update(cx, |data, cx| {
                            data.request(AppEvent::DownloadModel(target.clone()), cx)
                        })
                    })
                    .into_any_element(),
                None => Button::new(SharedString::from(format!("settings-remove-{id}")))
                    .outline()
                    .small()
                    .label(lokalbot_i18n::tr("Remove…"))
                    .disabled(used || self.models.setup.is_switching())
                    .on_click(move |_, window, cx| {
                        models::confirm_remove(data.clone(), target.clone(), window, cx)
                    })
                    .into_any_element(),
            };
            let error = progress.and_then(|d| d.error.clone());
            list = list.row(
                "settings.unusedModels",
                settings_row::content_row(
                    SharedString::from(format!("settings-downloaded-{id}")),
                    h_flex()
                        .w_full()
                        .gap(px(12.))
                        .items_center()
                        .child(ui::icon(Ico::Package, px(16.), lb.text_secondary))
                        .child(
                            v_flex()
                                .flex_1()
                                .min_w_0()
                                .gap(px(2.))
                                .child(
                                    div()
                                        .text_size(ty::BODY)
                                        .font_weight(FontWeight::MEDIUM)
                                        .text_color(lb.text)
                                        .truncate()
                                        .child(model_name(id)),
                                )
                                .child(settings_row::help(detail, cx))
                                .when(!used && progress.is_none(), |this| {
                                    this.child(settings_row::help(
                                        lokalbot_i18n::tr("Not used by your current settings"),
                                        cx,
                                    ))
                                })
                                .when_some(error, |this, error| {
                                    this.child(
                                        div()
                                            .text_size(ty::SECONDARY)
                                            .text_color(lb.attention_text)
                                            .child(ui::text::paragraph(error)),
                                    )
                                }),
                        )
                        .child(control),
                    false,
                    cx,
                ),
            );
        }
        let unused = models::unused_models(&settings, &status.installed);
        if !unused.is_empty() {
            let total: u64 = unused.iter().map(|id| model_bytes(id, &settings)).sum();
            list = list.row(
                "settings.unusedModelsHelp",
                settings_row::content_row(
                    "settings.unusedModelsHelp",
                    settings_row::help(
                        lokalbot_i18n::format(
                            "Removing all of them frees about {0}. You can download any of them again later.",
                            &[("0", size_label(total))],
                        ),
                        cx,
                    ),
                    false,
                    cx,
                ),
            );
        }
        let mut sections = vec![bar, list];
        let mut more = Section::new(None);
        for runtime in &status.runtime_storage {
            let path = runtime.path.clone();
            let id = SharedString::from(format!("settings-runtime-storage-{}", runtime.name));
            more = more.row(
                "settings.modelStorage",
                settings_row::content_row(
                    id.clone(),
                    h_flex()
                        .gap(px(12.))
                        .items_center()
                        .child(ui::icon(Ico::HardDrive, px(16.), lb.text_secondary))
                        .child(div().flex_1().min_w_0().child(settings_row::help(
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
        if let Some(row) = self.read_aloud_storage_row(cx) {
            more = more.row("settings.speechVoice", row);
        }
        if !more.rows.is_empty() {
            sections.push(more);
        }
        sections
    }

    /// Other models (`ModelOtherModelsView`): Dictation's Compose, Read aloud
    /// and search by meaning, each where it is set.
    pub(super) fn other_models_page(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let lb = cx.lb().clone();
        let settings = self.data.read(cx).settings.clone();
        let page = cx.entity();
        let back = page.clone();
        let bar = Section::bare(super::subpage::bar(
            "settings-models-back",
            lokalbot_i18n::tr("Models"),
            lokalbot_i18n::tr("Other models"),
            move |_, cx| {
                back.update(cx, |page, cx| {
                    page.models.page = ModelsPage::Active;
                    cx.notify();
                })
            },
            cx,
        ));
        // Compose writes with Think unless a built-in model is chosen for it.
        let composition = lokalbot_ai::dictation::composition_settings(&settings);
        let (_, hosts) = crate::state::inference_presentation(&composition);
        let compose_value = if settings.dictation_composition_built_in_model_id.is_empty() {
            lokalbot_i18n::tr("Same as Think").to_string()
        } else {
            model_name(&settings.dictation_composition_built_in_model_id)
        };
        let compose_remote = !hosts.is_empty();
        let to_dictation = page.clone();
        let to_voice = page.clone();
        let search_data = self.data.clone();
        let section = Section::new(None)
            .row(
                "settings.dictationCompositionBuiltInModelID",
                other_row(
                    "settings-models-other-compose",
                    Ico::MessageSquareText,
                    lokalbot_i18n::tr("Dictation composition"),
                    compose_remote
                        .then(|| lokalbot_i18n::tr("Spoken requests are composed remotely.")),
                    compose_value,
                    compose_remote,
                    move |window, cx| {
                        to_dictation.update(cx, |page, cx| {
                            page.reveal("settings.dictationCompositionBuiltInModelID", window, cx)
                        })
                    },
                    cx,
                ),
            )
            .row(
                "settings.speechVoice",
                other_row(
                    "settings-models-other-voice",
                    Ico::Volume2,
                    lokalbot_i18n::tr("Read aloud"),
                    None,
                    lokalbot_i18n::tr("Kokoro 82M · On this PC").to_string(),
                    false,
                    move |_, cx| {
                        to_voice.update(cx, |page, cx| {
                            page.models.page = ModelsPage::ReadAloud;
                            cx.notify();
                        })
                    },
                    cx,
                ),
            )
            .row(
                "settings.semanticSearchEnabled",
                settings_row::content_row(
                    "settings.semanticSearchEnabled",
                    h_flex()
                        .w_full()
                        .gap(px(10.))
                        .items_center()
                        .child(ui::icon_tile(Ico::Search, lb.accent_text, px(30.)))
                        .child(
                            settings_row::label(
                                lokalbot_i18n::tr("Search by meaning"),
                                Some(
                                    if settings.semantic_search_enabled {
                                        lokalbot_i18n::tr("Managed automatically · On this PC")
                                    } else {
                                        lokalbot_i18n::tr("Off · On this PC")
                                    }
                                    .into(),
                                ),
                                cx,
                            )
                            .flex_1(),
                        )
                        .child(settings_row::switch(
                            "settings.semanticSearchEnabled",
                            settings.semantic_search_enabled,
                            move |on, _, cx| {
                                search_data.update(cx, |data, cx| {
                                    data.update_settings(|s| s.semantic_search_enabled = on, cx)
                                })
                            },
                        )),
                    self.is_focused("settings.semanticSearchEnabled"),
                    cx,
                ),
            );
        vec![bar, section]
    }
}

/// A row that opens another page: its name, an optional line under it, an
/// optional value and a chevron (`SettingsDrillRow`, `moreRow`).
pub(super) fn drill_row(
    id: &'static str,
    title: impl Into<SharedString>,
    detail: Option<&'static str>,
    value: Option<String>,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let title: SharedString = title.into();
    let on_click: RowAction = std::rc::Rc::new(on_click);
    let open = opener_button(id, title.clone(), on_click.clone());
    h_flex()
        .id(id)
        .w_full()
        .px(px(14.))
        .py(px(10.))
        .gap(px(10.))
        .items_center()
        .cursor_pointer()
        .rounded(crate::theme::metric::GROUP_RADIUS)
        .hover(|s| s.bg(lb.hover))
        .child(settings_row::label(title, detail.map(SharedString::from), cx).flex_1())
        .when_some(value, |this, value| {
            this.child(
                div()
                    .flex_none()
                    .max_w(px(220.))
                    .truncate()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(directional(value)),
            )
        })
        .child(open)
        .on_click(move |_, window, cx| on_click(window, cx))
        .into_any_element()
}

/// One row of Other models: its icon, its name, where it runs, and a way to
/// where it is set.
#[allow(clippy::too_many_arguments)]
fn other_row(
    id: &'static str,
    icon: Ico,
    title: &'static str,
    detail: Option<&'static str>,
    value: String,
    remote: bool,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let tint = if remote {
        lb.attention_text
    } else {
        lb.accent_text
    };
    let on_click: RowAction = std::rc::Rc::new(on_click);
    let open = opener_button(id, title.into(), on_click.clone());
    h_flex()
        .id(id)
        .w_full()
        .px(px(14.))
        .py(px(10.))
        .gap(px(10.))
        .items_center()
        .cursor_pointer()
        .rounded(crate::theme::metric::GROUP_RADIUS)
        .hover(|s| s.bg(lb.hover))
        .child(ui::icon_tile(icon, tint, px(30.)))
        .child(settings_row::label(title, detail.map(SharedString::from), cx).flex_1())
        .child(
            div()
                .flex_none()
                .max_w(px(260.))
                .text_size(ty::SECONDARY)
                .text_color(if remote {
                    lb.attention_text
                } else {
                    lb.text_secondary
                })
                .child(ui::text::paragraph(directional(value))),
        )
        .child(open)
        .on_click(move |_, window, cx| on_click(window, cx))
        .into_any_element()
}

/// The chevron at a row's end, as a button: the row takes the pointer, and
/// this is where Tab and Return reach it.
fn opener_button(id: &'static str, title: SharedString, on_click: RowAction) -> Button {
    let chevron = if lokalbot_i18n::current().rtl {
        Ico::ChevronLeft
    } else {
        Ico::ChevronRight
    };
    Button::new(SharedString::from(format!("{id}-open")))
        .ghost()
        .xsmall()
        .icon(gpui_kit::component::Icon::new(chevron))
        .tooltip(title)
        .on_click(move |_, window, cx| {
            // The row under it would run it again.
            cx.stop_propagation();
            on_click(window, cx)
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::settings::CotypingBackend;
    use lokalbot_engine::ModelCheckResult;

    fn info(role: Role, state: ModelState, downloads: bool) -> ModelInfo {
        ModelInfo {
            role,
            name: String::new(),
            bytes: None,
            downloads,
            state,
        }
    }

    fn checks() -> ModelCheckStatus {
        ModelCheckStatus::default()
    }

    #[test]
    fn each_role_says_where_it_runs_and_what_it_weighs() {
        let settings = Settings::default();
        let rows = role_rows(
            &settings,
            &[
                info(Role::Transcribe, ModelState::Missing, true),
                info(Role::Think, ModelState::Ready, true),
                info(Role::Autocomplete, ModelState::Missing, true),
            ],
            &HashMap::new(),
            &checks(),
        );
        assert_eq!(rows.len(), 3);
        assert!(rows.iter().all(|row| row.place == Place::ThisPc));
        assert_eq!(rows[0].chip, Chip::NotDownloaded);
        assert_eq!(rows[0].chip_tone(), ChipTone::Attention);
        assert_eq!(rows[1].chip, Chip::Ready);
        assert!(rows[1].bytes.is_some());
        assert!(rows[1].place_text().starts_with("On this PC · "));
        // Autocomplete is off: its missing model is no warning.
        assert!(!rows[2].needed);
        assert_eq!(rows[2].chip_tone(), ChipTone::Quiet);
        assert_eq!(rows[0].job(), "Turns meeting audio and dictation into text");
    }

    #[test]
    fn a_server_is_online_once_approved_and_not_set_up_before() {
        let mut settings = Settings {
            summarizer_backend: SummarizerBackend::OpenAICompatible,
            openai_base_url: "https://ai.example.com/v1".into(),
            ..Settings::default()
        };
        assert_eq!(place(Role::Think, &settings), Place::NotSetUp);
        settings
            .approved_remote_inference_origins
            .push("https://ai.example.com".into());
        assert_eq!(
            place(Role::Think, &settings),
            Place::Online("ai.example.com".into())
        );
        let row = &role_rows(
            &settings,
            &[info(Role::Think, ModelState::Ready, false)],
            &HashMap::new(),
            &checks(),
        )[0];
        assert_eq!(row.place_text(), "Online · ai.example.com");
        assert_eq!(row.bytes, None);
        // A server on this computer's own address keeps everything here.
        settings.openai_base_url = "http://127.0.0.1:8080/v1".into();
        assert_eq!(place(Role::Think, &settings), Place::ThisPc);
        // Blocked: the chip says so, whatever the engine reports.
        settings.openai_base_url = "http://ai.example.com/v1".into();
        let row = &role_rows(
            &settings,
            &[info(Role::Think, ModelState::Ready, false)],
            &HashMap::new(),
            &checks(),
        )[0];
        assert_eq!(row.chip, Chip::NotSetUp);
        assert_eq!(row.place_text(), "Online");
    }

    #[test]
    fn autocomplete_on_a_server_names_its_host() {
        let mut settings = Settings {
            cotyping_backend: CotypingBackend::Server,
            cotyping_server_base_url: "https://complete.example.net/v1".into(),
            cotyping_server_model: "tiny".into(),
            ..Settings::default()
        };
        assert_eq!(place(Role::Autocomplete, &settings), Place::NotSetUp);
        settings
            .approved_remote_autocomplete_origins
            .push("https://complete.example.net".into());
        assert_eq!(
            place(Role::Autocomplete, &settings),
            Place::Online("complete.example.net".into())
        );
        // A set's size needs Autocomplete's model here.
        assert_eq!(preset_bytes(Preset::Balanced, &settings), None);
    }

    #[test]
    fn checks_and_downloads_show_on_the_chip() {
        let settings = Settings::default();
        let mut status = checks();
        status.results.push(ModelCheckResult {
            role: ModelRole::Think,
            checked_at: chrono::Local::now(),
            elapsed_seconds: 1.0,
            failure: Some("No answer".into()),
            identity: Vec::new(),
        });
        status.testing = Some(ModelRole::Transcribe);
        let mut downloads = HashMap::new();
        downloads.insert(
            settings.cotyping_built_in_model_id.clone(),
            DownloadProgress {
                done_bytes: 0,
                total_bytes: 0,
                error: Some("Disk full".into()),
            },
        );
        let rows = role_rows(
            &settings,
            &[
                info(Role::Transcribe, ModelState::Ready, true),
                info(Role::Think, ModelState::Ready, true),
                info(Role::Autocomplete, ModelState::Attention, true),
            ],
            &downloads,
            &status,
        );
        assert_eq!(rows[0].chip, Chip::Checking);
        assert_eq!(rows[1].chip, Chip::CheckFailed);
        assert_eq!(rows[1].problem.as_deref(), Some("No answer"));
        assert_eq!(rows[2].chip, Chip::Stopped);
        assert_eq!(rows[2].problem.as_deref(), Some("Disk full"));
        assert_eq!(Chip::Downloading(Some(0.456)).text(), "Downloading · 46%");
        assert_eq!(Chip::Downloading(None).text(), "Downloading…");
    }

    #[test]
    fn the_model_set_says_what_it_is_and_weighs() {
        let mut settings = Settings::default();
        Preset::Balanced.patch().apply(&mut settings);
        assert_eq!(model_set(&settings), Some(Preset::Balanced));
        let help = model_set_help(&settings);
        assert!(
            help.starts_with("Balanced local models for everyday work. "),
            "{help}"
        );
        assert!(help.ends_with(" in all."), "{help}");
        assert!(
            preset_menu_title(Preset::Lightweight, &settings).starts_with("Lightweight local · ")
        );
        settings.built_in_model_id = "not-a-preset-model".into();
        assert_eq!(model_set(&settings), None);
        assert!(model_set_help(&settings).starts_with("You picked your own models."));
    }

    #[test]
    fn more_rows_count_models_and_name_services_once() {
        assert_eq!(downloaded_summary(&[]), "None yet");
        assert_eq!(
            downloaded_summary(&[RUNTIME_ID.to_string(), "qwen3.5-4b".into()]),
            "1"
        );
        let mut settings = Settings::default();
        assert_eq!(online_summary(&settings), "None set up");
        settings.approved_remote_inference_origins = vec!["https://ai.example.com".into()];
        settings.approved_remote_transcription_origins = vec![
            "https://ai.example.com".into(),
            "https://audio.example.org".into(),
        ];
        assert_eq!(
            online_summary(&settings),
            "ai.example.com, audio.example.org"
        );
    }
}
