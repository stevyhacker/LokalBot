//! What the Settings window says about the state of each feature
//! (`SettingsStatus.swift`): the "Off" and "Paused" marks and count badges in
//! its list, what needs the person on Overview, each permission's row on
//! Privacy & permissions, and the status lines under every page's header.
//! Derived from real state and nothing else, so each of those places says
//! the same thing. Kept apart from drawing so it can be tested.
//!
//! Linux and Windows have no permission prompts like macOS. A permission here
//! is what this desktop allows LokalBot ([`crate::control::permissions`]):
//! its real state, which features that are on use it, and the one fix that
//! exists, if any (Windows' microphone switch, the calendar links).

use std::collections::HashMap;

use lokalbot_core::Settings;
use lokalbot_core::settings::{CotypingBackend, SummarizerBackend};

use crate::pages::people::model::fill;
use crate::state::{DownloadProgress, ModelStatus, SettingsCategory};

/// How a status line is marked.
#[derive(Clone, Debug, PartialEq)]
pub enum Tone {
    /// Something the person has to do: amber, with a warning sign.
    Need,
    /// Working: a green dot.
    Ok,
    /// Off, or waiting on something that is already under way: gray.
    Quiet,
    /// Something leaves this computer: amber, with a globe.
    Online,
    /// Under way, with how far along it is when that is known (0–1).
    Progress(Option<f32>),
}

/// What a status line's button, an Overview row and a Privacy & permissions
/// row do, so each fix works the same way everywhere.
#[derive(Clone, Debug, PartialEq)]
pub enum StatusAction {
    /// Where a permission is decided (`permissions::request`): the system's
    /// own switch where it has one, the calendar links, or its row on
    /// Privacy & permissions.
    Permission(&'static str),
    /// Starts downloading the models that are missing.
    Download,
    /// Opens another Settings page, on a setting when one is named.
    Open(SettingsCategory, Option<&'static str>),
}

/// One line under a Settings page's header: whether the feature works, and
/// when it does not, the one control that fixes it (`SettingsStatusLine`).
#[derive(Clone, Debug, PartialEq)]
pub struct StatusLine {
    pub id: &'static str,
    pub tone: Tone,
    pub text: String,
    pub action: Option<StatusAction>,
    /// The button's title (a catalog key), when it is not the action's own.
    pub action_title: Option<&'static str>,
}

impl StatusLine {
    fn new(id: &'static str, tone: Tone, text: impl Into<String>) -> Self {
        Self {
            id,
            tone,
            text: text.into(),
            action: None,
            action_title: None,
        }
    }

    fn action(mut self, action: StatusAction) -> Self {
        self.action = Some(action);
        self
    }

    fn titled(mut self, title: &'static str) -> Self {
        self.action_title = Some(title);
        self
    }

    /// The button's title, already translated.
    pub fn button_title(&self) -> Option<&'static str> {
        let key = self.action_title.or(match self.action {
            Some(StatusAction::Download) => Some("Download"),
            Some(StatusAction::Permission(_)) => Some("Review…"),
            Some(StatusAction::Open(..)) => Some("Change…"),
            None => None,
        })?;
        Some(lokalbot_i18n::tr(key))
    }

    /// Buttons fix something; links only take you somewhere.
    pub fn is_link(&self) -> bool {
        matches!(self.action, Some(StatusAction::Open(..)))
    }
}

/// The fix a permission has on this platform.
pub use crate::control::permissions::Fix as PermissionFix;

/// One row on Privacy & permissions.
#[derive(Clone, Debug, PartialEq)]
pub struct Permission {
    /// `microphone`, `accessibility`, …, as `permissions request` takes them.
    pub name: &'static str,
    pub title: String,
    pub granted: bool,
    /// False where nothing can be read before the feature is used, the way
    /// setup leaves it unclaimed too (`crate::access`).
    pub checked: bool,
    /// The features that are on and use it, already translated.
    pub needed_by: Vec<String>,
    /// What this desktop allows, or why it does not.
    pub detail: String,
    pub fix: Option<PermissionFix>,
}

/// Where a permission stands (`SettingsStatus.Access`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Access {
    Allowed,
    /// A feature that is on uses it, and this desktop does not allow it.
    Missing,
    /// Not allowed, and nothing that is on uses it.
    NotNeeded,
    /// Nothing can be read before it is used (the microphone).
    Unchecked,
}

impl From<crate::control::permissions::PermissionNeed> for Permission {
    fn from(need: crate::control::permissions::PermissionNeed) -> Self {
        Self {
            name: need.name,
            title: need.title,
            granted: need.granted,
            checked: need.checked,
            needed_by: need.needed_by,
            detail: need.detail,
            fix: need.fix,
        }
    }
}

impl Permission {
    pub fn access(&self) -> Access {
        if !self.checked {
            Access::Unchecked
        } else if self.granted {
            Access::Allowed
        } else if self.needed_by.is_empty() {
            Access::NotNeeded
        } else {
            Access::Missing
        }
    }

    /// The fix as a status action, when this platform has one.
    pub fn fix_action(&self) -> Option<StatusAction> {
        self.fix.map(|_| StatusAction::Permission(self.name))
    }

    /// The fix's button title (a catalog key).
    pub fn fix_title(&self) -> Option<&'static str> {
        self.fix.map(|fix| match fix {
            PermissionFix::SystemSettings => "Open System Settings…",
            PermissionFix::CalendarLinks => "Change…",
            PermissionFix::WindowCalls => "Get Window Calls…",
        })
    }

    /// Used by a feature named with `feature` (a catalog key).
    fn used_by(&self, feature: &str) -> bool {
        let name = lokalbot_i18n::tr(feature);
        self.needed_by.iter().any(|used| used == name)
    }
}

