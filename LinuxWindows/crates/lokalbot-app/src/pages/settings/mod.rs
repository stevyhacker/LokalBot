//! Settings (`SettingsView.swift`, `SettingsSidebar.swift`), in its own
//! window (`windows::settings`). On the left: search, the LokalBot row that
//! opens Overview with what needs you, then every page in its group, each
//! marked "Off", "Paused" or with a count where something needs fixing
//! (`status`). On the right: back, forward and the page's name in the
//! window's bar, then the page: Overview's status page, or one shared header
//! (`header`) above the page's sections. Search reaches every page.

pub mod advanced;
mod calendar;
pub mod catalog;
mod coding_agents;
mod day_memory;
mod devices;
mod dictation;
mod exports;
mod files;
pub(crate) mod general;
mod header;
mod health;
pub mod meetings;
mod model_browse;
mod model_checks;
pub(crate) mod model_options;
mod model_overview;
pub(crate) mod model_setup;
pub mod models;
mod overnight_review;
mod overview;
mod personal_context;
mod plans;
mod privacy;
mod remembered_people;
mod resource_monitor;
mod retention_review;
pub(crate) use retention_review::needs_review as needs_retention_review;
mod routines;
pub mod status;
mod subpage;
mod try_sheet;
pub mod writing;
mod writing_rehearsal;
mod writing_server;
mod writing_stats;

pub use coding_agents::choose as choose_coding_agents;
use day_memory::hour_label;
pub(crate) use devices::{history_label, pairing_prompt_changed};

use std::collections::HashSet;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState, TextareaState};
use gpui_kit::component::slider::{SliderEvent, SliderState};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, Focusable as _, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement as _, Render, ScrollHandle, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window, div, px,
};
use lokalbot_core::Settings;
use lokalbot_core::access::ScreenScope;
use lokalbot_platform::shortcuts::Shortcut;

use crate::pages::people::model::fill as people_fill;
use crate::state::{AppData, SettingsCategory};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::rule_list::{RuleKind, RuleList, RuleListEvent};
use crate::ui::shortcut_field::{ShortcutEvent, ShortcutField};
use crate::ui::{self, Ico, settings_row};

/// Every page, in the order the window lists them: the LokalBot row
/// (Overview), the pages above the first heading, each heading's pages, then
/// Diagnostics (`SettingsTab.allCases`).
pub const CATEGORIES: [SettingsCategory; 15] = [
    SettingsCategory::Overview,
    SettingsCategory::General,
    SettingsCategory::Models,
    SettingsCategory::Privacy,
    SettingsCategory::Meetings,
    SettingsCategory::DayMemory,
    SettingsCategory::Files,
    SettingsCategory::Ask,
    SettingsCategory::PersonalContext,
    SettingsCategory::DailyReview,
    SettingsCategory::Writing,
    SettingsCategory::Dictation,
    SettingsCategory::Agents,
    SettingsCategory::Devices,
    SettingsCategory::Advanced,
];

/// The pages listed under the LokalBot row, above the first heading.
pub const LEADING_PAGES: [SettingsCategory; 3] = [
    SettingsCategory::General,
    SettingsCategory::Models,
    SettingsCategory::Privacy,
];

/// The pages listed after the last heading.
pub const TRAILING_PAGES: [SettingsCategory; 1] = [SettingsCategory::Advanced];

/// The headings of the list, in order (`SettingsTab.Group`).
pub const GROUPS: [&str; 4] = ["Remember", "Assistant", "Writing", "Sharing"];

/// The heading a page sits under; `None` above and below the headings.
pub fn category_group(category: SettingsCategory) -> Option<&'static str> {
    match category {
        SettingsCategory::Meetings | SettingsCategory::DayMemory | SettingsCategory::Files => {
            Some("Remember")
        }
        SettingsCategory::Ask
        | SettingsCategory::PersonalContext
        | SettingsCategory::DailyReview => Some("Assistant"),
        SettingsCategory::Writing | SettingsCategory::Dictation => Some("Writing"),
        SettingsCategory::Agents | SettingsCategory::Devices => Some("Sharing"),
        SettingsCategory::Overview
        | SettingsCategory::General
        | SettingsCategory::Models
        | SettingsCategory::Privacy
        | SettingsCategory::Advanced => None,
    }
}

/// The page's glyph, the Lucide closest to the Mac's symbol.
pub fn category_icon(category: SettingsCategory) -> Ico {
    match category {
        SettingsCategory::Overview => Ico::LayoutGrid,
        SettingsCategory::General => Ico::Settings,
        SettingsCategory::Models => Ico::Package,
        SettingsCategory::Privacy => Ico::Lock,
        SettingsCategory::Meetings => Ico::AudioLines,
        SettingsCategory::DayMemory => Ico::AppWindow,
        SettingsCategory::Files => Ico::Folder,
        SettingsCategory::Ask => Ico::Sparkles,
        SettingsCategory::PersonalContext => Ico::CircleUser,
        SettingsCategory::DailyReview => Ico::Moon,
        SettingsCategory::Writing => Ico::TextCursorInput,
        SettingsCategory::Dictation => Ico::Mic,
        SettingsCategory::Agents => Ico::Network,
        SettingsCategory::Devices => Ico::Smartphone,
        SettingsCategory::Advanced => Ico::Activity,
    }
}

/// One line under the page's name in its header (`SettingsTab.summary`).
/// Overview has no header: it opens with what needs you.
pub fn category_summary(category: SettingsCategory, settings: &Settings) -> String {
    let text = match category {
        SettingsCategory::Overview => return String::new(),
        SettingsCategory::General => lokalbot_i18n::tr("Startup, appearance, and updates."),
        SettingsCategory::Models => lokalbot_i18n::tr(
            "Three AI models do LokalBot’s work. They run on this PC unless you choose an online one.",
        ),
        SettingsCategory::Privacy => {
            lokalbot_i18n::tr("What LokalBot may use on this PC, and what leaves it.")
        }
        SettingsCategory::Meetings => {
            lokalbot_i18n::tr("Detection, transcription, speakers, notes, and export.")
        }
        SettingsCategory::DayMemory => lokalbot_i18n::tr(
            "What LokalBot sees on screen, how long it keeps it, and what it never captures.",
        ),
        SettingsCategory::Files => {
            lokalbot_i18n::tr("Folders LokalBot reads, so Ask can find files by what’s in them.")
        }
        SettingsCategory::Ask => lokalbot_i18n::tr(
            "Ask from any app, act on selected text, and choose what answers use.",
        ),
        SettingsCategory::PersonalContext => {
            lokalbot_i18n::tr("What you told LokalBot about yourself, and what it learns.")
        }
        SettingsCategory::DailyReview => {
            lokalbot_i18n::tr("The day digest, the overnight review, routines, and the daily note.")
        }
        SettingsCategory::Writing => {
            lokalbot_i18n::tr("Suggests the next few words as you type, in any app.")
        }
        SettingsCategory::Dictation => {
            // Dictation's line names its shortcut.
            return people_fill(
                lokalbot_i18n::tr("Press %@, speak, and the text lands where you type."),
                &[&settings.dictation_shortcut],
            );
        }
        SettingsCategory::Agents => {
            lokalbot_i18n::tr("What Claude, Codex, Cursor, and other agents can read or change.")
        }
        SettingsCategory::Devices => {
            lokalbot_i18n::tr("Read your work memory on your own iPhone, iPad, or Android device.")
        }
        SettingsCategory::Advanced => {
            lokalbot_i18n::tr("Memory health, resources, and files for support.")
        }
    };
    text.to_string()
}

