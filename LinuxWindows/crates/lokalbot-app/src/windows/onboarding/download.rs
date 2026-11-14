//! Setup, step 3 (`OnboardingDownloadStep.swift`): each model's job and size
//! and the free space before anything downloads, then progress per model
//! and overall, with the time left once the speed is known. Nothing
//! downloads until Download is pressed.

use std::collections::{HashMap, HashSet, VecDeque};
use std::time::Instant;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Div, FontWeight, IntoElement, ParentElement as _, SharedString,
    Styled as _, div, px,
};
use lokalbot_core::settings::{CotypingBackend, ModelDownloadSource, Settings, SummarizerBackend};

use super::{
    Onboarding, attention_label, card, done_label, heading, note, progress_bar, quiet, row,
    row_title,
};
use crate::pages::settings::model_options::download_source_row;
use crate::pages::settings::models::{
    RUNTIME_ID, autocomplete_needs, model_bytes, model_name, models_in_use, size_label,
    speech_needs,
};
use crate::state::{AppData, AppEvent, DownloadProgress};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};
use lokalbot_i18n::{interface_directional, mac};

/// Slack a download needs beyond its own size (`DiskSpacePrecheck.headroomBytes`).
const HEADROOM_BYTES: u64 = 2_000_000_000;

/// What the download step and its footer share while the window is open
/// (`OnboardingDownloadSession`).
pub(super) struct Session {
    pub include_autocomplete: bool,
    pub opens_sample_meeting: bool,
    /// Download was pressed in this window.
    started: bool,
    /// What was on this computer when the download began, so progress counts
    /// only what this download fetches.
    ready_before: Option<HashSet<String>>,
    /// Ids this window asked for, so each is asked for once until Retry.
    requested: HashSet<String>,
    estimator: Estimator,
    last_downloaded: Option<u64>,
}