/// One of the three models, as far as Settings needs to describe it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Role {
    Transcribe,
    Think,
    Autocomplete,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ModelState {
    Ready,
    /// Not downloaded, and nothing is on its way.
    Missing,
    /// On its way, with how far along when that is known (0–1).
    Downloading(Option<f32>),
    /// A server that can't be used yet, or a download that failed.
    Attention,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ModelInfo {
    pub role: Role,
    pub name: String,
    /// What its download weighs, when one is needed and its size is known.
    pub bytes: Option<u64>,
    /// False for a server: nothing downloads.
    pub downloads: bool,
    pub state: ModelState,
}

impl ModelInfo {
    /// "Gemma 4 E2B (3.9 GB)", or the name alone when the size is unknown.
    pub fn name_and_size(&self) -> String {
        match self.bytes.filter(|bytes| self.downloads && *bytes > 0) {
            Some(bytes) => format!("{} ({})", self.name, size(bytes)),
            None => self.name.clone(),
        }
    }
}

/// "3.2 GB", the way the Models page sizes downloads.
pub fn size(bytes: u64) -> String {
    super::models::size_label(bytes)
}

/// What a role needs downloaded, and whether anything downloads at all.
pub(super) fn role_ids(role: Role, settings: &Settings) -> (Vec<String>, bool) {
    match role {
        Role::Transcribe => {
            let downloads = !lokalbot_speech::models::is_remote(&settings.transcription_model);
            (super::models::speech_needs(settings), downloads)
        }
        Role::Think => {
            let built_in = settings.summarizer_backend == SummarizerBackend::BuiltIn;
            let ids = if built_in {
                vec![
                    settings.built_in_model_id.clone(),
                    super::models::RUNTIME_ID.to_string(),
                ]
            } else {
                Vec::new()
            };
            (ids, built_in)
        }
        Role::Autocomplete => {
            let on_device = settings.cotyping_backend == CotypingBackend::OnDevice;
            (super::models::autocomplete_needs(settings), on_device)
        }
    }
}

fn role_name(role: Role, settings: &Settings) -> String {
    match role {
        Role::Transcribe => super::models::model_name(&settings.transcription_model),
        Role::Think => match settings.summarizer_backend {
            SummarizerBackend::BuiltIn => super::models::model_name(&settings.built_in_model_id),
            _ => crate::state::remote_ai_hosts(settings)
                .into_iter()
                .next()
                .unwrap_or_else(|| lokalbot_i18n::tr("Think").to_string()),
        },
        Role::Autocomplete => match settings.cotyping_backend {
            CotypingBackend::OnDevice => {
                super::models::model_name(&settings.cotyping_built_in_model_id)
            }
            _ => lokalbot_ai::autocomplete::server::configured_host(settings)
                .unwrap_or_else(|| lokalbot_i18n::tr("Autocomplete").to_string()),
        },
    }
}

/// The three models from what the engine reports and what is downloading.
pub fn models(
    settings: &Settings,
    status: &ModelStatus,
    downloads: &HashMap<String, DownloadProgress>,
) -> Vec<ModelInfo> {
    [Role::Transcribe, Role::Think, Role::Autocomplete]
        .into_iter()
        .map(|role| {
            let (ids, downloads_any) = role_ids(role, settings);
            let ready = match role {
                Role::Transcribe => status.transcription_ready,
                Role::Think => status.think_ready,
                Role::Autocomplete => status.autocomplete_ready,
            };
            let missing: Vec<&String> = ids
                .iter()
                .filter(|id| !status.installed.contains(id))
                .collect();
            // The runtime comes with Think; another role shares it.
            let sized: Vec<&String> = missing
                .iter()
                .copied()
                .filter(|id| role == Role::Think || id.as_str() != super::models::RUNTIME_ID)
                .collect();
            let bytes: u64 = sized
                .iter()
                .map(|id| super::models::model_bytes(id, settings))
                .sum();
            let running: Vec<&DownloadProgress> = missing
                .iter()
                .filter_map(|id| downloads.get(id.as_str()))
                .collect();
            let failed = running.iter().any(|progress| progress.error.is_some());
            let state = if ready {
                ModelState::Ready
            } else if failed || !downloads_any {
                ModelState::Attention
            } else if !running.is_empty() {
                let total: u64 = running.iter().map(|p| p.total_bytes).sum();
                let done: u64 = running.iter().map(|p| p.done_bytes).sum();
                ModelState::Downloading(
                    (total > 0 && running.len() == missing.len())
                        .then(|| (done as f32 / total as f32).clamp(0.0, 1.0)),
                )
            } else {
                ModelState::Missing
            };
            ModelInfo {
                role,
                name: role_name(role, settings),
                bytes: (bytes > 0).then_some(bytes),
                downloads: downloads_any,
                state,
            }
        })
        .collect()
}

/// Everything the status is derived from.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StatusInput {
    pub settings: Settings,
    pub permissions: Vec<Permission>,
    pub models: Vec<ModelInfo>,
    /// Free space on the drive that holds the models.
    pub free_bytes: Option<u64>,
    /// The kinds of data external agents may read, of [`AGENT_READ_KINDS`].
    pub agent_kinds: usize,
    pub agents_can_change_settings: bool,
    pub paired_devices: usize,
    /// Why autocomplete can't work on this desktop at all, if so.
    pub autocomplete_unavailable: Option<String>,
    /// The roles whose last check failed (`failedChecks`).
    pub failed_checks: Vec<Role>,
}

/// The setting a failed check's line opens: the page that runs the checks
/// (`SettingsStatus.modelChecksFocus`).
pub const MODEL_CHECKS_FOCUS: &str = "settings.modelChecks";

/// `AgentReadAccess.Kind`: meetings, screen memory, personal context, files
/// and agent notes.
pub const AGENT_READ_KINDS: usize = 5;

/// A list row's mark (`SettingsStatus.RowState`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowState {
    Normal,
    Off,
    /// On, but blocked by a missing permission or model.
    Paused,
}

/// Something only the person can fix, listed on Overview.
#[derive(Clone, Debug, PartialEq)]
pub enum Need {
    Permission(Permission),
    /// Models that have to be downloaded, and what they weigh together.
    Download {
        roles: Vec<Role>,
        bytes: Option<u64>,
    },
    /// A model that stopped or can't be used yet.
    ModelAttention(Role),
}

impl Need {
    /// The page where it is fixed, which carries the count badge.
    pub fn page(&self) -> SettingsCategory {
        match self {
            Need::Permission(_) => SettingsCategory::Privacy,
            Need::Download { .. } | Need::ModelAttention(_) => SettingsCategory::Models,
        }
    }
}

/// The features a page owns, as `permissions::needs` names them.
fn page_features(page: SettingsCategory) -> &'static [&'static str] {
    match page {
        SettingsCategory::Meetings => &["Meetings", "Calendar detection"],
        SettingsCategory::DayMemory => &["Screen & activity", "Screen images"],
        SettingsCategory::Writing => &["Autocomplete"],
        SettingsCategory::Dictation => &["Dictation"],
        SettingsCategory::Ask => &["Ask anywhere", "Selection actions"],
        _ => &[],
    }
}

pub struct SettingsStatus {
    pub input: StatusInput,
}

impl SettingsStatus {
    pub fn new(input: StatusInput) -> Self {
        Self { input }
    }

    fn settings(&self) -> &Settings {
        &self.input.settings
    }

    // ------------------------------------------------------- permissions

    /// Needed by something that is on, and not allowed.
    pub fn missing_permissions(&self) -> Vec<&Permission> {
        self.input
            .permissions
            .iter()
            .filter(|p| p.access() == Access::Missing)
            .collect()
    }

    /// Missing permissions a page's features use.
    fn missing_for(&self, page: SettingsCategory) -> Vec<&Permission> {
        let features = page_features(page);
        self.missing_permissions()
            .into_iter()
            .filter(|p| features.iter().any(|f| p.used_by(f)))
            .collect()
    }