/// One grouped section of a category; `ids` are the rows it holds, for search jumps.
pub struct Section {
    pub title: Option<&'static str>,
    /// Drawn in place of the title (a disclosure, a way back). A section
    /// with a header and no rows is the header alone, with no panel.
    pub header: Option<AnyElement>,
    pub ids: Vec<&'static str>,
    pub rows: Vec<AnyElement>,
}

impl Section {
    pub fn new(title: impl Into<Option<&'static str>>) -> Self {
        Self {
            title: title.into(),
            header: None,
            ids: Vec::new(),
            rows: Vec::new(),
        }
    }

    /// An element on its own, outside any panel: a subpage's way back, the
    /// Advanced disclosure.
    pub fn bare(element: impl IntoElement) -> Self {
        Self::new(None).header(element)
    }

    pub fn header(mut self, element: impl IntoElement) -> Self {
        self.header = Some(element.into_any_element());
        self
    }

    pub fn row(mut self, id: &'static str, element: impl IntoElement) -> Self {
        self.ids.push(id);
        self.rows.push(element.into_any_element());
        self
    }
}

pub struct SettingsPage {
    /// The Files grant as last set here; `None` reads the marker.
    files_access: Option<bool>,
    agent_notes_access: Option<bool>,
    data: Entity<AppData>,
    search: Entity<InputState>,
    query: String,
    /// The setting a search result jumped to; it stays highlighted.
    focused: Option<&'static str>,
    pending_scroll: Option<&'static str>,
    scroll: ScrollHandle,
    open_details: HashSet<&'static str>,
    quick_recall_shortcut: Entity<ShortcutField>,
    dictation_shortcut: Entity<ShortcutField>,
    selection_actions_shortcut: Entity<ShortcutField>,
    digest_prompt: Entity<TextareaState>,
    cotyping_name: Entity<InputState>,
    cotyping_style: Entity<InputState>,
    excluded_apps: Entity<RuleList>,
    excluded_sites: Entity<RuleList>,
    retention_slider: Entity<SliderState>,
    /// Writing: the practice editor, autocomplete's exclusions and pause.
    practice: Entity<TextareaState>,
    practice_text: (String, String),
    /// The practice editor's origin in the window, from its last paint.
    practice_origin: std::rc::Rc<std::cell::Cell<Option<gpui_kit::Point<gpui_kit::Pixels>>>>,
    cotyping_excluded_apps: Entity<RuleList>,
    cotyping_excluded_sites: Entity<RuleList>,
    debounce_slider: Entity<SliderState>,
    interval_slider: Entity<SliderState>,
    writing: writing::WritingState,
    overnight: overnight_review::OvernightState,
    personal: personal_context::PersonalState,
    /// External-agent markers, read from disk off the main thread.
    meetings_access: Option<bool>,
    screen_access: Option<Option<ScreenScope>>,
    cli_installed: Option<bool>,
    /// Whether the command's folder is on PATH, and what the last CLI button did.
    cli_on_path: Option<bool>,
    cli_message: Option<String>,
    agent_changes_open: bool,
    access_generation: u64,
    models: models::ModelsState,
    resources: resource_monitor::ResourceMonitor,
    calendar: calendar::CalendarState,
    devices: devices::DevicesState,
    /// "Never read sessions in these folders".
    coding_agent_folders: Entity<RuleList>,
    /// Where the retention slider is while it is being dragged. Nothing changes
    /// until it is let go and any review is applied.
    retention_draft: Option<u32>,
    retention_error: Option<String>,
    retention_completion: Option<String>,
    /// The library's size and the free space on its drive, for Memory health.
    storage: Option<(u64, Option<u64>)>,
    /// Read with the storage sizes, for Memory health.
    latest_activity: Option<chrono::DateTime<chrono::Utc>>,
    pending_jobs: usize,
    storage_measured_at: Option<std::time::Instant>,
    last_settings: Settings,
    /// Back and forward through the pages shown in this window.
    history: status::PageHistory,
    /// The page a row of Autocomplete or Dictation opened in its place.
    subpage: Option<subpage::Subpage>,
    /// The library without its models, and the free space where the models
    /// are, for Overview and Privacy & permissions. Measured off the main
    /// thread now and then.
    library_size: Option<u64>,
    free_bytes: Option<u64>,
    library_measured_at: Option<std::time::Instant>,
    /// The free space alone, which the download lines on every page's header
    /// weigh the missing models against.
    free_measured_at: Option<std::time::Instant>,
    _subscriptions: Vec<Subscription>,
}

/// What the Ask and dictation shortcuts share: not selection actions' chord,
/// and nothing the system or other apps hold (Ctrl+Shift+W closes tabs here).
fn other_shortcut_problem(candidate: &str, settings: &Settings) -> Option<String> {
    use lokalbot_platform::shortcuts::ShortcutProblem;
    if settings.selection_actions_enabled && candidate == settings.selection_actions_shortcut {
        return Some(
            lokalbot_i18n::tr(&ShortcutProblem::UsedBySelectionActions.message()).to_string(),
        );
    }
    Shortcut::parse(candidate)
        .ok()?
        .selection_actions_problem(None, None)
        .filter(|problem| *problem == ShortcutProblem::UsedBySystem)
        .map(|problem| lokalbot_i18n::tr(&problem.message()).to_string())
}

