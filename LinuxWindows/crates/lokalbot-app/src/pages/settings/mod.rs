//! Settings (`SettingsView.swift`): categories with teal icons on the left,
//! a title and grouped form on the right, and search across every category.

pub mod advanced;
mod calendar;
pub mod catalog;
mod day_memory;
mod dictation;
mod general;
pub mod meetings;
pub mod models;
mod plans;
mod privacy;
pub mod writing;

pub use day_memory::mode_detail as day_memory_mode_detail;

use std::collections::HashSet;

use crate::i18n::h_flex;
use gpui_kit::component::input::{Input, InputEvent, InputState, TextareaState};
use gpui_kit::component::slider::{SliderEvent, SliderState};
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, Focusable as _, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement as _, Render, ScrollHandle, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window, div, px,
};
use lokalbot_core::Settings;
use lokalbot_core::access::ScreenScope;

use crate::pages::Page;
use crate::state::{AppData, SettingsCategory};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::rule_list::{RuleKind, RuleList, RuleListEvent};
use crate::ui::shortcut_field::{ShortcutEvent, ShortcutField};
use crate::ui::{self, Ico, settings_row};

pub const CATEGORIES: [SettingsCategory; 8] = [
    SettingsCategory::General,
    SettingsCategory::Meetings,
    SettingsCategory::DayMemory,
    SettingsCategory::Writing,
    SettingsCategory::Dictation,
    SettingsCategory::Models,
    SettingsCategory::Privacy,
    SettingsCategory::Advanced,
];

fn category_icon(category: SettingsCategory) -> Ico {
    match category {
        SettingsCategory::General => Ico::Settings,
        SettingsCategory::Meetings => Ico::Users,
        SettingsCategory::DayMemory => Ico::ChartGantt,
        SettingsCategory::Writing => Ico::Pencil,
        SettingsCategory::Dictation => Ico::Mic,
        SettingsCategory::Models => Ico::Package,
        SettingsCategory::Privacy => Ico::Lock,
        SettingsCategory::Advanced => Ico::SlidersHorizontal,
    }
}

fn category_subtitle(category: SettingsCategory) -> &'static str {
    match category {
        SettingsCategory::General => {
            lokalbot_i18n::tr("Startup, appearance, the Ask shortcut, and updates.")
        }
        SettingsCategory::Meetings => {
            lokalbot_i18n::tr("Meeting capture, detection, processing, and summaries.")
        }
        SettingsCategory::DayMemory => {
            lokalbot_i18n::tr("Activity, captured screen context, and daily digests.")
        }
        SettingsCategory::Writing => lokalbot_i18n::tr("Autocomplete and your writing profile."),
        SettingsCategory::Dictation => lokalbot_i18n::tr(
            "The dictation shortcut, Transcribe or Compose, and where the text goes.",
        ),
        SettingsCategory::Models => {
            lokalbot_i18n::tr("Choose the models behind Transcribe, Think, and Autocomplete.")
        }
        SettingsCategory::Privacy => {
            lokalbot_i18n::tr("Control retention, exclusions, and remote processing.")
        }
        SettingsCategory::Advanced => {
            lokalbot_i18n::tr("Setup, the Agent CLI, logs, and details about this build.")
        }
    }
}

/// One grouped section of a category; `ids` are the rows it holds, for search jumps.
pub struct Section {
    pub title: Option<&'static str>,
    pub ids: Vec<&'static str>,
    pub rows: Vec<AnyElement>,
}

impl Section {
    pub fn new(title: impl Into<Option<&'static str>>) -> Self {
        Self {
            title: title.into(),
            ids: Vec::new(),
            rows: Vec::new(),
        }
    }

    pub fn row(mut self, id: &'static str, element: impl IntoElement) -> Self {
        self.ids.push(id);
        self.rows.push(element.into_any_element());
        self
    }
}