    /// One line for each missing permission a page uses: what this desktop
    /// says about it, and its fix (or the way to its row).
    fn permission_lines(&self, page: SettingsCategory) -> Vec<StatusLine> {
        self.missing_for(page)
            .into_iter()
            .map(Self::permission_line)
            .collect()
    }

    fn permission_line(p: &Permission) -> StatusLine {
        let line = StatusLine::new("permission", Tone::Need, p.detail.clone());
        match (p.fix_action(), p.fix_title()) {
            (Some(action), Some(title)) => line.action(action).titled(title),
            _ => line
                .action(StatusAction::Open(
                    SettingsCategory::Privacy,
                    Some("settings.permissions"),
                ))
                .titled("Review…"),
        }
    }

    /// What stops trying dictation in its sheet: the microphone and the
    /// Transcribe model, said as the page's own lines say them, whether or
    /// not the shortcut is on (`DictationTrySheet.blockers`).
    pub fn dictation_try_blockers(&self) -> Vec<StatusLine> {
        let mut input = self.input.clone();
        input.settings.dictation_enabled = true;
        let status = SettingsStatus::new(input);
        let mut lines: Vec<StatusLine> = status
            .missing_for(SettingsCategory::Dictation)
            .into_iter()
            .filter(|p| p.name == "microphone")
            .map(Self::permission_line)
            .collect();
        lines.extend(status.model_line(Role::Transcribe, "settings.transcriptionModel"));
        lines
    }

    // ------------------------------------------------------------ models

    pub fn model(&self, role: Role) -> Option<&ModelInfo> {
        self.input.models.iter().find(|m| m.role == role)
    }

    /// Transcribe and Think always; Autocomplete's model only while
    /// Autocomplete is on.
    fn required_models(&self) -> impl Iterator<Item = &ModelInfo> {
        let autocomplete = self.settings().cotyping_enabled;
        self.input
            .models
            .iter()
            .filter(move |m| m.role != Role::Autocomplete || autocomplete)
    }

    pub fn models_to_download(&self) -> Vec<&ModelInfo> {
        self.required_models()
            .filter(|m| m.downloads && m.state == ModelState::Missing)
            .collect()
    }

    pub fn models_needing_attention(&self) -> Vec<&ModelInfo> {
        self.required_models()
            .filter(|m| m.state == ModelState::Attention)
            .collect()
    }

    pub fn models_downloading(&self) -> Vec<&ModelInfo> {
        self.input
            .models
            .iter()
            .filter(|m| matches!(m.state, ModelState::Downloading(_)))
            .collect()
    }

    /// 0–1 across the models that are downloading, when every size and
    /// progress is known.
    pub fn download_fraction(&self) -> Option<f32> {
        let working = self.models_downloading();
        if working.is_empty() {
            return None;
        }
        let mut total = 0u64;
        let mut arrived = 0f64;
        for model in working {
            let (Some(bytes), ModelState::Downloading(Some(progress))) =
                (model.bytes, &model.state)
            else {
                return None;
            };
            total += bytes;
            arrived += bytes as f64 * f64::from(progress.clamp(0.0, 1.0));
        }
        (total > 0).then(|| (arrived / total as f64) as f32)
    }

    fn total_bytes(models: &[&ModelInfo]) -> Option<u64> {
        models.iter().map(|m| m.bytes).sum::<Option<u64>>()
    }

    /// What every model that still has to arrive weighs together, for the
    /// header's "Download all" button. `None` when nothing is missing or a
    /// size is unknown.
    pub fn bytes_to_download(&self) -> Option<u64> {
        let downloads = self.models_to_download();
        Self::total_bytes(&downloads).filter(|bytes| !downloads.is_empty() && *bytes > 0)
    }

    // --------------------------------------------- what leaves this computer

    /// Every server the AI features send to, each named once.
    pub fn remote_hosts(&self) -> Vec<String> {
        crate::state::remote_ai_hosts(self.settings())
    }

    pub fn shares_with_devices(&self) -> bool {
        self.settings().companion_sharing_enabled
    }

    /// True while no AI server is in use and nothing is shared with phones.
    pub fn everything_stays_here(&self) -> bool {
        self.remote_hosts().is_empty() && !self.shares_with_devices()
    }

    // ---------------------------------------------------------- Overview

    pub fn needs(&self) -> Vec<Need> {
        let mut needs: Vec<Need> = self
            .missing_permissions()
            .into_iter()
            .map(|p| Need::Permission(p.clone()))
            .collect();
        let downloads = self.models_to_download();
        if !downloads.is_empty() {
            needs.push(Need::Download {
                roles: downloads.iter().map(|m| m.role).collect(),
                bytes: Self::total_bytes(&downloads),
            });
        }
        needs.extend(
            self.models_needing_attention()
                .into_iter()
                .map(|m| Need::ModelAttention(m.role)),
        );
        needs
    }

    pub fn needs_attention(&self) -> bool {
        !self.needs().is_empty()
    }

    /// The second line of the LokalBot row at the top of the list.
    pub fn summary(&self) -> String {
        let count = self.needs().len();
        if count == 1 {
            lokalbot_i18n::tr("1 thing needs you").into()
        } else if count > 1 {
            fill(
                lokalbot_i18n::tr("%lld things need you"),
                &[&count.to_string()],
            )
        } else if !self.models_downloading().is_empty() {
            lokalbot_i18n::tr("Downloading models…").into()
        } else {
            lokalbot_i18n::tr("Everything is working").into()
        }
    }

    /// Overview's headline, and the line under it.
    pub fn headline(&self) -> (String, String) {
        if self.needs_attention() {
            return (
                self.summary(),
                lokalbot_i18n::tr("Until then, parts of LokalBot can’t run.").into(),
            );
        }
        if !self.models_downloading().is_empty() {
            return (
                lokalbot_i18n::tr("Almost ready").into(),
                lokalbot_i18n::tr("The models are downloading. Everything else is set up.").into(),
            );
        }
        let hosts = self.remote_hosts();
        if !hosts.is_empty() {
            return (
                self.summary(),
                lokalbot_i18n::format(
                    "Some AI runs online at {0}. Everything else stays on this PC.",
                    &[("0", hosts.join(", "))],
                ),
            );
        }
        let detail = if self.shares_with_devices() {
            lokalbot_i18n::tr("Nothing needs you.")
        } else {
            lokalbot_i18n::tr("Nothing needs you, and everything stays on this PC.")
        };
        (self.summary(), detail.into())
    }

    pub fn need_title(&self, need: &Need) -> String {
        match need {
            Need::Permission(p) => p.title.clone(),
            Need::Download { .. } => lokalbot_i18n::tr("Download the models").into(),
            Need::ModelAttention(_) => lokalbot_i18n::tr("A model needs attention").into(),
        }
    }