impl Default for Session {
    fn default() -> Self {
        Self {
            include_autocomplete: false,
            opens_sample_meeting: true,
            started: false,
            ready_before: None,
            requested: HashSet::new(),
            estimator: Estimator::default(),
            last_downloaded: None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Role {
    Transcribe,
    Think,
    /// Port-only: search by meaning's embedding model (the Mac's is built in).
    Search,
    /// Port-only: screen text recognition, when the workday keeps text.
    ScreenText,
    Autocomplete,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) enum ModelState {
    NotStarted,
    /// How far, 0…1.
    Downloading(f32),
    Stopped(String),
    Ready,
    /// Nothing downloads for it here: a model server does the work.
    Elsewhere,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Model {
    pub role: Role,
    pub name: String,
    /// What downloads for it, with the llama.cpp runtime on the first role
    /// that needs it.
    pub ids: Vec<String>,
    pub state: ModelState,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Phase {
    /// Nothing has been asked for yet.
    Before,
    Running,
    /// At least one download failed; others may still be running.
    Stopped,
    /// Nothing is left to download.
    Finished,
}

/// What the plan reads.
pub(super) struct Inputs<'a> {
    pub settings: &'a Settings,
    pub installed: &'a [String],
    pub downloads: &'a HashMap<String, DownloadProgress>,
    /// What screen text recognition would download for the draft's choice.
    pub screen_text: Option<(String, u64)>,
    pub include_autocomplete: bool,
    pub started: bool,
    pub ready_before: Option<&'a HashSet<String>>,
    pub available_bytes: Option<u64>,
}

/// `OnboardingDownloadPlan`.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Plan {
    /// The rows, in order. Autocomplete is listed while it can still be
    /// chosen and once it is part of the download.
    pub models: Vec<Model>,
    selected: Vec<Role>,
    pub phase: Phase,
    /// A download is running now, also beside one that stopped.
    pub is_downloading: bool,
    /// Free space on the drive that holds the library.
    pub available_bytes: Option<u64>,
    /// Bytes of the selected models that were not here when the download
    /// began.
    pub total_bytes: u64,
    /// Of `total_bytes`, how much has arrived.
    pub downloaded_bytes: u64,
    /// What Download will fetch now.
    pub remaining_bytes: u64,
    bytes: HashMap<String, u64>,
}

impl Plan {
    pub(super) fn new(input: Inputs<'_>) -> Self {
        let settings = input.settings;
        let mut bytes: HashMap<String, u64> = HashMap::new();
        let mut size = |id: &str| {
            let value = match &input.screen_text {
                Some((screen, screen_bytes)) if screen == id => *screen_bytes,
                _ => model_bytes(id, settings),
            };
            bytes.insert(id.to_string(), value);
        };
        let installed = |id: &String| input.installed.contains(id);
        let state_of = |ids: &[String], sizes: &HashMap<String, u64>| -> ModelState {
            if ids.is_empty() {
                return ModelState::Elsewhere;
            }
            if ids.iter().all(installed) {
                return ModelState::Ready;
            }
            if let Some(error) = ids.iter().find_map(|id| {
                input
                    .downloads
                    .get(id)
                    .and_then(|d| d.error.as_ref().map(|e| e.to_string()))
            }) {
                return ModelState::Stopped(error);
            }
            if ids.iter().any(|id| input.downloads.contains_key(id)) {
                let total: u64 = ids
                    .iter()
                    .map(|id| sizes.get(id).copied().unwrap_or(0))
                    .sum();
                let arrived: f64 =
                    ids.iter()
                        .map(|id| {
                            let bytes = sizes.get(id).copied().unwrap_or(0) as f64;
                            if installed(id) {
                                bytes
                            } else {
                                input.downloads.get(id).map_or(0.0, |d| {
                                    bytes * f64::from(d.fraction().clamp(0.0, 1.0))
                                })
                            }
                        })
                        .sum();
                let fraction = if total == 0 {
                    0.0
                } else {
                    (arrived / total as f64) as f32
                };
                return ModelState::Downloading(fraction.clamp(0.0, 1.0));
            }
            ModelState::NotStarted
        };

        let built_in_think = settings.summarizer_backend == SummarizerBackend::BuiltIn;
        let mut roles: Vec<(Role, String, Vec<String>)> = vec![
            (
                Role::Transcribe,
                model_name(&settings.transcription_model),
                speech_needs(settings),
            ),
            (
                Role::Think,
                if built_in_think {
                    model_name(&settings.built_in_model_id)
                } else {
                    lokalbot_i18n::tr("Your model server").to_string()
                },
                if built_in_think {
                    vec![settings.built_in_model_id.clone()]
                } else {
                    Vec::new()
                },
            ),
        ];
        if settings.semantic_search_enabled {
            let id = lokalbot_ai::catalog::EMBEDDING_MODEL_ID.to_string();
            roles.push((Role::Search, model_name(&id), vec![id]));
        }
        if let Some((id, _)) = &input.screen_text {
            roles.push((Role::ScreenText, model_name(id), vec![id.clone()]));
        }
        let autocomplete_downloads = settings.cotyping_backend == CotypingBackend::OnDevice;
        let autocomplete_id = settings.cotyping_built_in_model_id.clone();
        let autocomplete_chosen = autocomplete_downloads
            && (input.include_autocomplete
                || installed(&autocomplete_id)
                || input.downloads.contains_key(&autocomplete_id));
        if autocomplete_downloads && (autocomplete_chosen || !input.started) {
            roles.push((
                Role::Autocomplete,
                model_name(&autocomplete_id),
                vec![autocomplete_id],
            ));
        }
        let mut selected: Vec<Role> = roles
            .iter()
            .map(|(role, ..)| *role)
            .filter(|role| *role != Role::Autocomplete)
            .collect();
        if autocomplete_chosen {
            selected.push(Role::Autocomplete);
        }
        // The runtime downloads with the first selected role that runs on it.
        if let Some((_, _, ids)) = roles.iter_mut().find(|(role, _, ids)| {
            !ids.is_empty()
                && selected.contains(role)
                && matches!(role, Role::Think | Role::Search | Role::Autocomplete)
        }) {
            ids.push(RUNTIME_ID.to_string());
        }
        for (_, _, ids) in &roles {
            for id in ids {
                size(id);
            }
        }
        let models: Vec<Model> = roles
            .into_iter()
            .map(|(role, name, ids)| {
                let state = state_of(&ids, &bytes);
                Model {
                    role,
                    name,
                    ids,
                    state,
                }
            })
            .collect();

        let chosen: Vec<&Model> = models
            .iter()
            .filter(|m| selected.contains(&m.role))
            .collect();
        let chosen_ids: Vec<&String> = {
            let mut seen = HashSet::new();
            chosen
                .iter()
                .flat_map(|m| m.ids.iter())
                .filter(|id| seen.insert(id.as_str()))
                .collect()
        };
        let byte = |id: &String| bytes.get(id).copied().unwrap_or(0);
        let remaining_bytes = chosen_ids
            .iter()
            .filter(|id| !installed(id))
            .map(|id| byte(id))
            .sum();
        let pending: Vec<&&String> = chosen_ids
            .iter()
            .filter(|id| match input.ready_before {
                Some(before) => !before.contains(id.as_str()),
                None => !installed(id),
            })
            .collect();
        let total_bytes = pending.iter().map(|id| byte(id)).sum();
        let downloaded_bytes = pending
            .iter()
            .map(|id| {
                let size = byte(id) as f64;
                if installed(id) {
                    size
                } else {
                    match input.downloads.get(id.as_str()) {
                        Some(d) if d.error.is_none() => {
                            size * f64::from(d.fraction().clamp(0.0, 1.0))
                        }
                        _ => 0.0,
                    }
                }
            })
            .sum::<f64>() as u64;

        let is_downloading = chosen
            .iter()
            .any(|m| matches!(m.state, ModelState::Downloading(_)));
        let waiting = chosen.iter().any(|m| m.state == ModelState::NotStarted);
        let phase = if chosen
            .iter()
            .any(|m| matches!(m.state, ModelState::Stopped(_)))
        {
            Phase::Stopped
        } else if is_downloading {
            Phase::Running
        } else if waiting {
            // Between the button and the first progress there is no state yet.
            if input.started {
                Phase::Running
            } else {
                Phase::Before
            }
        } else {
            Phase::Finished
        };
        Self {
            models,
            selected,
            phase,
            is_downloading,
            available_bytes: input.available_bytes,
            total_bytes,
            downloaded_bytes,
            remaining_bytes,
            bytes,
        }
    }

    fn chosen(&self) -> impl Iterator<Item = &Model> {
        self.models
            .iter()
            .filter(|m| self.selected.contains(&m.role))
    }

    /// Every selected model can be used now.
    pub(super) fn all_ready(&self) -> bool {
        self.chosen()
            .all(|m| matches!(m.state, ModelState::Ready | ModelState::Elsewhere))
    }

    /// 0…1 across the whole download.
    pub(super) fn fraction(&self) -> Option<f32> {
        (self.total_bytes > 0).then(|| {
            (self.downloaded_bytes as f64 / self.total_bytes as f64).clamp(0.0, 1.0) as f32
        })
    }

    /// Whether the download and the headroom it needs fit in the free space.
    /// True when the free space is unknown.
    pub(super) fn fits_on_disk(&self) -> bool {
        match self.available_bytes {
            Some(available) if self.remaining_bytes > 0 => {
                available >= self.remaining_bytes.saturating_add(HEADROOM_BYTES)
            }
            _ => true,
        }
    }

    fn stopped(&self) -> Vec<&Model> {
        self.chosen()
            .filter(|m| matches!(m.state, ModelState::Stopped(_)))
            .collect()
    }

    /// What the row weighs: its ids still to come, or all of them once here.
    fn row_bytes(&self, model: &Model, installed: &[String]) -> u64 {
        let missing: u64 = model
            .ids
            .iter()
            .filter(|id| !installed.contains(id))
            .map(|id| self.bytes.get(id).copied().unwrap_or(0))
            .sum();
        if missing > 0 {
            missing
        } else {
            model
                .ids
                .iter()
                .map(|id| self.bytes.get(id).copied().unwrap_or(0))
                .sum()
        }
    }
}

/// Time left for a download, from how fast the bytes arrived over the last
/// half minute. It says nothing until it has watched for a few seconds, and
/// nothing while no bytes arrive (`DownloadTimeEstimator`).
#[derive(Default)]
pub(super) struct Estimator {
    samples: VecDeque<(Instant, u64)>,
}

impl Estimator {
    const WINDOW_SECS: f64 = 30.;
    const MINIMUM_SPAN_SECS: f64 = 5.;

    pub(super) fn record(&mut self, downloaded: u64, at: Instant) {
        // A retried download starts over, so earlier speeds no longer apply.
        if let Some((last_at, last)) = self.samples.back()
            && (downloaded < *last || at < *last_at)
        {
            self.samples.clear();
        }
        self.samples.push_back((at, downloaded));
        while let Some((first_at, _)) = self.samples.front() {
            if at.duration_since(*first_at).as_secs_f64() > Self::WINDOW_SECS {
                self.samples.pop_front();
            } else {
                break;
            }
        }
    }

    pub(super) fn reset(&mut self) {
        self.samples.clear();
    }

    fn seconds_left(&self, total: u64) -> Option<f64> {
        let (first_at, first) = self.samples.front()?;
        let (last_at, last) = self.samples.back()?;
        let span = last_at.duration_since(*first_at).as_secs_f64();
        let arrived = last.checked_sub(*first)?;
        if span < Self::MINIMUM_SPAN_SECS || arrived == 0 || total <= *last {
            return None;
        }
        Some((total - last) as f64 / (arrived as f64 / span))
    }

    /// Whole minutes, never less than one.
    pub(super) fn minutes_left(&self, total: u64) -> Option<u64> {
        self.seconds_left(total)
            .map(|seconds| ((seconds / 60.).round() as u64).max(1))
    }
}

impl Onboarding {
    pub(super) fn plan(&mut self, cx: &App) -> Plan {
        let data = self.data.read(cx);
        let screen_text = self
            .draft
            .reads_screen_text()
            .then_some(data.models.screen_text.download)
            .flatten()
            .map(|d| (d.id.to_string(), d.bytes));
        let plan = Plan::new(Inputs {
            settings: &data.settings,
            installed: &data.models.installed,
            downloads: &data.downloads,
            screen_text,
            include_autocomplete: self.download.include_autocomplete,
            started: self.download.started,
            ready_before: self.download.ready_before.as_ref(),
            available_bytes: lokalbot_ai::download::free_space(data.library.paths().root()),
        });
        // A download that began outside this window (before a relaunch, or
        // from Settings) counts what is missing from when it is first seen.
        if plan.phase != Phase::Before && self.download.ready_before.is_none() {
            self.download.ready_before = Some(data.models.installed.iter().cloned().collect());
        }
        plan
    }

    /// Feeds the time-left estimate as bytes arrive.
    pub(super) fn download_changed(&mut self, cx: &App) {
        if self.step != super::Step::Download {
            return;
        }
        let plan = self.plan(cx);
        let downloaded = (plan.phase == Phase::Running).then_some(plan.downloaded_bytes);
        if downloaded != self.download.last_downloaded {
            self.download.last_downloaded = downloaded;
            match downloaded {
                Some(bytes) => self.download.estimator.record(bytes, Instant::now()),
                None => self.download.estimator.reset(),
            }
        }
    }

    /// Asks for every selected model this computer lacks that this window
    /// hasn't asked for yet. The meeting models go through `PrepareModels`,
    /// which fetches them one at a time.
    fn start_download(&mut self, cx: &mut Context<Self>) {
        if !self.download.started {
            let installed = self
                .data
                .read(cx)
                .models
                .installed
                .iter()
                .cloned()
                .collect();
            self.download.ready_before = Some(installed);
            self.download.started = true;
        }
        let (meeting, extra) = {
            let data = self.data.read(cx);
            let screen_text = self
                .draft
                .reads_screen_text()
                .then_some(data.models.screen_text.download)
                .flatten()
                .map(|d| d.id);
            let needs = setup_downloads(
                &data.settings,
                screen_text,
                self.download.include_autocomplete,
            );
            let missing = |ids: Vec<String>| -> Vec<String> {
                ids.into_iter()
                    .filter(|id| !data.models.installed.contains(id))
                    .filter(|id| !data.downloads.get(id).is_some_and(|d| d.error.is_none()))
                    .filter(|id| !self.download.requested.contains(id))
                    .collect()
            };
            (missing(needs.meeting), missing(needs.extra))
        };
        self.data.update(cx, |data, cx| {
            if !meeting.is_empty() {
                data.request(AppEvent::PrepareModels, cx);
            }
            for id in &extra {
                data.request(AppEvent::DownloadModel(id.clone()), cx);
            }
        });
        self.download.requested.extend(meeting);
        self.download.requested.extend(extra);
        cx.notify();
    }

    /// Retry asks again for what stopped.
    fn retry(&mut self, cx: &mut Context<Self>) {
        self.download.requested.clear();
        self.start_download(cx);
    }

    pub(super) fn render_download(&self, plan: &Plan, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let (settings, installed) = {
            let data = self.data.read(cx);
            (data.settings.clone(), data.models.installed.clone())
        };
        // The microphone row's own state: allowed, or a microphone found.
        let microphone_allowed = self
            .access_rows(cx)
            .first()
            .is_some_and(|row| row.state == super::access::RowState::Allowed);
        let built_in = settings.summarizer_backend == SummarizerBackend::BuiltIn;

        let heading = match plan.phase {
            Phase::Before => heading(
                lokalbot_i18n::tr("Download the models"),
                Some(
                    lokalbot_i18n::tr(
                        "LokalBot transcribes, writes notes and answers questions on this PC, so it needs the models below. They download once, then work offline.",
                    )
                    .to_string(),
                ),
                cx,
            ),
            Phase::Running | Phase::Stopped => heading(
                lokalbot_i18n::tr("Downloading the models"),
                Some(
                    lokalbot_i18n::tr("You can start now. The download keeps going in the background.")
                        .to_string(),
                ),
                cx,
            ),
            Phase::Finished if plan.all_ready() => heading(
                lokalbot_i18n::tr("You’re ready"),
                built_in.then(|| {
                    lokalbot_i18n::tr(
                        "The models are on this PC, so notes and answers work offline too.",
                    )
                    .to_string()
                }),
                cx,
            ),
            Phase::Finished => heading(lokalbot_i18n::tr("Prepare Your Workflows"), None, cx),
        };

        let mut list = card(cx);
        if plan.phase != Phase::Before && !(plan.phase == Phase::Finished && !plan.all_ready()) {
            list = list.child(self.hero(plan, cx)).child(ui::divider(cx));
        }
        for (index, model) in plan.models.iter().enumerate() {
            if index > 0 {
                list = list.child(ui::divider(cx));
            }
            list = list.child(self.model_row(plan, model, &installed, cx));
        }

        let shows_autocomplete = self.download.include_autocomplete
            && plan.models.iter().any(|m| m.role == Role::Autocomplete);
        let inference = (!built_in).then(|| {
            note(
                if settings.think_is_local() {
                    Ico::ShieldCheck
                } else {
                    Ico::Network
                },
                if settings.think_is_local() {
                    lokalbot_i18n::tr("The configured Think model processes selected context on this PC.")
                } else {
                    lokalbot_i18n::tr(
                        "Selected transcript and work context is sent to the approved model server.",
                    )
                },
                cx,
            )
        });

        v_flex()
            .w_full()
            .gap(px(16.))
            .child(heading)
            .child(list)
            .when(shows_autocomplete, |this| {
                this.child(div().px(px(2.)).child(quiet(autocomplete_disclosure(), cx)))
            })
            .children(inference)
            .map(|this| {
                if plan.phase == Phase::Before {
                    this.child(self.before_notes(plan, &settings, cx))
                } else {
                    this.child(self.after_options(plan, microphone_allowed, cx))
                }
            })
            .text_color(lb.text)
    }

    /// The overall line: time left or the outcome, the amount, and the bar.
    fn hero(&self, plan: &Plan, cx: &App) -> Div {
        let lb = cx.lb();
        let title: AnyElement =
            match plan.phase {
                Phase::Stopped => h_flex()
                    .gap(px(6.))
                    .items_center()
                    .child(ui::icon(Ico::TriangleAlert, px(15.), lb.attention_text))
                    .child(div().text_color(lb.attention_text).child(
                        if plan.stopped().len() == 1 {
                            lokalbot_i18n::tr("One download stopped")
                        } else {
                            lokalbot_i18n::tr("Downloads stopped")
                        },
                    ))
                    .into_any_element(),
                Phase::Finished => h_flex()
                    .gap(px(6.))
                    .items_center()
                    .child(ui::icon(Ico::Check, px(15.), lb.success_text))
                    .child(
                        div()
                            .text_color(lb.success_text)
                            .child(lokalbot_i18n::tr("Your models are ready")),
                    )
                    .into_any_element(),
                Phase::Before | Phase::Running => {
                    let text = match self.download.estimator.minutes_left(plan.total_bytes) {
                        Some(1) => lokalbot_i18n::tr("About 1 minute left").to_string(),
                        Some(minutes) => mac(
                            "About %lld minutes left",
                            &[&lokalbot_i18n::number(minutes as usize)],
                        ),
                        None => lokalbot_i18n::tr("Downloading…").to_string(),
                    };
                    div().child(interface_directional(&text)).into_any_element()
                }
            };
        let amount = (plan.total_bytes > 0).then(|| {
            if plan.phase == Phase::Finished {
                mac("%@ downloaded", &[&size_label(plan.total_bytes)])
            } else {
                // Sizes carry their unit, so the pair reads the same in every language.
                format!(
                    "{} / {}",
                    size_label(plan.downloaded_bytes),
                    size_label(plan.total_bytes)
                )
            }
        });
        let fraction = if plan.phase == Phase::Finished {
            Some(1.0)
        } else {
            plan.fraction()
        };
        let stopped_message = (plan.phase == Phase::Stopped)
            .then(|| {
                plan.stopped().into_iter().find_map(|m| match &m.state {
                    ModelState::Stopped(message) => Some(message.clone()),
                    _ => None,
                })
            })
            .flatten();
        v_flex()
            .w_full()
            .px(px(16.))
            .py(px(13.))
            .gap(px(8.))
            .child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(px(16.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(title),
                    )
                    .children(amount.map(|amount| {
                        div()
                            .flex_none()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(interface_directional(&amount))
                    })),
            )
            .children(fraction.map(|fraction| progress_bar(fraction, cx)))
            .children(stopped_message.map(|message| quiet(message, cx)))
    }

    fn model_row(
        &self,
        plan: &Plan,
        model: &Model,
        installed: &[String],
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let (symbol, title, job): (Ico, &'static str, Option<&'static str>) = match model.role {
            Role::Transcribe => (
                Ico::AudioLines,
                lokalbot_i18n::tr("Transcription"),
                Some(lokalbot_i18n::tr("Turns speech into text")),
            ),
            Role::Think => (
                Ico::FileText,
                lokalbot_i18n::tr("Notes and answers"),
                Some(lokalbot_i18n::tr("Writes notes and answers questions")),
            ),
            Role::Search => (Ico::Search, lokalbot_i18n::tr("Search by meaning"), None),
            Role::ScreenText => (
                Ico::ScanText,
                lokalbot_i18n::tr("Screen text"),
                Some(lokalbot_i18n::tr("Reads screen text")),
            ),
            Role::Autocomplete => (
                Ico::Keyboard,
                lokalbot_i18n::tr("Autocomplete"),
                Some(lokalbot_i18n::tr("Suggests text as you type in other apps")),
            ),
        };
        let line = match job {
            Some(job) => format!("{job} · {}", model.name),
            None => model.name.clone(),
        };
        let detail = v_flex()
            .gap(px(2.))
            .child(row_title(
                title,
                (model.role == Role::Autocomplete).then(|| lokalbot_i18n::tr("Optional")),
                cx,
            ))
            .child(quiet(line, cx));
        let trailing: Option<AnyElement> = match &model.state {
            ModelState::Ready => Some(done_label(lokalbot_i18n::tr("Ready"), cx)),
            ModelState::Elsewhere => None,
            ModelState::Downloading(fraction) => Some(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(div().w(px(84.)).child(progress_bar(*fraction, cx)))
                    .child(
                        div()
                            .min_w(px(34.))
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(format!("{}%", (fraction * 100.).round() as u32)),
                    )
                    .into_any_element(),
            ),
            ModelState::Stopped(_) => Some(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(attention_label(lokalbot_i18n::tr("Stopped"), cx))
                    .child(
                        Button::new(SharedString::from(format!(
                            "onboarding-retry-{:?}",
                            model.role
                        )))
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Retry"))
                        .on_click(cx.listener(|this, _, _, cx| this.retry(cx))),
                    )
                    .into_any_element(),
            ),
            ModelState::NotStarted => {
                let size = plan.row_bytes(model, installed);
                let offers_switch = model.role == Role::Autocomplete && plan.phase == Phase::Before;
                Some(
                    h_flex()
                        .gap(px(10.))
                        .items_center()
                        .when(size > 0, |this| {
                            this.child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(size_label(size)),
                            )
                        })
                        .when(offers_switch, |this| {
                            this.child(
                                Switch::new("onboarding-include-autocomplete")
                                    .checked(self.download.include_autocomplete)
                                    .on_click(cx.listener(|this, on: &bool, _, cx| {
                                        this.download.include_autocomplete = *on;
                                        this.save(cx);
                                        cx.notify();
                                    })),
                            )
                        })
                        .into_any_element(),
                )
            }
        };
        row(symbol, false, detail, trailing, cx)
    }

    /// Before the download: the total and the free space, then what to expect.
    fn before_notes(&self, plan: &Plan, settings: &Settings, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let total = (plan.remaining_bytes > 0).then(|| size_label(plan.remaining_bytes));
        let free = plan.available_bytes.map(size_label);
        let fits = plan.fits_on_disk();
        let tone = if fits { lb.text } else { lb.attention_text };
        let size_note = (total.is_some() || free.is_some()).then(|| {
            h_flex()
                .px(px(2.))
                .gap(px(6.))
                .items_center()
                .flex_wrap()
                .child(ui::icon(
                    if fits {
                        Ico::ArrowDownToLine
                    } else {
                        Ico::TriangleAlert
                    },
                    px(13.),
                    tone,
                ))
                .when_some(total.clone(), |this, total| {
                    this.child(
                        div()
                            .text_size(ty::SECONDARY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tone)
                            .child(interface_directional(&mac("%@ in all", &[&total]))),
                    )
                })
                .when(total.is_some() && free.is_some(), |this| {
                    this.child(div().text_size(ty::SECONDARY).text_color(tone).child("·"))
                })
                .when_some(free, |this, free| {
                    this.child(div().text_size(ty::SECONDARY).text_color(tone).child(
                        interface_directional(&lokalbot_i18n::format(
                            "{size} free on this PC",
                            &[("size", free)],
                        )),
                    ))
                })
        });
        let source_page = cx.entity();
        let source = shows_download_source(settings).then(|| {
            div().pt(px(6.)).child(download_source_row(
                settings.model_download_source,
                false,
                move |source, _, cx| {
                    source_page.update(cx, |this, cx| {
                        // Only where to download from: Download still starts it.
                        this.data.update(cx, |data, cx| {
                            data.update_settings(|s| s.model_download_source = source, cx)
                        });
                    })
                },
                cx,
            ))
        });
        v_flex()
            .w_full()
            .gap(px(6.))
            .children(size_note)
            .child(note(
                Ico::Clock,
                lokalbot_i18n::tr("You can use LokalBot while it downloads."),
                cx,
            ))
            .child(note(
                Ico::Lock,
                lokalbot_i18n::tr(
                    "Downloads use the model provider. They do not send your meeting content. Existing downloaded models are kept.",
                ),
                cx,
            ))
            .children(source)
    }

    /// While it downloads, and after: the sample meeting, and that recording
    /// already works.
    fn after_options(&self, plan: &Plan, microphone_allowed: bool, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let waiting = plan.phase != Phase::Finished;
        let sample = h_flex()
            .w_full()
            .px(px(14.))
            .py(px(11.))
            .gap(px(10.))
            .items_start()
            .child(
                div().pt(px(2.)).child(
                    Checkbox::new("onboarding-open-sample")
                        .checked(self.download.opens_sample_meeting)
                        .on_click(cx.listener(|this, on: &bool, _, cx| {
                            this.download.opens_sample_meeting = *on;
                            this.save(cx);
                            cx.notify();
                        })),
                ),
            )
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(ui::text::paragraph(lokalbot_i18n::tr(if waiting {
                                "Open a sample meeting when the models are ready"
                            } else {
                                "Open the sample meeting first"
                            }))),
                    )
                    .child(quiet(
                        lokalbot_i18n::tr(
                            "A made-up three-and-a-half-minute call. Read its notes and ask it a question before your first real meeting.",
                        ),
                        cx,
                    )),
            );
        let recording = (waiting && microphone_allowed).then(|| {
            h_flex()
                .w_full()
                .px(px(14.))
                .py(px(11.))
                .gap(px(10.))
                .items_start()
                .child(
                    div()
                        .pt(px(2.))
                        .w(px(16.))
                        .child(ui::icon(Ico::Mic, px(15.), lb.accent_text)),
                )
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text)
                                .child(lokalbot_i18n::tr("Recording already works")),
                        )
                        .child(quiet(
                            lokalbot_i18n::tr(
                                "A meeting you record now gets its notes as soon as the download finishes.",
                            ),
                            cx,
                        )),
                )
        });
        v_flex()
            .w_full()
            .gap(px(10.))
            .when(waiting, |this| {
                this.child(
                    div()
                        .px(px(2.))
                        .text_size(ty::SECTION)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(lokalbot_i18n::tr("While you wait")),
                )
            })
            .child(
                card(cx)
                    .child(sample)
                    .when_some(recording, |this, recording| {
                        this.child(ui::divider(cx)).child(recording)
                    }),
            )
    }

    /// Skip and "Download 5.9 GB" before anything downloads, then the way
    /// into the app while it runs (`OnboardingDownloadFooterContent`).
    pub(super) fn download_footer(
        &self,
        footer: Div,
        back: Button,
        plan: &Plan,
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let opens_sample = self.download.opens_sample_meeting;
        let footer = match plan.phase {
            Phase::Before => footer.child(ui::section_panel::panel_link(
                "onboarding-skip-download",
                lokalbot_i18n::tr("Skip for now"),
                {
                    let page = cx.entity();
                    move |window, cx| page.update(cx, |this, cx| this.finish(false, window, cx))
                },
                cx,
            )),
            Phase::Running | Phase::Stopped => footer.child(
                div()
                    .flex_1()
                    .min_w_0()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(ui::text::paragraph(lokalbot_i18n::tr(
                        "Closing this window doesn’t stop the download.",
                    ))),
            ),
            Phase::Finished => footer,
        };
        // The note while it downloads takes the free width itself.
        let footer = footer
            .when(
                !matches!(plan.phase, Phase::Running | Phase::Stopped),
                |this| this.child(div().flex_1().min_w(px(8.))),
            )
            .child(back);
        if plan.phase == Phase::Before {
            let label = if plan.remaining_bytes > 0 {
                mac("Download %@", &[&size_label(plan.remaining_bytes)])
            } else {
                lokalbot_i18n::tr("Download").to_string()
            };
            footer.child(
                Button::new("onboarding-download-models")
                    .primary()
                    .label(label)
                    .on_click(cx.listener(|this, _, _, cx| this.start_download(cx))),
            )
        } else {
            footer.child(
                Button::new("onboarding-finish")
                    .primary()
                    .label(lokalbot_i18n::tr("Start using LokalBot"))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.finish(opens_sample, window, cx)
                    })),
            )
        }
    }
}