pub struct SettingsPage {
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
    /// External-agent markers, read from disk off the main thread.
    meetings_access: Option<bool>,
    screen_access: Option<Option<ScreenScope>>,
    cli_installed: Option<bool>,
    models: models::ModelsState,
    calendar: calendar::CalendarState,
    last_settings: Settings,
    _subscriptions: Vec<Subscription>,
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
                    (candidate == settings.dictation_shortcut).then(|| {
                        lokalbot_i18n::tr("Dictation already uses this shortcut. Choose another.")
                            .to_string()
                    })
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
                    (candidate == settings.quick_recall_shortcut).then(|| {
                        lokalbot_i18n::tr(
                            "The Ask shortcut already uses this shortcut. Choose another.",
                        )
                        .to_string()
                    })
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
                RuleKind::Domains,
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
        for (list, set) in [
            (
                &excluded_apps,
                (|s: &mut Settings, v: String| s.excluded_apps = v) as fn(&mut Settings, String),
            ),
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
            |this, _, event: &SliderEvent, _, cx| {
                let (SliderEvent::Change(value) | SliderEvent::Release(value)) = event;
                let days = value.start().round() as u32;
                this.update_settings(move |s| s.retention_days = days, cx);
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
        let calendar = calendar::CalendarState::new(&settings, window, cx);
        subscriptions.extend(calendar::CalendarState::subscribe(&calendar, window, cx));
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
            meetings_access: None,
            screen_access: None,
            cli_installed: None,
            models,
            calendar,
            last_settings: settings,
            _subscriptions: subscriptions,
        };
        page.reload_access(cx);
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
        self.excluded_apps
            .update(cx, |list, cx| list.set_value(&settings.excluded_apps, cx));
        self.excluded_sites.update(cx, |list, cx| {
            list.set_value(&settings.excluded_screen_domains, cx)
        });
        sync_slider(
            &self.retention_slider,
            settings.retention_days as f32,
            window,
            cx,
        );
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
        cx.notify();
    }

    fn reload_access(&mut self, cx: &mut Context<Self>) {
        let paths = self.data.read(cx).library.paths().clone();
        cx.spawn(async move |this, cx| {
            let (meetings, screen, cli) = cx
                .background_spawn(async move {
                    (
                        lokalbot_core::access::meetings_access_enabled(&paths),
                        lokalbot_core::access::screen_access_scope(&paths),
                        lokalbot_cli::install::installed_for_current_user(),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.meetings_access = Some(meetings);
                this.screen_access = Some(screen);
                this.cli_installed = Some(cli);
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
        self.data
            .update(cx, |data, cx| data.open_settings(category, cx));
    }

    fn clear_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.query.is_empty() {
            self.query.clear();
            self.search
                .update(cx, |input, cx| input.set_value("", window, cx));
        }
    }

    /// Opens a setting from search: its category, scrolled to and highlighted.
    fn jump_to(
        &mut self,
        entry: &'static catalog::Entry,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.clear_search(window, cx);
        self.focused = Some(entry.id);
        self.pending_scroll = Some(entry.id);
        if entry.category == SettingsCategory::Models {
            self.models.page = models::ModelsPage::for_setting(entry.id);
        }
        self.data
            .update(cx, |data, cx| data.open_settings(entry.category, cx));
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
            SettingsCategory::General => self.general_sections(cx),
            SettingsCategory::Meetings => self.meetings_sections(cx),
            SettingsCategory::DayMemory => self.day_memory_sections(cx),
            SettingsCategory::Writing => self.writing_sections(cx),
            SettingsCategory::Dictation => self.dictation_sections(cx),
            SettingsCategory::Models => self.models_sections(window, cx),
            SettingsCategory::Privacy => self.privacy_sections(cx),
            SettingsCategory::Advanced => self.advanced_sections(cx),
        }
    }

    fn render_categories(
        &self,
        category: SettingsCategory,
        searching: bool,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let rows: Vec<AnyElement> = CATEGORIES
            .iter()
            .map(|item| {
                let item = *item;
                let selected = item == category && !searching;
                h_flex()
                    .id(SharedString::from(format!("settings-category-{item:?}")))
                    .mx(px(8.))
                    .px(px(10.))
                    .h(px(34.))
                    .gap(px(10.))
                    .items_center()
                    .rounded(metric::ROW_RADIUS)
                    .cursor_pointer()
                    .when(selected, |this| this.bg(lb.sidebar_selection))
                    .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
                    .child(ui::icon(category_icon(item), px(16.), lb.accent_text))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .when(selected, |this| this.font_weight(FontWeight::MEDIUM))
                            .child(catalog::category_title(item)),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.select_category(item, window, cx)
                    }))
                    .into_any_element()
            })
            .collect();
        v_flex()
            .w(metric::SETTINGS_CATEGORIES_WIDTH)
            .flex_none()
            .h_full()
            .border_r_1()
            .border_color(lb.separator)
            .child(
                v_flex()
                    .px(px(20.))
                    .pt(px(16.))
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(ty::COLUMN_TITLE)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Settings"))),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                "LokalBot {0}",
                                &[("0", env!("CARGO_PKG_VERSION").to_string())],
                            ))),
                    ),
            )
            .child(div().px(px(14.)).pt(px(12.)).pb(px(10.)).child(
                Input::new(&self.search).cleanable(true).prefix(ui::icon(
                    Ico::Search,
                    px(14.),
                    lb.text_secondary,
                )),
            ))
            .child(v_flex().gap(px(2.)).children(rows))
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
                                        entry.title,
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
                            ),
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