    pub fn need_detail(&self, need: &Need) -> String {
        match need {
            Need::Permission(p) => fill(
                lokalbot_i18n::tr("Needed for: %@"),
                &[&p.needed_by.join(", ")],
            ),
            Need::Download { roles, bytes } => {
                let waiting = if roles.contains(&Role::Transcribe) || roles.contains(&Role::Think) {
                    lokalbot_i18n::tr("New meetings wait to be transcribed until then.")
                } else {
                    lokalbot_i18n::tr("Autocomplete waits until then.")
                };
                match bytes.filter(|bytes| *bytes > 0) {
                    Some(bytes) => format!("{} · {waiting}", size(bytes)),
                    None => waiting.into(),
                }
            }
            Need::ModelAttention(role) => fill(
                lokalbot_i18n::tr("%@ can’t be used yet."),
                &[&self
                    .model(*role)
                    .map(|m| m.name.clone())
                    .unwrap_or_default()],
            ),
        }
    }

    /// The fix of a need: its button title (a catalog key) and what it does.
    pub fn need_fix(&self, need: &Need) -> (&'static str, StatusAction) {
        match need {
            Need::Permission(p) => match (p.fix_title(), p.fix_action()) {
                (Some(title), Some(action)) => (title, action),
                _ => (
                    "Review…",
                    StatusAction::Open(SettingsCategory::Privacy, Some("settings.permissions")),
                ),
            },
            Need::Download { .. } => ("Download", StatusAction::Download),
            Need::ModelAttention(_) => (
                "Review…",
                StatusAction::Open(SettingsCategory::Models, None),
            ),
        }
    }

    // ---------------------------------------------------------- the list

    /// "Off" or "Paused" at the right of a feature's row.
    pub fn row_state(&self, page: SettingsCategory) -> RowState {
        let settings = self.settings();
        let not_ready = |role: Role| {
            self.model(role)
                .is_some_and(|m| m.state != ModelState::Ready)
        };
        match page {
            SettingsCategory::Meetings => {
                if self
                    .missing_for(page)
                    .iter()
                    .any(|p| p.name == "microphone")
                {
                    RowState::Paused
                } else {
                    RowState::Normal
                }
            }
            SettingsCategory::DayMemory => {
                if !settings.tracking_enabled {
                    RowState::Off
                } else if self.missing_for(page).is_empty() {
                    RowState::Normal
                } else {
                    RowState::Paused
                }
            }
            SettingsCategory::Files => off_unless(settings.file_search_enabled),
            SettingsCategory::Writing => {
                if !settings.cotyping_enabled {
                    RowState::Off
                } else if !self.missing_for(page).is_empty()
                    || self.input.autocomplete_unavailable.is_some()
                    || not_ready(Role::Autocomplete)
                {
                    RowState::Paused
                } else {
                    RowState::Normal
                }
            }
            SettingsCategory::Dictation => {
                if !settings.dictation_enabled {
                    RowState::Off
                } else if !self.missing_for(page).is_empty() || not_ready(Role::Transcribe) {
                    RowState::Paused
                } else {
                    RowState::Normal
                }
            }
            SettingsCategory::Agents => {
                off_unless(self.input.agent_kinds > 0 || self.input.agents_can_change_settings)
            }
            SettingsCategory::Devices => off_unless(settings.companion_sharing_enabled),
            SettingsCategory::Overview
            | SettingsCategory::General
            | SettingsCategory::Models
            | SettingsCategory::Privacy
            | SettingsCategory::Ask
            | SettingsCategory::PersonalContext
            | SettingsCategory::DailyReview
            | SettingsCategory::Advanced => RowState::Normal,
        }
    }

    /// How many things need the person on the page where they are fixed.
    pub fn badge(&self, page: SettingsCategory) -> usize {
        self.needs()
            .iter()
            .filter(|need| need.page() == page)
            .count()
    }

    // ------------------------------------------------------ page headers

    /// The status lines under a page's header, most pressing first.
    pub fn lines(&self, page: SettingsCategory) -> Vec<StatusLine> {
        let settings = self.settings();
        let off = || {
            vec![StatusLine::new(
                "off",
                Tone::Quiet,
                lokalbot_i18n::tr("Off"),
            )]
        };
        match page {
            SettingsCategory::Privacy => self.privacy_lines(),
            SettingsCategory::Models => self.model_lines(),
            SettingsCategory::Writing => self.autocomplete_lines(),
            SettingsCategory::Dictation => self.dictation_lines(),
            SettingsCategory::Meetings => self.meeting_lines(),
            SettingsCategory::DayMemory => {
                if settings.tracking_enabled {
                    self.permission_lines(page)
                } else {
                    off()
                }
            }
            SettingsCategory::Ask => self.permission_lines(page),
            SettingsCategory::Files if !settings.file_search_enabled => off(),
            SettingsCategory::Agents if self.row_state(page) == RowState::Off => off(),
            SettingsCategory::Devices if !settings.companion_sharing_enabled => off(),
            _ => Vec::new(),
        }
    }

    fn privacy_lines(&self) -> Vec<StatusLine> {
        let missing = self.missing_permissions().len();
        let line = if missing == 1 {
            StatusLine::new(
                "permissions",
                Tone::Need,
                lokalbot_i18n::tr("1 permission is off, so a feature is paused."),
            )
        } else if missing > 1 {
            StatusLine::new(
                "permissions",
                Tone::Need,
                fill(
                    lokalbot_i18n::tr("%lld permissions are off, so some features are paused."),
                    &[&missing.to_string()],
                ),
            )
        } else if !self.everything_stays_here() {
            StatusLine::new(
                "leaves",
                Tone::Online,
                lokalbot_i18n::tr("Permissions are set. See below for what leaves this PC."),
            )
        } else {
            StatusLine::new(
                "set",
                Tone::Ok,
                lokalbot_i18n::tr("All set. Nothing leaves this PC."),
            )
        };
        vec![line]
    }