impl SettingsPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let settings = data.read(cx).settings.clone();
        let search = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Search settings…",
                window,
                cx,
            ))
        });
        let quick_recall_shortcut = cx.new(|cx| {
            ShortcutField::new(
                settings.quick_recall_shortcut.clone(),
                "Ctrl+Shift+Space",
                |candidate, cx| {
                    let settings = &AppData::global(cx).read(cx).settings;
                    let parse = |text: &str| Shortcut::parse(text).ok();
                    parse(candidate)
                        .and_then(|shortcut| {
                            shortcut
                                .quick_recall_problem(parse(&settings.dictation_shortcut).as_ref())
                        })
                        .map(|problem| lokalbot_i18n::tr(&problem.message()).to_string())
                        .or_else(|| other_shortcut_problem(candidate, settings))
                },
                window,
                cx,
            )
        });
        let dictation_shortcut = cx.new(|cx| {
            ShortcutField::new(
                settings.dictation_shortcut.clone(),
                "Alt+Space",
                |candidate, cx| {
                    let settings = &AppData::global(cx).read(cx).settings;
                    let parse = |text: &str| Shortcut::parse(text).ok();
                    parse(candidate)
                        .and_then(|shortcut| {
                            shortcut
                                .dictation_problem(parse(&settings.quick_recall_shortcut).as_ref())
                        })
                        .map(|problem| lokalbot_i18n::tr(&problem.message()).to_string())
                        .or_else(|| other_shortcut_problem(candidate, settings))
                },
                window,
                cx,
            )
        });
        let selection_actions_shortcut = cx.new(|cx| {
            ShortcutField::new(
                settings.selection_actions_shortcut.clone(),
                "Ctrl+Alt+Space",
                |candidate, cx| {
                    let settings = &AppData::global(cx).read(cx).settings;
                    let parse = |text: &str| Shortcut::parse(text).ok();
                    let problem = parse(candidate)?.selection_actions_problem(
                        parse(&settings.dictation_shortcut).as_ref(),
                        parse(&settings.quick_recall_shortcut).as_ref(),
                    )?;
                    Some(lokalbot_i18n::tr(&problem.message()).to_string())
                },
                window,
                cx,
            )
        });
        let digest_prompt = cx.new(|cx| {
            TextareaState::new(window, cx)
                .rows(3)
                .placeholder(crate::i18n::placeholder(
                    "Example: Emphasize decisions, blockers, and next steps.",
                    window,
                    cx,
                ))
                .default_value(settings.day_digest_custom_prompt.clone())
        });
        let cotyping_name = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::i18n::placeholder("Optional", window, cx))
                .default_value(settings.cotyping_user_name.clone())
        });
        let cotyping_style = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::i18n::placeholder(
                    "Optional, e.g. concise and friendly",
                    window,
                    cx,
                ))
                .default_value(settings.cotyping_style_note.clone())
        });
        let excluded_apps = cx.new(|cx| {
            RuleList::new(
                "Never capture these apps",
                RuleKind::Applications,
                &settings.excluded_apps,
                window,
                cx,
            )
        });
        let excluded_sites = cx.new(|cx| {
            RuleList::new(
                "Never capture these sites",
                RuleKind::Domains,
                &settings.excluded_screen_domains,
                window,
                cx,
            )
        });
        let retention_slider = cx.new(|_| {
            SliderState::new()
                .min(1.)
                .max(90.)
                .step(1.)
                .default_value(settings.retention_days as f32)
        });
        let practice = cx.new(|cx| {
            TextareaState::new(window, cx)
                .rows(3)
                .default_value(writing::PRACTICE_OPENING)
        });
        let cotyping_excluded_apps = cx.new(|cx| {
            RuleList::new(
                "Never suggest in these apps",
                RuleKind::Applications,
                &settings.cotyping_excluded_apps,
                window,
                cx,
            )
        });
        let cotyping_excluded_sites = cx.new(|cx| {
            RuleList::new(
                "Never suggest on these sites",
                RuleKind::WritingDomains,
                &settings.cotyping_excluded_domains,
                window,
                cx,
            )
        });
        let debounce_slider = cx.new(|_| {
            SliderState::new()
                .min(20.)
                .max(1000.)
                .step(20.)
                .default_value(settings.cotyping_debounce_ms as f32)
        });
        let interval_slider = cx.new(|_| {
            SliderState::new()
                .min(1.)
                .max(15.)
                .step(1.)
                .default_value(settings.screenshot_interval_minutes.clamp(1.0, 15.0) as f32)
        });

        let mut subscriptions = vec![
            cx.observe_in(&data, window, Self::on_data_changed),
            // A window closed while a shortcut field records never hears the
            // field stop, and the global shortcuts would stay paused.
            cx.on_release(|this, cx| {
                let was_recording = this
                    .data
                    .update(cx, |data, _| std::mem::take(&mut data.shortcut_recording));
                if was_recording {
                    crate::desktop::sync_shortcuts_later(cx);
                }
            }),
            cx.subscribe_in(&search, window, |this, input, event: &InputEvent, _, cx| {
                if matches!(event, InputEvent::Change) {
                    this.query = input.read(cx).value().to_string();
                    cx.notify();
                }
            }),
            cx.subscribe_in(
                &quick_recall_shortcut,
                window,
                |this, _, event: &ShortcutEvent, _, cx| match event {
                    ShortcutEvent::Changed(value) => {
                        let value = value.clone();
                        this.update_settings(move |s| s.quick_recall_shortcut = value, cx);
                    }
                    ShortcutEvent::Recording(recording) => {
                        let recording = *recording;
                        this.data.update(cx, |data, cx| {
                            data.shortcut_recording = recording;
                            cx.notify();
                        });
                        // Unregisters the global shortcuts while the field
                        // records, and puts them back when it stops.
                        crate::desktop::sync_shortcuts_later(cx);
                    }
                },
            ),
            cx.subscribe_in(
                &dictation_shortcut,
                window,
                |this, _, event: &ShortcutEvent, _, cx| match event {
                    ShortcutEvent::Changed(value) => {
                        let value = value.clone();
                        this.update_settings(move |s| s.dictation_shortcut = value, cx);
                    }
                    ShortcutEvent::Recording(recording) => {
                        let recording = *recording;
                        this.data.update(cx, |data, cx| {
                            data.shortcut_recording = recording;
                            cx.notify();
                        });
                        // Unregisters the global shortcuts while the field
                        // records, and puts them back when it stops.
                        crate::desktop::sync_shortcuts_later(cx);
                    }
                },
            ),
            cx.subscribe_in(
                &selection_actions_shortcut,
                window,
                |this, _, event: &ShortcutEvent, _, cx| match event {
                    ShortcutEvent::Changed(value) => {
                        let value = value.clone();
                        this.update_settings(move |s| s.selection_actions_shortcut = value, cx);
                    }
                    ShortcutEvent::Recording(recording) => {
                        let recording = *recording;
                        this.data.update(cx, |data, cx| {
                            data.shortcut_recording = recording;
                            cx.notify();
                        });
                        // Unregisters the global shortcuts while the field
                        // records, and puts them back when it stops.
                        crate::desktop::sync_shortcuts_later(cx);
                    }
                },
            ),
            cx.subscribe_in(
                &digest_prompt,
                window,
                |this, input, event: &InputEvent, _, cx| {
                    if matches!(event, InputEvent::Change) {
                        let value = input.read(cx).value().to_string();
                        this.update_settings(move |s| s.day_digest_custom_prompt = value, cx);
                    }
                },
            ),
            cx.subscribe_in(
                &cotyping_name,
                window,
                |this, input, event: &InputEvent, _, cx| {
                    if matches!(event, InputEvent::Change) {
                        let value = input.read(cx).value().to_string();
                        this.update_settings(move |s| s.cotyping_user_name = value, cx);
                    }
                },
            ),
            cx.subscribe_in(
                &cotyping_style,
                window,
                |this, input, event: &InputEvent, _, cx| {
                    if matches!(event, InputEvent::Change) {
                        let value = input.read(cx).value().to_string();
                        this.update_settings(move |s| s.cotyping_style_note = value, cx);
                    }
                },
            ),
        ];
        let coding_agent_folders = cx.new(|cx| {
            RuleList::new(
                "Never read sessions in these folders",
                RuleKind::Folders,
                &settings.coding_agent_excluded_folders,
                window,
                cx,
            )
        });
        for (list, set) in [
            (
                &coding_agent_folders,
                (|s: &mut Settings, v: String| s.coding_agent_excluded_folders = v)
                    as fn(&mut Settings, String),
            ),
            (&excluded_apps, |s: &mut Settings, v: String| {
                s.excluded_apps = v
            }),
            (&excluded_sites, |s: &mut Settings, v: String| {
                s.excluded_screen_domains = v
            }),
            (&cotyping_excluded_apps, |s: &mut Settings, v: String| {
                s.cotyping_excluded_apps = v
            }),
            (&cotyping_excluded_sites, |s: &mut Settings, v: String| {
                s.cotyping_excluded_domains = v
            }),
        ] {
            subscriptions.push(cx.subscribe_in(
                list,
                window,
                move |this, _, event: &RuleListEvent, _, cx| {
                    let RuleListEvent::Changed(value) = event;
                    let value = value.clone();
                    this.update_settings(move |s| set(s, value), cx);
                },
            ));
        }
        subscriptions.push(cx.subscribe_in(
            &retention_slider,
            window,
            |this, _, event: &SliderEvent, window, cx| match event {
                // Dragging only previews: shortening has to go through the review.
                SliderEvent::Change(value) => {
                    this.retention_draft = Some(value.start().round() as u32);
                    cx.notify();
                }
                SliderEvent::Release(value) => {
                    let days = value.start().round() as u32;
                    let forever = this.data.read(cx).settings.keep_ocr_text_forever;
                    this.propose_retention(days, forever, window, cx);
                }
            },
        ));
        subscriptions.push(cx.subscribe_in(
            &debounce_slider,
            window,
            |this, _, event: &SliderEvent, _, cx| {
                let (SliderEvent::Change(value) | SliderEvent::Release(value)) = event;
                let ms = value.start().round() as u32;
                this.update_settings(move |s| s.cotyping_debounce_ms = ms, cx);
            },
        ));
        // Typing and caret moves in the practice editor go to the engine.
        subscriptions.push(cx.observe(&practice, |this, _, cx| this.practice_sync(cx)));
        if let Some(autocomplete) = crate::autocomplete::global(cx) {
            subscriptions.push(cx.observe(&autocomplete, |_, _, cx| cx.notify()));
        }
        if let Some(updates) = crate::updates::global(cx) {
            subscriptions.push(cx.observe(&updates, |_, _, cx| cx.notify()));
        }
        subscriptions.push(cx.subscribe_in(
            &interval_slider,
            window,
            |this, _, event: &SliderEvent, _, cx| {
                let (SliderEvent::Change(value) | SliderEvent::Release(value)) = event;
                let minutes = f64::from(value.start().round());
                this.update_settings(move |s| s.screenshot_interval_minutes = minutes, cx);
            },
        ));

        let models = models::ModelsState::new(&settings, window, cx);
        subscriptions.extend(models::ModelsState::subscribe(&models, window, cx));
        let writing = writing::WritingState::new(&settings, window, cx);
        subscriptions.extend(writing::WritingState::subscribe(&writing, window, cx));
        let calendar = calendar::CalendarState::new(&settings, window, cx);
        subscriptions.extend(calendar::CalendarState::subscribe(&calendar, window, cx));
        let devices = devices::DevicesState::new(&settings, window, cx);
        subscriptions.extend(devices::DevicesState::subscribe(&devices, window, cx));
        if let Some(host) = crate::control::global(cx) {
            subscriptions.push(cx.observe(&host, |this, host, cx| {
                let generation = host.read(cx).access_generation;
                if generation != this.access_generation {
                    this.access_generation = generation;
                    this.reload_access(cx);
                }
                cx.notify();
            }));
        }
        let opened_on = data.read(cx).settings_category;
        let mut page = Self {
            data,
            search,
            query: String::new(),
            focused: None,
            pending_scroll: None,
            scroll: ScrollHandle::new(),
            open_details: HashSet::new(),
            quick_recall_shortcut,
            dictation_shortcut,
            selection_actions_shortcut,
            digest_prompt,
            cotyping_name,
            cotyping_style,
            excluded_apps,
            excluded_sites,
            retention_slider,
            practice,
            practice_text: (String::new(), String::new()),
            practice_origin: Default::default(),
            cotyping_excluded_apps,
            cotyping_excluded_sites,
            debounce_slider,
            interval_slider,
            overnight: Default::default(),
            personal: Default::default(),
            files_access: None,
            agent_notes_access: None,
            meetings_access: None,
            screen_access: None,
            cli_installed: None,
            cli_on_path: None,
            cli_message: None,
            agent_changes_open: false,
            access_generation: 0,
            writing,
            models,
            resources: Default::default(),
            calendar,
            devices,
            coding_agent_folders,
            retention_draft: None,
            retention_error: None,
            retention_completion: None,
            storage: None,
            latest_activity: None,
            pending_jobs: 0,
            storage_measured_at: None,
            history: status::PageHistory::new(opened_on),
            subpage: None,
            library_size: None,
            free_bytes: None,
            library_measured_at: None,
            free_measured_at: None,
            last_settings: settings,
            _subscriptions: subscriptions,
        };
        page.reload_access(cx);
        // Opened from the CLI or tray with its window closed.
        let focus = page.data.update(cx, |data, _| data.settings_focus.take());
        if let Some(id) = focus {
            page.reveal(&id, window, cx);
        }
        page
    }

    fn update_settings(&self, change: impl FnOnce(&mut Settings), cx: &mut Context<Self>) {
        self.data
            .update(cx, |data, cx| data.update_settings(change, cx));
    }

    /// Keeps entity-backed controls in step with settings changed elsewhere.
    fn on_data_changed(
        &mut self,
        data: Entity<AppData>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.models.setup.poll(&data, cx);
        let focus = data.update(cx, |data, _| data.settings_focus.take());
        if let Some(id) = focus {
            self.reveal(&id, window, cx);
        }
        let settings = data.read(cx).settings.clone();
        if settings == self.last_settings {
            cx.notify();
            return;
        }
        let old = std::mem::replace(&mut self.last_settings, settings.clone());
        if old.quick_recall_shortcut != settings.quick_recall_shortcut {
            self.quick_recall_shortcut.update(cx, |field, cx| {
                field.set_value(&settings.quick_recall_shortcut, cx)
            });
        }
        if old.dictation_shortcut != settings.dictation_shortcut {
            self.dictation_shortcut.update(cx, |field, cx| {
                field.set_value(&settings.dictation_shortcut, cx)
            });
        }
        if old.selection_actions_shortcut != settings.selection_actions_shortcut {
            self.selection_actions_shortcut.update(cx, |field, cx| {
                field.set_value(&settings.selection_actions_shortcut, cx)
            });
        }
        sync_text(
            &self.digest_prompt,
            &settings.day_digest_custom_prompt,
            window,
            cx,
        );
        sync_input(
            &self.cotyping_name,
            &settings.cotyping_user_name,
            window,
            cx,
        );
        sync_input(
            &self.cotyping_style,
            &settings.cotyping_style_note,
            window,
            cx,
        );
        self.writing.sync(&settings, window, cx);
        self.excluded_apps
            .update(cx, |list, cx| list.set_value(&settings.excluded_apps, cx));
        self.excluded_sites.update(cx, |list, cx| {
            list.set_value(&settings.excluded_screen_domains, cx)
        });
        self.coding_agent_folders.update(cx, |list, cx| {
            list.set_value(&settings.coding_agent_excluded_folders, cx)
        });
        // A drag in progress keeps its place.
        if self.retention_draft.is_none() {
            sync_slider(
                &self.retention_slider,
                settings.retention_days as f32,
                window,
                cx,
            );
        }
        self.cotyping_excluded_apps.update(cx, |list, cx| {
            list.set_value(&settings.cotyping_excluded_apps, cx)
        });
        self.cotyping_excluded_sites.update(cx, |list, cx| {
            list.set_value(&settings.cotyping_excluded_domains, cx)
        });
        sync_slider(
            &self.debounce_slider,
            settings.cotyping_debounce_ms as f32,
            window,
            cx,
        );
        if !old.cotyping_enabled && settings.cotyping_enabled {
            // Turned on: the practice editor's text is a context to suggest for.
            self.practice_text = Default::default();
            self.practice_sync(cx);
        }
        sync_slider(
            &self.interval_slider,
            settings.screenshot_interval_minutes.clamp(1.0, 15.0) as f32,
            window,
            cx,
        );
        self.models.sync(&old, &settings, window, cx);
        self.calendar.sync(&old, &settings, window, cx);
        self.devices.sync(&old, &settings, window, cx);
        cx.notify();
    }

    fn reload_access(&mut self, cx: &mut Context<Self>) {
        let paths = self.data.read(cx).library.paths().clone();
        cx.spawn(async move |this, cx| {
            let (meetings, screen, personal, files, notes, cli, on_path) = cx
                .background_spawn(async move {
                    (
                        lokalbot_core::access::meetings_access_enabled(&paths),
                        lokalbot_core::access::screen_access_scope(&paths),
                        lokalbot_core::access::personal_context_enabled(&paths),
                        lokalbot_core::files::access::is_enabled(&paths),
                        lokalbot_core::agent_notes::access::is_enabled(&paths),
                        lokalbot_cli::install::installed_for_current_user(),
                        lokalbot_cli::install::on_path_for_current_user(),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.meetings_access = Some(meetings);
                this.screen_access = Some(screen);
                this.personal.access_on = personal;
                this.files_access = Some(files);
                this.agent_notes_access = Some(notes);
                this.cli_installed = Some(cli);
                this.cli_on_path = Some(on_path);
                cx.notify();
            });
        })
        .detach();
    }

    fn category(&self, cx: &App) -> SettingsCategory {
        self.data.read(cx).settings_category
    }

    fn select_category(
        &mut self,
        category: SettingsCategory,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.focused = None;
        self.clear_search(window, cx);
        self.scroll.set_offset(gpui_kit::point(px(0.), px(0.)));
        // A row's page belongs to the Settings page that opened it.
        if self.subpage.is_some_and(|sub| sub.page() != category) {
            self.subpage = None;
        }
        self.data
            .update(cx, |data, cx| data.select_settings_category(category, cx));
    }

    /// The page a row opened, while its own Settings page is the one shown.
    fn open_subpage(&self, category: SettingsCategory) -> Option<subpage::Subpage> {
        self.subpage.filter(|sub| sub.page() == category)
    }

    /// Opens the page behind one of Autocomplete's or Dictation's rows, at
    /// its top.
    fn show_subpage(&mut self, sub: subpage::Subpage, cx: &mut Context<Self>) {
        self.subpage = Some(sub);
        self.focused = None;
        self.scroll.set_offset(gpui_kit::point(px(0.), px(0.)));
        cx.notify();
    }

    fn close_subpage(&mut self, cx: &mut Context<Self>) {
        self.subpage = None;
        self.focused = None;
        self.scroll.set_offset(gpui_kit::point(px(0.), px(0.)));
        cx.notify();
    }

    fn clear_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.query.is_empty() {
            self.query.clear();
            self.search
                .update(cx, |input, cx| input.set_value("", window, cx));
        }
    }

    /// Opens a setting from search: its category, scrolled to and highlighted. A
    /// setting that shows only behind a switch opens that switch instead.
    fn jump_to(
        &mut self,
        entry: &'static catalog::Entry,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let settings = self.data.read(cx).settings.clone();
        let target = catalog::focus_target(entry.id, &settings);
        let entry = catalog::ENTRIES
            .iter()
            .find(|candidate| candidate.id == target)
            .unwrap_or(entry);
        self.clear_search(window, cx);
        // The try-out opens as a sheet over its page (`SettingsSheet`).
        if entry.id == "settings.autocompletePreview" {
            self.focused = None;
            if self.subpage.is_some() {
                self.subpage = None;
            }
            self.data.update(cx, |data, cx| {
                data.select_settings_category(entry.category, cx)
            });
            // After this update: the page may still be opening its window.
            cx.defer_in(window, |_, window, cx| {
                try_sheet::open(cx.entity(), try_sheet::TryKind::Autocomplete, window, cx)
            });
            cx.notify();
            return;
        }
        self.focused = Some(entry.id);
        self.pending_scroll = Some(entry.id);
        if entry.category == SettingsCategory::Models {
            self.models.page = models::ModelsPage::for_setting(entry.id);
        }
        // A setting a row's page holds opens that page; one on the page
        // itself closes it (`revealFocusedSetting`).
        self.subpage = subpage::Subpage::containing(entry.id, entry.category)
            .or(self.subpage.filter(|sub| sub.page() != entry.category));
        self.data.update(cx, |data, cx| {
            data.select_settings_category(entry.category, cx)
        });
        cx.notify();
    }

    /// Opens a setting in any category, scrolled to and highlighted, as a
    /// search result would.
    fn reveal(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(entry) = catalog::ENTRIES.iter().find(|e| e.id == id) {
            self.jump_to(entry, window, cx);
        }
    }

    fn is_focused(&self, id: &str) -> bool {
        self.focused == Some(id)
    }

    fn details_open(&self, id: &'static str) -> bool {
        self.open_details.contains(id)
    }

    /// A "How this works" disclosure that remembers whether it is open.
    fn details(
        &self,
        id: &'static str,
        title: &'static str,
        text: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let page = cx.entity();
        settings_row::details(
            id,
            title,
            text,
            self.details_open(id),
            move |_, cx| {
                page.update(cx, |page, cx| {
                    if !page.open_details.remove(id) {
                        page.open_details.insert(id);
                    }
                    cx.notify();
                })
            },
            cx,
        )
        .into_any_element()
    }

    /// A row with a switch bound to one boolean setting.
    fn toggle(
        &self,
        id: &'static str,
        title: &'static str,
        help: Option<&'static str>,
        value: bool,
        set: fn(&mut Settings, bool),
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let data = self.data.clone();
        settings_row::row(
            id,
            title,
            help.map(SharedString::from),
            settings_row::switch(id, value, move |checked, _, cx| {
                data.update(cx, |data, cx| data.update_settings(|s| set(s, checked), cx))
            }),
            self.is_focused(id),
            cx,
        )
        .into_any_element()
    }

    /// A row with a pop-up picker over `options`.
    #[allow(clippy::too_many_arguments)]
    fn choice<T: Copy + PartialEq + 'static>(
        &self,
        id: &'static str,
        title: &'static str,
        help: Option<SharedString>,
        options: Vec<(T, SharedString)>,
        current: T,
        set: fn(&mut Settings, T),
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let data = self.data.clone();
        let label = options
            .iter()
            .find(|(value, _)| *value == current)
            .map(|(_, l)| l.clone())
            .unwrap_or_default();
        let items: Vec<(SharedString, bool)> = options
            .iter()
            .map(|(value, l)| (l.clone(), *value == current))
            .collect();
        let values: Vec<T> = options.iter().map(|(value, _)| *value).collect();
        settings_row::row(
            id,
            title,
            help,
            settings_row::picker(
                SharedString::from(format!("{id}-picker")),
                label,
                items,
                move |index, _, cx| {
                    if let Some(value) = values.get(index).copied() {
                        data.update(cx, |data, cx| data.update_settings(|s| set(s, value), cx));
                    }
                },
            ),
            self.is_focused(id),
            cx,
        )
        .into_any_element()
    }

    fn sections(
        &mut self,
        category: SettingsCategory,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<Section> {
        match category {
            // Drawn by `render_overview`, as a status page rather than rows.
            SettingsCategory::Overview => Vec::new(),
            SettingsCategory::General => self.general_sections(cx),
            SettingsCategory::Models => self.models_sections(window, cx),
            SettingsCategory::Privacy => self.privacy_sections(cx),
            SettingsCategory::Meetings => self.meetings_sections(cx),
            SettingsCategory::DayMemory => {
                let mut sections = self.day_memory_sections(cx);
                sections.push(self.retention_section(cx));
                sections.push(self.exclusions_section(cx));
                sections.push(self.coding_agents_section(cx));
                sections.push(self.agent_kind_section(privacy::AgentKind::ScreenMemory, cx));
                sections
            }
            SettingsCategory::Files => {
                let mut sections = self.files_sections(cx);
                if self.data.read(cx).settings.file_search_enabled {
                    sections.push(self.agent_kind_section(privacy::AgentKind::Files, cx));
                }
                sections
            }
            SettingsCategory::Ask => self.ask_sections(cx),
            SettingsCategory::PersonalContext => self.personal_context_sections(cx),
            SettingsCategory::DailyReview => self.daily_review_sections(cx),
            SettingsCategory::Writing => self.writing_sections(cx),
            SettingsCategory::Dictation => self.dictation_sections(cx),
            SettingsCategory::Agents => {
                vec![self.agent_access_section(cx), self.agent_cli_section(cx)]
            }
            SettingsCategory::Devices => self.devices_sections(window, cx),
            SettingsCategory::Advanced => self.advanced_sections(cx),
        }
    }

    /// What a page adds to its shared header: "Try it…", its main switch, or
    /// a control of its own. Pages with none of these keep the default.
    fn header_spec(
        &mut self,
        category: SettingsCategory,
        status: &status::SettingsStatus,
        cx: &mut Context<Self>,
    ) -> header::HeaderSpec {
        let settings = self.data.read(cx).settings.clone();
        let page = cx.entity();
        let data = self.data.clone();
        match category {
            // "Download all", or Cancel while the models arrive.
            SettingsCategory::Models => header::HeaderSpec {
                accessory: header::download_control(status, &self.data),
                ..Default::default()
            },
            // The switch does what the page's own switch did: it sets the
            // setting, with no confirmation, as before.
            SettingsCategory::Writing => header::HeaderSpec {
                try_it: Some(std::rc::Rc::new(move |window, cx| {
                    try_sheet::open(page.clone(), try_sheet::TryKind::Autocomplete, window, cx)
                })),
                switch: Some(header::HeaderSwitch {
                    setting_id: "settings.cotypingEnabled",
                    on: settings.cotyping_enabled,
                    on_change: std::rc::Rc::new(move |on, _, cx| {
                        data.update(cx, |data, cx| {
                            data.update_settings(|s| s.cotyping_enabled = on, cx)
                        })
                    }),
                }),
                ..Default::default()
            },
            SettingsCategory::Dictation => header::HeaderSpec {
                try_it: Some(std::rc::Rc::new(move |window, cx| {
                    try_sheet::open(page.clone(), try_sheet::TryKind::Dictation, window, cx)
                })),
                switch: Some(header::HeaderSwitch {
                    setting_id: "settings.dictationEnabled",
                    on: settings.dictation_enabled,
                    on_change: std::rc::Rc::new(move |on, _, cx| {
                        data.update(cx, |data, cx| {
                            data.update_settings(|s| s.dictation_enabled = on, cx)
                        })
                    }),
                }),
                ..Default::default()
            },
            _ => header::HeaderSpec::default(),
        }
    }

    /// What opens in place of the shared header: a row's page starts with
    /// its way back (`SettingsSubpageBar`), and Models' own pages draw
    /// theirs. `None` keeps the header.
    fn replaces_header(
        &self,
        category: SettingsCategory,
        cx: &mut Context<Self>,
    ) -> Option<Option<AnyElement>> {
        if category == SettingsCategory::Models && self.models.page != models::ModelsPage::Active {
            return Some(None);
        }
        let sub = self.open_subpage(category)?;
        let page = cx.entity();
        Some(Some(subpage::bar(
            "settings-subpage-back",
            catalog::category_title(category),
            lokalbot_i18n::tr(sub.title()),
            move |_, cx| page.update(cx, |page, cx| page.close_subpage(cx)),
            cx,
        )))
    }

    /// Back to the page shown before (`SettingsPageHistory.goBack`).
    fn go_back(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(page) = self.history.go_back() {
            self.select_category(page, window, cx);
        }
    }

    fn go_forward(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(page) = self.history.go_forward() {
            self.select_category(page, window, cx);
        }
    }

    /// The free space where the models go, for the header's download line
    /// ("They need 3.7 GB, and this PC has 79 GB free"), measured off the main
    /// thread at most every 30 seconds.
    fn refresh_free_space(&mut self, cx: &mut Context<Self>) {
        if self
            .free_measured_at
            .is_some_and(|at| at.elapsed() < std::time::Duration::from_secs(30))
        {
            return;
        }
        self.free_measured_at = Some(std::time::Instant::now());
        let paths = self.data.read(cx).library.paths().clone();
        cx.spawn(async move |this, cx| {
            let free = cx
                .background_spawn(async move {
                    lokalbot_ai::download::free_space(&paths.models_dir())
                        .or_else(|| lokalbot_ai::download::free_space(paths.root()))
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if free.is_some() && this.free_bytes != free {
                    this.free_bytes = free;
                    cx.notify();
                }
            });
        })
        .detach();
    }

    /// The library's size without its models, and the free space where the
    /// models are, measured off the main thread at most every 30 seconds.
    fn refresh_library_size(&mut self, cx: &mut Context<Self>) {
        if self
            .library_measured_at
            .is_some_and(|at| at.elapsed() < std::time::Duration::from_secs(30))
        {
            return;
        }
        self.library_measured_at = Some(std::time::Instant::now());
        let paths = self.data.read(cx).library.paths().clone();
        cx.spawn(async move |this, cx| {
            let (bytes, free) = cx
                .background_spawn(async move {
                    let models = paths.models_dir();
                    (
                        status::library_bytes(paths.root(), &models),
                        lokalbot_ai::download::free_space(&models)
                            .or_else(|| lokalbot_ai::download::free_space(paths.root())),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.library_size = Some(bytes);
                this.free_bytes = free;
                cx.notify();
            });
        })
        .detach();
    }

    /// Everything the window says about each feature's state, read now.
    fn status(&self, cx: &App) -> status::SettingsStatus {
        let data = self.data.read(cx);
        let settings = data.settings.clone();
        // Read the way setup reads it (`crate::access`), so the two agree.
        let permissions: Vec<status::Permission> = crate::control::permissions::needs(data, cx)
            .into_iter()
            .map(status::Permission::from)
            .collect();
        let files_shared = self
            .files_access
            .unwrap_or_else(|| lokalbot_core::files::access::is_enabled(data.library.paths()));
        let notes_shared = self.agent_notes_access.unwrap_or_else(|| {
            lokalbot_core::agent_notes::access::is_enabled(data.library.paths())
        });
        let agent_kinds = usize::from(self.meetings_access == Some(true))
            + usize::from(self.screen_access.flatten().is_some())
            + usize::from(self.personal.access_on)
            + usize::from(files_shared)
            + usize::from(notes_shared);
        let agents_can_change_settings =
            crate::control::global(cx).is_some_and(|host| host.read(cx).enabled);
        let autocomplete_unavailable = match lokalbot_platform::autocomplete::support() {
            lokalbot_platform::autocomplete::Support::Unavailable(reason) => Some(reason),
            _ => None,
        };
        let failed_checks = data
            .model_checks
            .results
            .iter()
            .filter(|result| result.failure.is_some())
            .map(|result| match result.role {
                lokalbot_engine::ModelRole::Transcribe => status::Role::Transcribe,
                lokalbot_engine::ModelRole::Think => status::Role::Think,
                lokalbot_engine::ModelRole::Autocomplete => status::Role::Autocomplete,
            })
            .collect();
        status::SettingsStatus::new(status::StatusInput {
            models: status::models(&settings, &data.models, &data.downloads),
            failed_checks,
            permissions,
            free_bytes: self.free_bytes,
            agent_kinds,
            agents_can_change_settings,
            paired_devices: data.companion.devices.len(),
            autocomplete_unavailable,
            settings,
        })
    }

    /// The window's list (`SettingsSidebar`): search, the LokalBot row that
    /// opens Overview, then every page in its group. Feature rows say "Off"
    /// or "Paused" at the right, and the page where something is fixed
    /// carries a count. The strip above the search moves the window.
    fn render_categories(
        &self,
        category: SettingsCategory,
        searching: bool,
        status: &status::SettingsStatus,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let mut list = v_flex()
            .id("settings-categories")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .pb(px(12.))
            .gap(px(2.))
            .child(self.render_identity_row(
                category == SettingsCategory::Overview && !searching,
                status,
                cx,
            ));
        for page in LEADING_PAGES {
            list = list.child(self.render_category_row(page, category, searching, status, cx));
        }
        for group in GROUPS {
            list = list.child(
                div()
                    .px(px(20.))
                    .pt(px(12.))
                    .pb(px(2.))
                    .text_size(ty::SIDEBAR_SECTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text_secondary)
                    .child(lokalbot_i18n::tr(group)),
            );
            for page in CATEGORIES
                .into_iter()
                .filter(|page| category_group(*page) == Some(group))
            {
                list = list.child(self.render_category_row(page, category, searching, status, cx));
            }
        }
        for (index, page) in TRAILING_PAGES.into_iter().enumerate() {
            list = list.child(
                div()
                    .when(index == 0, |this| this.pt(px(14.)))
                    .child(self.render_category_row(page, category, searching, status, cx)),
            );
        }
        v_flex()
            .w(metric::SETTINGS_CATEGORIES_WIDTH)
            .flex_none()
            .h_full()
            .bg(lb.sidebar)
            .border_r_1()
            .border_color(lb.separator)
            .child(crate::shell::drag_region(
                h_flex()
                    .id("settings-search-bar")
                    .h(metric::TOOLBAR_HEIGHT)
                    .flex_none()
                    .px(px(12.))
                    .items_center()
                    .child(
                        div()
                            .w_full()
                            // The field takes its own clicks; the strip
                            // around it moves the window.
                            .on_mouse_down(gpui_kit::MouseButton::Left, |_, _, cx| {
                                cx.stop_propagation()
                            })
                            .child(Input::new(&self.search).cleanable(true).prefix(ui::icon(
                                Ico::Search,
                                px(14.),
                                lb.text_secondary,
                            ))),
                    ),
            ))
            .child(list)
    }

    /// The row at the top of the list, where System Settings puts the
    /// account: the app, and under it how many things need you
    /// (`SettingsIdentityRow`).
    fn render_identity_row(
        &self,
        selected: bool,
        status: &status::SettingsStatus,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let summary_color = if status.needs_attention() {
            lb.attention_text
        } else {
            lb.text_secondary
        };
        h_flex()
            .id("settings-identity")
            .mx(px(8.))
            .mt(px(2.))
            .mb(px(4.))
            .px(px(10.))
            .py(px(7.))
            .gap(px(10.))
            .items_center()
            .rounded(metric::ROW_RADIUS)
            .cursor_pointer()
            .when(selected, |this| this.bg(lb.sidebar_selection))
            .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
            .child(
                gpui_kit::img("brand/lokalbot.svg")
                    .size(px(32.))
                    .flex_none(),
            )
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(1.))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child("LokalBot"),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(summary_color)
                            .line_clamp(2)
                            .child(crate::pages::people::model::directional(status.summary())),
                    ),
            )
            .on_click(cx.listener(|this, _, window, cx| {
                this.select_category(SettingsCategory::Overview, window, cx)
            }))
            .into_any_element()
    }

    /// One page in the list: its glyph and name, then a count where things
    /// need fixing here, or "Paused" or "Off" (`SettingsCategoryRow`).
    fn render_category_row(
        &self,
        page: SettingsCategory,
        current: SettingsCategory,
        searching: bool,
        status: &status::SettingsStatus,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let selected = page == current && !searching;
        let badge = status.badge(page);
        let state = status.row_state(page);
        let trailing: Option<AnyElement> = if badge > 0 {
            Some(
                div()
                    .id(SharedString::from(format!(
                        "settings-category-{}-badge",
                        page.key()
                    )))
                    .flex_none()
                    .min_w(px(18.))
                    .h(px(17.))
                    .px(px(6.))
                    .rounded_full()
                    .bg(lb.attention_text)
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(ty::CAPTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.window)
                    .child(lokalbot_i18n::number(badge))
                    .into_any_element(),
            )
        } else {
            match state {
                status::RowState::Paused => Some(
                    div()
                        .flex_none()
                        .text_size(ty::SECONDARY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(if selected { lb.text } else { lb.attention_text })
                        .child(lokalbot_i18n::tr("Paused"))
                        .into_any_element(),
                ),
                status::RowState::Off => Some(
                    div()
                        .flex_none()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(lokalbot_i18n::tr("Off"))
                        .into_any_element(),
                ),
                status::RowState::Normal => None,
            }
        };
        h_flex()
            .id(SharedString::from(format!(
                "settings-category-{}",
                page.key()
            )))
            .mx(px(8.))
            .px(px(10.))
            .h(px(32.))
            .gap(px(8.))
            .items_center()
            .rounded(metric::ROW_RADIUS)
            .cursor_pointer()
            .when(selected, |this| this.bg(lb.sidebar_selection))
            .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
            .child(ui::icon(category_icon(page), px(16.), lb.accent_text))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .when(selected, |this| this.font_weight(FontWeight::MEDIUM))
                    .child(catalog::category_title(page)),
            )
            .children(trailing)
            .on_click(
                cx.listener(move |this, _, window, cx| this.select_category(page, window, cx)),
            )
            .into_any_element()
    }

    /// Back and forward through the pages visited, then the page's name
    /// (`SettingsView.topBar`). It is the window's title bar: it moves the
    /// window and holds its buttons.
    fn render_top_bar(
        &self,
        title: SharedString,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        // Back points the way the interface reads.
        let (back, forward) = if lokalbot_i18n::current().rtl {
            (Ico::ChevronRight, Ico::ChevronLeft)
        } else {
            (Ico::ChevronLeft, Ico::ChevronRight)
        };
        let arrow = |id: &'static str, icon: Ico, label: &'static str, enabled: bool| {
            Button::new(id)
                .ghost()
                .small()
                .icon(Icon::new(icon))
                .tooltip(lokalbot_i18n::tr(label))
                .disabled(!enabled)
        };
        gpui_kit::component::TitleBar::new()
            .h(metric::TOOLBAR_HEIGHT)
            .bg(lb.title_bar)
            .border_color(lb.separator)
            .child(
                h_flex()
                    .h_full()
                    .min_w_0()
                    .items_center()
                    .child(
                        // The arrows take their own clicks; the rest of the
                        // bar moves the window.
                        h_flex()
                            .h_full()
                            .pl(px(10.))
                            .gap(px(2.))
                            .items_center()
                            // The bar under them must not see their presses:
                            // it would start moving the window.
                            .occlude()
                            .child(
                                arrow("settings-back", back, "Back", self.history.can_go_back())
                                    .on_click(
                                        cx.listener(|this, _, window, cx| this.go_back(window, cx)),
                                    ),
                            )
                            .child(
                                arrow(
                                    "settings-forward",
                                    forward,
                                    "Forward",
                                    self.history.can_go_forward(),
                                )
                                .on_click(
                                    cx.listener(|this, _, window, cx| this.go_forward(window, cx)),
                                ),
                            ),
                    )
                    .child(
                        div()
                            .pl(px(8.))
                            .min_w_0()
                            .truncate()
                            .text_size(ty::COLUMN_TITLE)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(title),
                    ),
            )
    }

    fn render_search_results(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let settings = self.data.read(cx).settings.clone();
        let results = catalog::search(&self.query);
        if results.is_empty() {
            return ui::empty_state(
                Ico::Search,
                lokalbot_i18n::format(
                    "No Results for “{0}”",
                    &[("0", self.query.trim().to_string())],
                ),
                lokalbot_i18n::tr("Check the spelling or try a different setting name."),
                cx,
            )
            .size_full()
            .into_any_element();
        }
        let rows: Vec<AnyElement> = results
            .into_iter()
            .map(|entry| {
                let value = (entry.value)(&settings);
                let prerequisite = catalog::prerequisite(entry.id, &settings);
                div()
                    .id(SharedString::from(format!("settings-result-{}", entry.id)))
                    .w_full()
                    .px(px(12.))
                    .py(px(9.))
                    .rounded(metric::ROW_RADIUS)
                    .cursor_pointer()
                    .hover(|s| s.bg(lb.hover))
                    .child(
                        v_flex()
                            .gap(px(3.))
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                        catalog::display_title(entry),
                                    ))),
                            )
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(format!(
                                        "{value} · {}",
                                        catalog::category_title(entry.category)
                                    )),
                            )
                            .when_some(prerequisite, |this, prerequisite| {
                                this.child(
                                    div()
                                        .text_size(ty::CAPTION)
                                        .text_color(lb.text_secondary)
                                        .child(crate::ui::text::paragraph(prerequisite)),
                                )
                            }),
                    )
                    .on_click(
                        cx.listener(move |this, _, window, cx| this.jump_to(entry, window, cx)),
                    )
                    .into_any_element()
            })
            .collect();
        div()
            .id("settings-results")
            .size_full()
            .overflow_y_scroll()
            .child(
                v_flex().w_full().items_center().child(
                    v_flex()
                        .w_full()
                        .max_w(metric::READING_MAX_WIDTH + px(56.))
                        .px(metric::DETAIL_PADDING)
                        .pb(metric::DETAIL_PADDING)
                        .gap(px(2.))
                        .children(rows),
                ),
            )
            .into_any_element()
    }
}