/// Opens the sample meeting now when its models are here, or once they land
/// (`openSampleMeetingWhenReady`). Nothing more downloads for it: setup's
/// download already asked for its models.
pub(super) fn open_sample_when_ready(data: &mut AppData, cx: &mut Context<AppData>) {
    data.try_sample(cx);
    match &mut data.sample_setup {
        // Waiting for its models: continue on its own once they land.
        Some(setup) if !setup.importing => {
            setup.downloading = true;
            cx.notify();
        }
        // Opened or being added: show it.
        _ => crate::desktop::show_main_window(cx),
    }
}

/// huggingface.co is blocked in mainland China, so the first download offers
/// HF-Mirror and ModelScope there: on a computer set to that region or to
/// Simplified Chinese, or once a mirror is already chosen. Settings → Models
/// always has the same picker.
fn shows_download_source(settings: &Settings) -> bool {
    settings.model_download_source != ModelDownloadSource::HuggingFace || in_mainland_china()
}

/// The interface is in Simplified Chinese, or the system prefers a
/// mainland-China locale.
fn in_mainland_china() -> bool {
    lokalbot_i18n::current().code == "zh-Hans"
        || lokalbot_i18n::system_preferences()
            .first()
            .is_some_and(|preference| is_mainland_china_locale(preference))
}