    fn model_lines(&self) -> Vec<StatusLine> {
        let mut lines = Vec::new();
        let downloads = self.models_to_download();
        let working = self.models_downloading();
        if !downloads.is_empty() {
            let together = match (Self::total_bytes(&downloads), self.input.free_bytes) {
                (Some(bytes), Some(free)) if bytes > 0 => Some(lokalbot_i18n::format(
                    "Not downloaded yet. They need {0}, and this PC has {1} free.",
                    &[("0", size(bytes)), ("1", size(free))],
                )),
                _ => None,
            };
            let texts = together.map_or_else(|| Self::missing_each(&downloads), |text| vec![text]);
            // The header's own button downloads them all. While it shows
            // Cancel for a running download, the first line keeps the button.
            for (index, text) in texts.into_iter().enumerate() {
                let line = StatusLine::new(
                    if index == 0 {
                        "download"
                    } else {
                        "download.more"
                    },
                    Tone::Need,
                    text,
                );
                lines.push(if working.is_empty() || index > 0 {
                    line
                } else {
                    line.action(StatusAction::Download)
                });
            }
        }
        lines.extend(self.models_needing_attention().into_iter().map(|m| {
            StatusLine::new(
                "attention",
                Tone::Need,
                fill(lokalbot_i18n::tr("%@ can’t be used yet."), &[&m.name]),
            )
        }));
        if !working.is_empty() {
            lines.push(StatusLine::new(
                "downloading",
                Tone::Progress(self.download_fraction()),
                self.downloading_text(&working),
            ));
        }
        // A model that is here and did not answer its check.
        lines.extend(self.input.failed_checks.iter().filter_map(|role| {
            let model = self.model(*role).filter(|m| m.state == ModelState::Ready)?;
            Some(
                StatusLine::new(
                    "check",
                    Tone::Need,
                    fill(
                        lokalbot_i18n::tr("%@ didn’t pass its check."),
                        &[&model.name],
                    ),
                )
                .action(StatusAction::Open(
                    SettingsCategory::Models,
                    Some(MODEL_CHECKS_FOCUS),
                ))
                .titled("Review…"),
            )
        }));
        if !lines.is_empty() {
            return lines;
        }
        let hosts = self.remote_hosts();
        if hosts.is_empty() {
            let here: Vec<&ModelInfo> = self
                .required_models()
                .filter(|m| m.downloads && m.state == ModelState::Ready)
                .collect();
            let stored = self.stored_bytes(&here);
            return vec![match (stored, self.input.free_bytes) {
                (Some(stored), Some(free)) if stored > 0 => StatusLine::new(
                    "ready",
                    Tone::Ok,
                    lokalbot_i18n::format(
                        "All ready. The models take about {0} on this PC, and {1} is free.",
                        &[("0", size(stored)), ("1", size(free))],
                    ),
                ),
                _ => StatusLine::new(
                    "ready",
                    Tone::Ok,
                    lokalbot_i18n::tr("All set. Every model runs on this PC."),
                ),
            }];
        }
        vec![StatusLine::new(
            "ready",
            Tone::Online,
            fill(
                lokalbot_i18n::tr("All set. Some AI runs online at %@."),
                &[&hosts.join(", ")],
            ),
        )]
    }

    /// What the models that are here weigh, from the catalog sizes the
    /// download was announced with.
    fn stored_bytes(&self, here: &[&ModelInfo]) -> Option<u64> {
        let settings = self.settings();
        let mut total = 0;
        for model in here {
            let (ids, _) = role_ids(model.role, settings);
            total += ids
                .iter()
                .filter(|id| model.role == Role::Think || id.as_str() != super::models::RUNTIME_ID)
                .map(|id| super::models::model_bytes(id, settings))
                .sum::<u64>();
        }
        (total > 0).then_some(total)
    }

    /// "Downloading · 3.7 GB of 9 GB", or which models are downloading.
    fn downloading_text(&self, working: &[&ModelInfo]) -> String {
        match (Self::total_bytes(working), self.download_fraction()) {
            (Some(total), Some(fraction)) if total > 0 => fill(
                lokalbot_i18n::tr("Downloading · %@ of %@"),
                &[
                    &size((total as f64 * f64::from(fraction)).round() as u64),
                    &size(total),
                ],
            ),
            _ => fill(
                lokalbot_i18n::tr("%@ is downloading."),
                &[&working
                    .iter()
                    .map(|m| m.name.clone())
                    .collect::<Vec<_>>()
                    .join(", ")],
            ),
        }
    }

    /// Whether a role's model is missing, on its way, stopped or ready.
    fn model_line(&self, role: Role, focus: &'static str) -> Option<StatusLine> {
        let model = self.model(role)?;
        match &model.state {
            ModelState::Ready => None,
            ModelState::Downloading(progress) => Some(StatusLine::new(
                "model.downloading",
                Tone::Progress(*progress),
                fill(lokalbot_i18n::tr("%@ is downloading."), &[&model.name]),
            )),
            ModelState::Missing => Some(
                StatusLine::new(
                    "model.download",
                    Tone::Need,
                    fill(
                        lokalbot_i18n::tr("%@ isn’t downloaded yet."),
                        &[&model.name_and_size()],
                    ),
                )
                .action(StatusAction::Download),
            ),
            ModelState::Attention => Some(
                StatusLine::new(
                    "model.attention",
                    Tone::Need,
                    fill(lokalbot_i18n::tr("%@ can’t be used yet."), &[&model.name]),
                )
                .action(StatusAction::Open(SettingsCategory::Models, Some(focus)))
                .titled("Review…"),
            ),
        }
    }

    fn autocomplete_lines(&self) -> Vec<StatusLine> {
        let settings = self.settings();
        if !settings.cotyping_enabled {
            return vec![StatusLine::new(
                "off",
                Tone::Quiet,
                lokalbot_i18n::tr("Off. No suggestions appear in other apps."),
            )];
        }
        let mut lines = self.permission_lines(SettingsCategory::Writing);
        // Accessibility's row already says it when that is the reason.
        if let Some(reason) = &self.input.autocomplete_unavailable
            && !lines.iter().any(|line| &line.text == reason)
        {
            lines.insert(
                0,
                StatusLine::new("unavailable", Tone::Need, reason.clone()),
            );
        }
        lines.extend(self.model_line(Role::Autocomplete, "settings.cotypingBackend"));
        let leaves = lokalbot_ai::autocomplete::server::leaves_this_computer(settings);
        match lokalbot_ai::autocomplete::server::configured_host(settings).filter(|_| leaves) {
            Some(host) => lines.push(
                StatusLine::new(
                    "online",
                    Tone::Online,
                    fill(
                        lokalbot_i18n::tr("What you type is sent to %@, where its model runs."),
                        &[&host],
                    ),
                )
                .action(StatusAction::Open(
                    SettingsCategory::Models,
                    Some("settings.cotypingBackend"),
                )),
            ),
            None if lines.is_empty() => {
                if let Some(model) = self.model(Role::Autocomplete) {
                    lines.push(
                        StatusLine::new(
                            "ready",
                            Tone::Ok,
                            lokalbot_i18n::format(
                                "Ready · {0}, on this PC",
                                &[("0", model.name.clone())],
                            ),
                        )
                        .action(StatusAction::Open(
                            SettingsCategory::Models,
                            Some("settings.cotypingBackend"),
                        )),
                    );
                }
            }
            None => {}
        }
        lines
    }