fn sync_input(input: &Entity<InputState>, value: &str, window: &mut Window, cx: &mut App) {
    if input.read(cx).value().as_ref() != value
        && !input.read(cx).focus_handle(cx).is_focused(window)
    {
        input.update(cx, |input, cx| {
            input.set_value(value.to_string(), window, cx)
        });
    }
}

fn sync_text(input: &Entity<TextareaState>, value: &str, window: &mut Window, cx: &mut App) {
    if input.read(cx).value().as_ref() != value
        && !input.read(cx).focus_handle(cx).is_focused(window)
    {
        input.update(cx, |input, cx| {
            input.set_value(value.to_string(), window, cx)
        });
    }
}

fn sync_slider(slider: &Entity<SliderState>, value: f32, window: &mut Window, cx: &mut App) {
    if (slider.read(cx).value().start() - value).abs() > f32::EPSILON {
        slider.update(cx, |slider, cx| slider.set_value(value, window, cx));
    }
}

impl Render for SettingsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let category = self.category(cx);
        // Pages opened from elsewhere (links, the CLI) count as visits too.
        self.history.visit(category);
        // What this computer allows can change while Settings is open (an
        // extension installed, a service started): read it again now and then.
        self.data
            .update(cx, |data, cx| data.refresh_access_if_stale(cx));
        self.refresh_free_space(cx);
        let searching = !self.query.trim().is_empty();
        let status = self.status(cx);
        let title: SharedString = if searching {
            lokalbot_i18n::tr("Search settings").into()
        } else {
            catalog::category_title(category).into()
        };
        let reading_column = || {
            v_flex()
                .w_full()
                .max_w(metric::READING_MAX_WIDTH + px(56.))
                .px(metric::DETAIL_PADDING)
        };

        let body = if searching {
            v_flex()
                .size_full()
                .child(
                    v_flex().w_full().items_center().child(
                        reading_column().pt(px(12.)).pb(px(8.)).child(settings_row::help(
                            lokalbot_i18n::tr(
                                "Results across all categories. Choose a setting to edit its value.",
                            ),
                            cx,
                        )),
                    ),
                )
                .child(div().flex_1().min_h_0().child(self.render_search_results(cx)))
                .into_any_element()
        } else if category == SettingsCategory::Overview {
            self.render_overview(&status, cx)
        } else {
            let sections = self.sections(category, window, cx);
            let header = match self.replaces_header(category, cx) {
                Some(bar) => bar,
                None => {
                    let spec = self.header_spec(category, &status, cx);
                    let settings = self.data.read(cx).settings.clone();
                    let switch_highlighted = spec
                        .switch
                        .as_ref()
                        .is_some_and(|switch| self.is_focused(switch.setting_id));
                    Some(header::page_header(
                        category,
                        category_summary(category, &settings),
                        status.lines(category),
                        spec,
                        switch_highlighted,
                        &self.data,
                        header::opener(&cx.entity()),
                        cx,
                    ))
                }
            };
            let leading = usize::from(header.is_some());
            if let Some(target) = self.pending_scroll.take()
                && let Some(index) = sections.iter().position(|s| s.ids.contains(&target))
            {
                // The header comes first.
                let index = index + leading;
                self.scroll.scroll_to_item(index);
                // A page drawn for the first time has no layout to scroll in yet.
                let scroll = self.scroll.clone();
                window.on_next_frame(move |window, _| {
                    scroll.scroll_to_item(index);
                    window.refresh();
                });
            }
            let mut children: Vec<AnyElement> = header
                .map(|header| {
                    reading_column()
                        .pt(px(20.))
                        .pb(metric::SECTION_SPACING)
                        .child(header)
                        .into_any_element()
                })
                .into_iter()
                .collect();
            children.extend(sections.into_iter().enumerate().map(|(index, section)| {
                let body = match section.header {
                    Some(header) if section.rows.is_empty() => header,
                    Some(header) => v_flex()
                        .w_full()
                        .gap(px(8.))
                        .child(header)
                        .child(settings_row::section(None, section.rows, cx))
                        .into_any_element(),
                    None => settings_row::section(
                        section
                            .title
                            .map(|key| SharedString::from(lokalbot_i18n::tr(key))),
                        section.rows,
                        cx,
                    )
                    .into_any_element(),
                };
                reading_column()
                    // A page without the header starts where the header would.
                    .when(index == 0 && leading == 0, |this| this.pt(px(20.)))
                    .pb(metric::SECTION_SPACING)
                    .child(body)
                    .into_any_element()
            }));
            v_flex()
                .id(SharedString::from(format!("settings-body-{category:?}")))
                .size_full()
                .items_center()
                .overflow_y_scroll()
                .track_scroll(&self.scroll)
                .pb(metric::DETAIL_PADDING)
                .children(children)
                .into_any_element()
        };

        h_flex()
            .size_full()
            .bg(lb.window)
            .child(self.render_categories(category, searching, &status, cx))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .child(self.render_top_bar(title, cx))
                    .child(div().flex_1().min_h_0().child(body)),
            )
    }
}