/// `zh-Hans`, `zh_CN.UTF-8`, `en-CN`: Simplified Chinese or the CN region.
fn is_mainland_china_locale(preference: &str) -> bool {
    let code = preference.split('.').next().unwrap_or(preference);
    let code = code.replace('_', "-").to_lowercase();
    code.starts_with("zh-hans") || code.split('-').skip(1).any(|part| part == "cn")
}

/// What setup downloads for the choices on screen.
#[derive(Debug, PartialEq)]
struct SetupDownloads {
    /// What the engine's `PrepareModels` fetches, one at a time: Transcribe
    /// with voice detection and speaker separation, Think, search by meaning
    /// and the llama.cpp runtime.
    meeting: Vec<String>,
    /// The rest, each asked for on its own: what the chosen screen text
    /// needs, and Autocomplete's model when asked for.
    extra: Vec<String>,
}

/// `screen_text` is the download the draft's screen context would need.
fn setup_downloads(
    settings: &Settings,
    screen_text: Option<&str>,
    include_autocomplete: bool,
) -> SetupDownloads {
    // `PrepareModels` leaves Autocomplete to its own switch, and screen text
    // to what the settings, not the draft, chose.
    let meeting_settings = Settings {
        cotyping_enabled: false,
        ..settings.clone()
    };
    let mut meeting = models_in_use(&meeting_settings);
    meeting.retain(|id| {
        id != lokalbot_ai::ocr::OCR_MODEL_ID && id != lokalbot_ai::ocr::OCR_LANGUAGES_ID
    });
    let mut extra: Vec<String> = screen_text.map(str::to_string).into_iter().collect();
    if include_autocomplete {
        extra.extend(autocomplete_needs(settings));
    }
    let mut seen = HashSet::new();
    extra.retain(|id| !meeting.contains(id) && seen.insert(id.clone()));
    SetupDownloads { meeting, extra }
}