    fn dictation_lines(&self) -> Vec<StatusLine> {
        let settings = self.settings();
        if !settings.dictation_enabled {
            return vec![StatusLine::new(
                "off",
                Tone::Quiet,
                lokalbot_i18n::tr("Off. The shortcut does nothing until you turn it on."),
            )];
        }
        let mut lines = self.permission_lines(SettingsCategory::Dictation);
        lines.extend(self.model_line(Role::Transcribe, "settings.transcriptionModel"));
        match lokalbot_core::remote_transcription::audio_destination(settings) {
            Some(host) => lines.push(
                StatusLine::new(
                    "online.speech",
                    Tone::Online,
                    fill(
                        lokalbot_i18n::tr("What you say is sent to %@ to be turned into text."),
                        &[&host],
                    ),
                )
                .action(StatusAction::Open(
                    SettingsCategory::Models,
                    Some("settings.transcriptionModel"),
                )),
            ),
            None if lines.is_empty() => {
                if let Some(model) = self.model(Role::Transcribe) {
                    lines.push(
                        StatusLine::new(
                            "ready",
                            Tone::Ok,
                            lokalbot_i18n::format(
                                "Ready · {0}, on this PC",
                                &[("0", model.name.clone())],
                            ),
                        )
                        .action(StatusAction::Open(
                            SettingsCategory::Models,
                            Some("settings.transcriptionModel"),
                        )),
                    );
                }
            }
            None => {}
        }
        if settings.dictation_intent == lokalbot_core::settings::DictationIntent::Compose
            && let Some(host) = think_host(settings)
        {
            lines.push(
                StatusLine::new(
                    "online.compose",
                    Tone::Online,
                    fill(
                        lokalbot_i18n::tr(
                            "Compose sends what you dictate to %@, where Think runs.",
                        ),
                        &[&host],
                    ),
                )
                .action(StatusAction::Open(
                    SettingsCategory::Models,
                    Some("settings.summarizerBackend"),
                )),
            );
        }
        lines
    }

    fn meeting_lines(&self) -> Vec<StatusLine> {
        let mut lines = self.permission_lines(SettingsCategory::Meetings);
        let downloads: Vec<&ModelInfo> = self
            .models_to_download()
            .into_iter()
            .filter(|m| m.role != Role::Autocomplete)
            .collect();
        // Which ones, each by name; the first line's button downloads them all.
        for (index, text) in Self::missing_each(&downloads).into_iter().enumerate() {
            let line = StatusLine::new(
                if index == 0 {
                    "model.download"
                } else {
                    "model.download.more"
                },
                Tone::Need,
                text,
            );
            lines.push(if index == 0 {
                line.action(StatusAction::Download)
            } else {
                line
            });
        }
        lines
    }

    /// "X isn’t downloaded yet." for each model: the Mac's sentence names one
    /// model, so several are never joined into one "isn’t".
    fn missing_each(downloads: &[&ModelInfo]) -> Vec<String> {
        downloads
            .iter()
            .map(|m| {
                fill(
                    lokalbot_i18n::tr("%@ isn’t downloaded yet."),
                    &[&m.name_and_size()],
                )
            })
            .collect()
    }
}

/// The server Think sends to, while its connection is allowed: what Compose
/// dictation sends there too. The transcription and autocomplete servers are
/// named on their own lines.
fn think_host(settings: &Settings) -> Option<String> {
    let think_only = Settings {
        cotyping_enabled: false,
        transcription_model: String::new(),
        ..settings.clone()
    };
    crate::state::remote_ai_hosts(&think_only)
        .into_iter()
        .next()
}

fn off_unless(on: bool) -> RowState {
    if on { RowState::Normal } else { RowState::Off }
}

/// What the library holds without the downloaded models
/// (`SettingsLibrarySize`): a long-used library has many thousands of files,
/// so call it off the main thread.
pub fn library_bytes(root: &std::path::Path, models: &std::path::Path) -> u64 {
    fn walk(directory: &std::path::Path, models: &std::path::Path, total: &mut u64) {
        let Ok(entries) = std::fs::read_dir(directory) else {
            return;
        };
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            let path = entry.path();
            if kind.is_dir() {
                if path != models {
                    walk(&path, models, total);
                }
            } else if kind.is_file() {
                *total += entry.metadata().map_or(0, |metadata| metadata.len());
            }
        }
    }
    let mut total = 0;
    walk(root, models, &mut total);
    total
}

/// Back and forward through the Settings pages visited in this window
/// (`SettingsPageHistory`).
#[derive(Clone, Debug, PartialEq)]
pub struct PageHistory {
    back: Vec<SettingsCategory>,
    forward: Vec<SettingsCategory>,
    current: SettingsCategory,
}

impl PageHistory {
    const LIMIT: usize = 50;

    pub fn new(current: SettingsCategory) -> Self {
        Self {
            back: Vec::new(),
            forward: Vec::new(),
            current,
        }
    }

    pub fn can_go_back(&self) -> bool {
        !self.back.is_empty()
    }

    pub fn can_go_forward(&self) -> bool {
        !self.forward.is_empty()
    }

    /// A page chosen from the list, a search result or a link. Choosing the
    /// page already shown changes nothing.
    pub fn visit(&mut self, page: SettingsCategory) {
        if page == self.current {
            return;
        }
        self.back.push(self.current);
        if self.back.len() > Self::LIMIT {
            self.back.remove(0);
        }
        self.forward.clear();
        self.current = page;
    }

    pub fn go_back(&mut self) -> Option<SettingsCategory> {
        let page = self.back.pop()?;
        self.forward.push(self.current);
        self.current = page;
        Some(page)
    }