impl Page for SettingsPage {
    fn title(&self, _cx: &App) -> SharedString {
        lokalbot_i18n::tr("Settings").into()
    }
}

impl Render for SettingsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let category = self.category(cx);
        let searching = !self.query.trim().is_empty();
        let (title, subtitle) = if searching {
            (
                lokalbot_i18n::tr("Search settings"),
                lokalbot_i18n::tr(
                    "Results across all categories. Choose a setting to edit its value.",
                ),
            )
        } else {
            (
                catalog::category_title(category),
                category_subtitle(category),
            )
        };

        let body = if searching {
            self.render_search_results(cx)
        } else {
            let sections = self.sections(category, window, cx);
            if let Some(target) = self.pending_scroll.take()
                && let Some(index) = sections.iter().position(|s| s.ids.contains(&target))
            {
                self.scroll.scroll_to_item(index);
            }
            let children: Vec<AnyElement> = sections
                .into_iter()
                .map(|section| {
                    div()
                        .w_full()
                        .max_w(metric::READING_MAX_WIDTH + px(56.))
                        .px(metric::DETAIL_PADDING)
                        .pb(metric::SECTION_SPACING)
                        .child(settings_row::section(
                            section
                                .title
                                .map(|key| SharedString::from(lokalbot_i18n::tr(key))),
                            section.rows,
                            cx,
                        ))
                        .into_any_element()
                })
                .collect();
            v_flex()
                .id(SharedString::from(format!("settings-body-{category:?}")))
                .size_full()
                .items_center()
                .overflow_y_scroll()
                .track_scroll(&self.scroll)
                .pt(px(4.))
                .pb(metric::DETAIL_PADDING)
                .children(children)
                .into_any_element()
        };

        h_flex()
            .size_full()
            .bg(lb.window)
            .child(self.render_categories(category, searching, cx))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .child(
                        v_flex().w_full().items_center().child(
                            v_flex()
                                .w_full()
                                .max_w(metric::READING_MAX_WIDTH + px(56.))
                                .px(metric::DETAIL_PADDING)
                                .pt(px(16.))
                                .pb(px(14.))
                                .gap(px(3.))
                                .child(
                                    div()
                                        .text_size(ty::PAGE_TITLE)
                                        .font_weight(FontWeight::BOLD)
                                        .text_color(lb.text)
                                        .child(title),
                                )
                                .child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(lb.text_secondary)
                                        .child(subtitle),
                                ),
                        ),
                    )
                    .child(div().flex_1().min_h_0().child(body)),
            )
    }
}