/// What preparing Autocomplete means for what it reads (`OnboardingView`).
fn autocomplete_disclosure() -> &'static str {
    lokalbot_i18n::tr(
        "Autocomplete also reads the window you are typing in, such as the conversation you are answering, to fit its suggestions: the text just above the field, and, once its text recognition model is downloaded, the whole window with on-device text recognition. It stays on this PC and is never saved; turn either off in Settings → Autocomplete.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::ScreenContextMode;

    fn progress(done: u64, total: u64) -> DownloadProgress {
        DownloadProgress {
            done_bytes: done,
            total_bytes: total,
            error: None,
        }
    }

    fn plan(
        settings: &Settings,
        installed: &[String],
        downloads: &HashMap<String, DownloadProgress>,
        include_autocomplete: bool,
        started: bool,
        ready_before: Option<&HashSet<String>>,
    ) -> Plan {
        Plan::new(Inputs {
            settings,
            installed,
            downloads,
            screen_text: None,
            include_autocomplete,
            started,
            ready_before,
            available_bytes: Some(100_000_000_000),
        })
    }

    fn meeting_ids(settings: &Settings) -> Vec<String> {
        setup_downloads(settings, None, false).meeting
    }

    #[test]
    fn nothing_is_asked_for_before_download_and_sizes_show_first() {
        let settings = Settings::default();
        let plan = plan(&settings, &[], &HashMap::new(), false, false, None);
        assert_eq!(plan.phase, Phase::Before);
        let roles: Vec<Role> = plan.models.iter().map(|m| m.role).collect();
        assert_eq!(roles.first(), Some(&Role::Transcribe));
        assert_eq!(roles.get(1), Some(&Role::Think));
        // Autocomplete is offered, unselected, while nothing has started.
        assert_eq!(roles.last(), Some(&Role::Autocomplete));
        let expected: u64 = meeting_ids(&settings)
            .iter()
            .map(|id| model_bytes(id, &settings))
            .sum();
        assert_eq!(plan.remaining_bytes, expected);
        assert!(
            plan.models
                .iter()
                .all(|m| m.state == ModelState::NotStarted)
        );
        // The runtime downloads with Think, once.
        let think = &plan.models[1];
        assert!(think.ids.contains(&RUNTIME_ID.to_string()));
        assert_eq!(
            plan.models
                .iter()
                .filter(|m| m.ids.contains(&RUNTIME_ID.to_string()))
                .count(),
            1
        );
    }

    #[test]
    fn autocomplete_counts_only_once_chosen() {
        let settings = Settings::default();
        let without = plan(&settings, &[], &HashMap::new(), false, false, None);
        let with = plan(&settings, &[], &HashMap::new(), true, false, None);
        let autocomplete = model_bytes(&settings.cotyping_built_in_model_id, &settings);
        assert_eq!(with.remaining_bytes, without.remaining_bytes + autocomplete);
        // Once the download is under way the unchosen option goes away.
        let started = plan(&settings, &[], &HashMap::new(), false, true, None);
        assert!(started.models.iter().all(|m| m.role != Role::Autocomplete));
        assert_eq!(started.phase, Phase::Running);
    }

    #[test]
    fn progress_counts_only_what_this_download_fetches() {
        let settings = Settings::default();
        let ids = meeting_ids(&settings);
        // The first piece was here already; the second is half way.
        let before: HashSet<String> = [ids[0].clone()].into_iter().collect();
        let installed = vec![ids[0].clone()];
        let half = model_bytes(&ids[1], &settings);
        let mut downloads = HashMap::new();
        downloads.insert(ids[1].clone(), progress(half / 2, half));
        let plan = plan(
            &settings,
            &installed,
            &downloads,
            false,
            true,
            Some(&before),
        );
        assert_eq!(plan.phase, Phase::Running);
        assert!(plan.is_downloading);
        let pending: u64 = ids[1..].iter().map(|id| model_bytes(id, &settings)).sum();
        assert_eq!(plan.total_bytes, pending);
        assert!(plan.downloaded_bytes.abs_diff(half / 2) <= 1);
    }

    #[test]
    fn a_failed_download_stops_the_plan_and_names_why() {
        let settings = Settings::default();
        let ids = meeting_ids(&settings);
        let mut downloads = HashMap::new();
        downloads.insert(
            ids[0].clone(),
            DownloadProgress {
                done_bytes: 0,
                total_bytes: 10,
                error: Some("connection reset".into()),
            },
        );
        let plan = plan(&settings, &[], &downloads, false, true, None);
        assert_eq!(plan.phase, Phase::Stopped);
        assert_eq!(plan.stopped().len(), 1);
        assert_eq!(
            plan.models[0].state,
            ModelState::Stopped("connection reset".into())
        );
    }

    #[test]
    fn everything_here_finishes_and_is_ready() {
        let settings = Settings::default();
        let installed = meeting_ids(&settings);
        let plan = plan(&settings, &installed, &HashMap::new(), false, false, None);
        assert_eq!(plan.phase, Phase::Finished);
        assert!(plan.all_ready());
        assert_eq!(plan.remaining_bytes, 0);
    }

    #[test]
    fn a_model_server_downloads_nothing_for_think() {
        let settings = Settings {
            summarizer_backend: SummarizerBackend::Ollama,
            semantic_search_enabled: false,
            ..Settings::default()
        };
        let plan = plan(&settings, &[], &HashMap::new(), false, false, None);
        let think = plan.models.iter().find(|m| m.role == Role::Think).unwrap();
        assert_eq!(think.state, ModelState::Elsewhere);
        assert!(!plan.models.iter().any(|m| m.role == Role::Search));
        // No role on this computer runs on llama.cpp, so it isn't fetched.
        assert!(
            !plan
                .models
                .iter()
                .any(|m| m.ids.contains(&RUNTIME_ID.to_string()))
        );
    }

    #[test]
    fn screen_text_joins_the_list_when_the_workday_keeps_text() {
        let settings = Settings::default();
        let plan = Plan::new(Inputs {
            settings: &settings,
            installed: &[],
            downloads: &HashMap::new(),
            screen_text: Some((lokalbot_ai::ocr::OCR_LANGUAGES_ID.to_string(), 30_000_000)),
            include_autocomplete: false,
            started: false,
            ready_before: None,
            available_bytes: None,
        });
        let screen = plan
            .models
            .iter()
            .find(|m| m.role == Role::ScreenText)
            .unwrap();
        assert_eq!(screen.ids, [lokalbot_ai::ocr::OCR_LANGUAGES_ID]);
        assert!(plan.fits_on_disk(), "unknown free space never warns");
    }

    #[test]
    fn the_download_must_fit_with_headroom() {
        let settings = Settings::default();
        let mut plan = plan(&settings, &[], &HashMap::new(), false, false, None);
        plan.available_bytes = Some(plan.remaining_bytes + HEADROOM_BYTES);
        assert!(plan.fits_on_disk());
        plan.available_bytes = Some(plan.remaining_bytes + HEADROOM_BYTES - 1);
        assert!(!plan.fits_on_disk());
    }

    #[test]
    fn time_left_waits_for_a_steady_speed() {
        let start = Instant::now();
        let mut estimator = Estimator::default();
        estimator.record(0, start);
        estimator.record(10_000_000, start + std::time::Duration::from_secs(2));
        // Two seconds is too short to say.
        assert_eq!(estimator.minutes_left(1_000_000_000), None);
        estimator.record(60_000_000, start + std::time::Duration::from_secs(6));
        // 10 MB/s with 940 MB to go: about a minute and a half.
        assert_eq!(estimator.minutes_left(1_000_000_000), Some(2));
        // A retry starts over.
        estimator.record(0, start + std::time::Duration::from_secs(7));
        assert_eq!(estimator.minutes_left(1_000_000_000), None);
        // Almost done still says one minute, never zero.
        let mut fast = Estimator::default();
        fast.record(0, start);
        fast.record(500_000_000, start + std::time::Duration::from_secs(5));
        assert_eq!(fast.minutes_left(510_000_000), Some(1));
    }

    #[test]
    fn setup_downloads_split_what_prepare_models_fetches() {
        use lokalbot_ai::ocr::{OCR_LANGUAGES_ID, OCR_MODEL_ID};

        let settings = Settings::default();
        let autocomplete = settings.cotyping_built_in_model_id.clone();
        let plain = setup_downloads(&settings, None, false);
        for id in [&settings.transcription_model, &settings.built_in_model_id] {
            assert!(plain.meeting.contains(id), "{id}");
        }
        assert!(plain.meeting.contains(&RUNTIME_ID.to_string()));
        assert!(!plain.meeting.contains(&autocomplete));
        assert!(plain.extra.is_empty());

        // The runtime comes with the meeting models; screen text and
        // Autocomplete's model are asked for on their own, once each.
        let both = setup_downloads(&settings, Some(OCR_LANGUAGES_ID), true);
        assert_eq!(both.meeting, plain.meeting);
        assert_eq!(
            both.extra,
            [OCR_LANGUAGES_ID.to_string(), autocomplete.clone()]
        );

        // Autocomplete already on, or screen text already chosen in settings,
        // still isn't something `PrepareModels` downloads.
        let on = Settings {
            cotyping_enabled: true,
            screen_context_capture_mode: ScreenContextMode::Text,
            ..settings.clone()
        };
        let meeting = setup_downloads(&on, None, false).meeting;
        assert!(!meeting.contains(&autocomplete));
        assert!(!meeting.contains(&OCR_MODEL_ID.to_string()));

        // With Think on a server and no search by meaning, Autocomplete
        // brings the runtime itself.
        let remote = Settings {
            summarizer_backend: SummarizerBackend::Ollama,
            semantic_search_enabled: false,
            ..settings
        };
        let remote = setup_downloads(&remote, None, true);
        assert!(!remote.meeting.contains(&RUNTIME_ID.to_string()));
        assert_eq!(remote.extra, [autocomplete, RUNTIME_ID.to_string()]);
    }

    #[test]
    fn mainland_china_locales_get_the_download_source() {
        for locale in ["zh-CN", "zh_CN.UTF-8", "zh-Hans", "zh-Hans-SG", "en-CN"] {
            assert!(is_mainland_china_locale(locale), "{locale}");
        }
        for locale in ["en-US", "zh-TW", "zh-Hant", "de_DE.UTF-8", "cn"] {
            assert!(!is_mainland_china_locale(locale), "{locale}");
        }
    }

    #[test]
    fn autocomplete_says_it_can_read_the_whole_window() {
        let text = autocomplete_disclosure();
        assert!(text.contains("the whole window"));
        assert!(text.contains("the text just above the field"));
        assert!(text.contains("never saved"));
        assert!(text.contains("turn either off"));
    }
}