    pub fn go_forward(&mut self) -> Option<SettingsCategory> {
        let page = self.forward.pop()?;
        self.back.push(self.current);
        self.current = page;
        Some(page)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use SettingsCategory as Page;

    fn permission(name: &'static str, granted: bool, needed_by: &[&str]) -> Permission {
        Permission {
            name,
            title: name.to_string(),
            granted,
            checked: name != "microphone",
            needed_by: needed_by
                .iter()
                .map(|f| lokalbot_i18n::tr(f).to_string())
                .collect(),
            detail: format!("{name} detail"),
            fix: (name == "calendar").then_some(PermissionFix::CalendarLinks),
        }
    }

    fn model(role: Role, state: ModelState, bytes: Option<u64>) -> ModelInfo {
        ModelInfo {
            role,
            name: format!("{role:?} model"),
            bytes,
            downloads: true,
            state,
        }
    }

    fn ready_models() -> Vec<ModelInfo> {
        vec![
            model(Role::Transcribe, ModelState::Ready, None),
            model(Role::Think, ModelState::Ready, None),
            model(Role::Autocomplete, ModelState::Ready, None),
        ]
    }

    fn status(input: StatusInput) -> SettingsStatus {
        SettingsStatus::new(input)
    }

    #[test]
    fn nothing_needs_you_when_everything_is_allowed_and_ready() {
        let s = status(StatusInput {
            permissions: vec![
                permission("microphone", true, &["Meetings"]),
                permission("accessibility", true, &["Screen & activity"]),
            ],
            models: ready_models(),
            ..Default::default()
        });
        assert!(s.needs().is_empty());
        assert_eq!(s.summary(), "Everything is working");
        assert_eq!(
            s.headline().1,
            "Nothing needs you, and everything stays on this PC."
        );
        assert_eq!(s.badge(Page::Privacy), 0);
        assert_eq!(s.lines(Page::Privacy)[0].tone, Tone::Ok);
    }

    #[test]
    fn a_missing_permission_is_one_need_badged_on_privacy_and_pauses_its_page() {
        let s = status(StatusInput {
            settings: Settings {
                tracking_enabled: true,
                ..Default::default()
            },
            permissions: vec![
                permission("accessibility", false, &["Screen & activity"]),
                // Not allowed, but nothing that is on uses it.
                permission("screen-recording", false, &[]),
            ],
            models: ready_models(),
            ..Default::default()
        });
        assert_eq!(s.needs().len(), 1);
        assert_eq!(s.summary(), "1 thing needs you");
        assert_eq!(s.badge(Page::Privacy), 1);
        assert_eq!(s.badge(Page::Models), 0);
        assert_eq!(s.row_state(Page::DayMemory), RowState::Paused);
        assert_eq!(
            s.input.permissions[1].access(),
            Access::NotNeeded,
            "only what something that is on uses counts"
        );
        // The page's header says what this desktop says, with the way to the row.
        let lines = s.lines(Page::DayMemory);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].text, "accessibility detail");
        assert_eq!(
            lines[0].action,
            Some(StatusAction::Open(
                Page::Privacy,
                Some("settings.permissions")
            ))
        );
        let need = &s.needs()[0];
        assert_eq!(s.need_detail(need), "Needed for: Screen & activity");
        assert_eq!(s.need_fix(need).0, "Review…");
    }

    #[test]
    fn a_permission_with_a_fix_offers_it() {
        let s = status(StatusInput {
            settings: Settings {
                calendar_detection_enabled: true,
                ..Default::default()
            },
            permissions: vec![permission("calendar", false, &["Calendar detection"])],
            models: ready_models(),
            ..Default::default()
        });
        let lines = s.lines(Page::Meetings);
        assert_eq!(lines[0].action, Some(StatusAction::Permission("calendar")));
        assert_eq!(lines[0].button_title(), Some("Change…"));
        assert_eq!(
            s.need_fix(&s.needs()[0]),
            ("Change…", StatusAction::Permission("calendar"))
        );
    }

    #[test]
    fn the_microphone_is_never_claimed_allowed_or_missing() {
        let mic = permission("microphone", true, &["Meetings"]);
        assert_eq!(mic.access(), Access::Unchecked);
        let s = status(StatusInput {
            permissions: vec![mic],
            models: ready_models(),
            ..Default::default()
        });
        assert_eq!(s.row_state(Page::Meetings), RowState::Normal);
        assert!(s.needs().is_empty());
    }

    #[test]
    fn missing_models_are_one_need_fixed_on_models() {
        let s = status(StatusInput {
            models: vec![
                model(Role::Transcribe, ModelState::Missing, Some(2_470_000_000)),
                model(Role::Think, ModelState::Missing, Some(2_740_000_000)),
                // Autocomplete is off, so its model isn't required.
                model(Role::Autocomplete, ModelState::Missing, Some(3_850_000_000)),
            ],
            free_bytes: Some(40_000_000_000),
            ..Default::default()
        });
        let needs = s.needs();
        assert_eq!(needs.len(), 1);
        assert_eq!(
            needs[0],
            Need::Download {
                roles: vec![Role::Transcribe, Role::Think],
                bytes: Some(5_210_000_000)
            }
        );
        assert_eq!(s.badge(Page::Models), 1);
        assert_eq!(
            s.need_detail(&needs[0]),
            "5.2 GB · New meetings wait to be transcribed until then."
        );
        let lines = s.lines(Page::Models);
        assert_eq!(
            lines[0].text,
            "Not downloaded yet. They need 5.2 GB, and this PC has 40.0 GB free."
        );
        // The header's "Download all" downloads them; the line has no button.
        assert_eq!(lines[0].action, None);
        // Meetings says which ones, one sentence each, with the same download.
        let meetings = s.lines(Page::Meetings);
        let texts: Vec<&str> = meetings.iter().map(|l| l.text.as_str()).collect();
        assert_eq!(
            texts,
            [
                "Transcribe model (2.5 GB) isn’t downloaded yet.",
                "Think model (2.7 GB) isn’t downloaded yet."
            ]
        );
        assert_eq!(meetings[0].action, Some(StatusAction::Download));
        assert_eq!(meetings[1].action, None);
        assert_eq!(s.bytes_to_download(), Some(5_210_000_000));
    }

    /// The Mac's "%@ isn’t downloaded yet." names one model; two never share
    /// one "isn’t", even before the free space is known.
    #[test]
    fn several_missing_models_are_never_one_isnt() {
        let two = || {
            vec![
                model(Role::Transcribe, ModelState::Missing, Some(927_000_000)),
                model(Role::Think, ModelState::Missing, Some(2_800_000_000)),
            ]
        };
        let unknown_space = status(StatusInput {
            models: two(),
            free_bytes: None,
            ..Default::default()
        });
        for page in [Page::Models, Page::Meetings] {
            for line in unknown_space.lines(page) {
                assert!(
                    !line.text.contains(", ") || !line.text.contains("isn’t"),
                    "{page:?}: {}",
                    line.text
                );
            }
        }
        let models = unknown_space.lines(Page::Models);
        assert_eq!(
            models[0].text,
            "Transcribe model (927 MB) isn’t downloaded yet."
        );
        assert_eq!(models[1].text, "Think model (2.8 GB) isn’t downloaded yet.");
        // One missing model keeps the sentence that names it.
        let one = status(StatusInput {
            models: vec![model(Role::Think, ModelState::Missing, Some(2_800_000_000))],
            free_bytes: None,
            ..Default::default()
        });
        assert_eq!(
            one.lines(Page::Models)[0].text,
            "Think model (2.8 GB) isn’t downloaded yet."
        );
    }

    #[test]
    fn downloads_under_way_say_how_far_they_are() {
        let s = status(StatusInput {
            models: vec![
                model(
                    Role::Transcribe,
                    ModelState::Downloading(Some(0.5)),
                    Some(2_000_000_000),
                ),
                model(
                    Role::Think,
                    ModelState::Downloading(Some(0.0)),
                    Some(2_000_000_000),
                ),
                model(Role::Autocomplete, ModelState::Ready, None),
            ],
            ..Default::default()
        });
        assert!(s.needs().is_empty());
        assert_eq!(s.summary(), "Downloading models…");
        assert_eq!(s.headline().0, "Almost ready");
        assert_eq!(s.download_fraction(), Some(0.25));
        let lines = s.lines(Page::Models);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].tone, Tone::Progress(Some(0.25)));
        assert_eq!(lines[0].text, "Downloading · 1.0 GB of 4.0 GB");
    }

    #[test]
    fn a_missing_model_keeps_its_button_while_the_header_shows_cancel() {
        let s = status(StatusInput {
            models: vec![
                model(
                    Role::Transcribe,
                    ModelState::Downloading(Some(0.5)),
                    Some(1),
                ),
                model(Role::Think, ModelState::Missing, Some(2_000_000_000)),
                model(Role::Autocomplete, ModelState::Ready, None),
            ],
            ..Default::default()
        });
        let lines = s.lines(Page::Models);
        assert_eq!(lines[0].id, "download");
        assert_eq!(lines[0].action, Some(StatusAction::Download));
        assert_eq!(lines[1].id, "downloading");
    }

    #[test]
    fn trying_dictation_names_only_what_stops_it_even_with_the_shortcut_off() {
        let mut microphone = permission("microphone", false, &["Dictation"]);
        microphone.checked = true;
        let s = status(StatusInput {
            permissions: vec![
                microphone,
                permission("accessibility", false, &["Dictation"]),
            ],
            models: vec![
                model(Role::Transcribe, ModelState::Missing, Some(1_000_000_000)),
                model(Role::Think, ModelState::Missing, Some(1)),
                model(Role::Autocomplete, ModelState::Ready, None),
            ],
            ..Default::default()
        });
        // The page says only that it is off.
        assert_eq!(s.lines(Page::Dictation)[0].id, "off");
        let blockers = s.dictation_try_blockers();
        assert_eq!(blockers.len(), 2);
        assert_eq!(blockers[0].text, "microphone detail");
        assert_eq!(blockers[1].id, "model.download");
        assert_eq!(blockers[1].action, Some(StatusAction::Download));
    }

    #[test]
    fn a_failed_check_is_a_line_that_opens_the_checks() {
        let s = status(StatusInput {
            models: ready_models(),
            failed_checks: vec![Role::Think, Role::Autocomplete],
            ..Default::default()
        });
        let lines = s.lines(Page::Models);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].text, "Think model didn’t pass its check.");
        assert_eq!(
            lines[0].action,
            Some(StatusAction::Open(Page::Models, Some(MODEL_CHECKS_FOCUS)))
        );
        // A check is no need of its own: nothing is badged for it.
        assert!(s.needs().is_empty());
        // A model that is not here has no check to fail.
        let missing = status(StatusInput {
            models: vec![model(Role::Think, ModelState::Missing, Some(1))],
            failed_checks: vec![Role::Think],
            ..Default::default()
        });
        assert!(
            missing
                .lines(Page::Models)
                .iter()
                .all(|line| line.id != "check")
        );
    }

    #[test]
    fn rows_say_off_and_paused() {
        let off = status(StatusInput {
            models: ready_models(),
            ..Default::default()
        });
        assert_eq!(off.row_state(Page::Writing), RowState::Off);
        assert_eq!(off.row_state(Page::Dictation), RowState::Off);
        assert_eq!(off.row_state(Page::Agents), RowState::Off);
        assert_eq!(off.row_state(Page::Devices), RowState::Off);
        assert_eq!(off.row_state(Page::General), RowState::Normal);
        assert_eq!(off.lines(Page::Agents)[0].text, "Off");
        let on = status(StatusInput {
            settings: Settings {
                cotyping_enabled: true,
                dictation_enabled: true,
                ..Default::default()
            },
            permissions: vec![permission("input-monitoring", false, &["Dictation"])],
            models: vec![
                model(Role::Transcribe, ModelState::Ready, None),
                model(Role::Think, ModelState::Ready, None),
                model(Role::Autocomplete, ModelState::Missing, Some(1)),
            ],
            agent_kinds: 1,
            ..Default::default()
        });
        assert_eq!(on.row_state(Page::Writing), RowState::Paused);
        assert_eq!(on.row_state(Page::Dictation), RowState::Paused);
        assert_eq!(on.row_state(Page::Agents), RowState::Normal);
        assert!(on.lines(Page::Agents).is_empty());
    }

    #[test]
    fn what_leaves_this_computer_is_said_where_it_happens() {
        let settings = Settings {
            summarizer_backend: SummarizerBackend::OpenAICompatible,
            openai_base_url: "https://ai.borealis.test/v1".into(),
            approved_remote_inference_origins: vec!["https://ai.borealis.test".into()],
            ..Default::default()
        };
        let hosts = crate::state::remote_ai_hosts(&settings);
        let s = status(StatusInput {
            settings,
            models: ready_models(),
            ..Default::default()
        });
        assert!(!s.everything_stays_here());
        let privacy = s.lines(Page::Privacy);
        assert_eq!(privacy[0].tone, Tone::Online);
        if let Some(host) = hosts.first() {
            assert!(s.headline().1.contains(host.as_str()));
            assert!(s.lines(Page::Models)[0].text.contains(host.as_str()));
        }
    }

    #[test]
    fn history_goes_back_and_forward_and_forgets_forward_on_a_new_page() {
        let mut history = PageHistory::new(Page::Overview);
        assert!(!history.can_go_back());
        history.visit(Page::General);
        history.visit(Page::General);
        history.visit(Page::Models);
        assert_eq!(history.go_back(), Some(Page::General));
        assert_eq!(history.go_back(), Some(Page::Overview));
        assert_eq!(history.go_back(), None);
        assert_eq!(history.go_forward(), Some(Page::General));
        history.visit(Page::Privacy);
        assert!(!history.can_go_forward());
        for _ in 0..60 {
            history.visit(Page::Files);
            history.visit(Page::Ask);
        }
        assert_eq!(history.back.len(), PageHistory::LIMIT);
    }

    #[test]
    fn the_library_size_leaves_out_the_models() {
        let root = tempfile::tempdir().unwrap();
        let models = root.path().join("models");
        std::fs::create_dir_all(models.join("big")).unwrap();
        std::fs::write(models.join("big/weights.gguf"), vec![0u8; 4000]).unwrap();
        std::fs::create_dir_all(root.path().join("meetings/a")).unwrap();
        std::fs::write(root.path().join("meetings/a/meta.json"), vec![0u8; 120]).unwrap();
        std::fs::write(root.path().join("settings.json"), vec![0u8; 30]).unwrap();
        assert_eq!(library_bytes(root.path(), &models), 150);
    }
}
